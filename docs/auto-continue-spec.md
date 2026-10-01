# Spec: auto-continue for chats the limit cut off

Status: accepted 2026-09-27; amended the same day (below) - 0.9.0 built
both modes, the ask and the automatic one. Written against 0.8.0. The
owner asked for it on by default with a switch to turn it off, and took
the decisions at the end as proposed. Spikes A3 and A4 were answered from
this machine's files (below); A1 and A2 need a real limit and wait for
one, with the 5-minute hold standing in until then. The command
`chatqnotify` is called `chatnotify` here (the old name stays as an alias).

Amended 2026-09-27: the owner asked that the default ask first. The ask
mode is built (0.9.0, below). The automatic mode the rest of this spec
describes is the opt-in `autoContinue: "on"`, built in the same 0.9.0 in
[src/auto-continue.ps1](../src/auto-continue.ps1); where this spec says
"on by default", read "on once chosen". How the two were fitted together is
in [Both modes, built](#both-modes-built).

## Goal

When the usage limit cuts off a Claude chat, chatq queues *"Continue from
where you left off."* for it by itself. The continue goes a minute after
the limit resets. It is the opt-in value `"on"` of `autoContinue`; the
default asks first (below). One switch turns it off for every
chat, and each chat can be set to always or never. Every surface that
shows a cut-off chat says what will happen to it and lets you cancel it.

## Ask at the reset (the default, built)

Built in 0.9.0, as the default value `"ask"` of `autoContinue`; `"off"`
keeps the rows as they were, only orange. Nothing in it continues a chat
unless you say so.

- **The setting.** [Get-ChatqAutoContinue](../src/queue.ps1) reads the
  top-level `autoContinue`: `false` or `"false"` or `"off"` is `off`,
  `"on"` the automatic mode, anything else - missing, `true` - is `ask`,
  so nothing written before turns on the automatic mode.
  [Set-ChatqAutoContinue](../src/queue.ps1) `-Value on|ask|off` writes it. [Get-ChatOverlayConfig](../src/overlay-data.ps1)
  carries it as `autoContinue`.
- **Which chats.** [Get-ChatqResetAsk](../src/queue.ps1), pure, takes the
  whole scan ([Get-ChatqCutOffChats](../src/queue.ps1), whose rows now
  carry `LimitUuid`) and returns one ask for every cut-off that is a limit
  (not a 529), whose reset has a time and is at least
  `$script:ChatqAskAfterMinutes` (5) and under 12 hours behind, with no job
  queued or running and no answer marker. A chat a terminal or any
  non-panel entry holds goes to `Left`, named, not asked about. While a 5 h
  or weekly window is limited with its reset ahead, nothing is asked. The
  5 minutes are this spec's panel hold (A1), given to every chat so there
  is one prompt.
- **Once per cut-off.** [Get-ChatqCutKey](../src/queue.ps1) is the marker
  name of this spec's check 7: `<sessionId>_<limitUuid>`, or the record's
  time in UTC ticks on a record with no `uuid`.
  [Save-ChatqAskAnswer](../src/queue.ps1) writes the answer marker,
  [Read-ChatqAskState](../src/queue.ps1) reads them,
  [Read-ChatqAskShown](../src/queue.ps1) and
  [Add-ChatqAskShown](../src/queue.ps1) keep the `.shown` files that stop a
  restarted overlay announcing an ask again.
- **The collector.** [Invoke-ChatOverlayCycle](../src/overlay-data.ps1)
  keeps the whole scan as `CutScan`, runs it while `overlay.cutOff` or the
  ask is on, and asks every pass. Only the Windows and macOS hosts
  (`WantAsk`) announce or act; `-Print` shows the ask as a note. Its
  `header.ask` carries the count, the reset, the keys and up to five
  titles. The rows' window widened: a cut-off stays while its reset is
  under 12 hours ago or it is under 12 hours old.
- **The answer.** [Complete-ChatqResetAsk](../src/overlay-data.ps1) acts
  only on the chats the answer's surface showed; one that changed meanwhile
  acts on nothing. Continue runs
  [Invoke-ChatqContinueChats](../src/commands.ps1) - the console's loop,
  made shared - and marks only the chats that got a job or had one, so a
  failed one is asked about again. Leave marks them all.
- **Windows.** A toast ([Show-ChatOverlayBalloon](../src/overlay-windows.ps1));
  a click on it opens the console, never answers. A banner
  ([Add-ChatOverlayAsk](../src/overlay-windows.ps1)) whose chip carries
  **continue N** and **leave them**
  ([Get-ChatOverlayChipActions](../src/overlay-windows.ps1)); the tray's
  items ([Update-ChatOverlayAsk](../src/overlay-windows.ps1)); both answer
  through [Invoke-ChatOverlayAskAnswer](../src/overlay-windows.ps1). The
  settings box's **Cut off** row, Ask or Leave
  ([Set-ChatOverlayAutoChoice](../src/overlay-windows.ps1)). The console's
  **Cut off** header and **Leave them**; its **Continue** answers the ask
  too ([Save-ChatConsoleAskAnswer](../src/console.ps1)).
- **macOS.** Two items at the top of the `CQ` menu, sent as the verbs
  `ask-go` and `ask-leave` through `overlay-cmd`, and a notification
  ([Update-ChatOverlayMacAsk](../src/overlay-mac.ps1)). Each verb names
  the cut-offs the items were drawn for, `ask-go <key>,<key>` - the
  menu's title is set on a timer that stops while the menu is open, so
  the host's newer snapshot may name one it never showed - and only those
  are answered ([Invoke-ChatOverlayCycle](../src/overlay-data.ps1)). A
  bare verb, from a shell, answers the saved snapshot's.
- **The console with `overlay.cutOff` off.** The ask still runs, and its
  toast opens the console: its **Cut off** list takes the ask's own chats
  when no row was drawn for them
  ([Get-ChatConsoleChatItems](../src/console.ps1)).
- **The phone.** [Send-ChatqResetAskAlert](../src/phone.ps1): one
  `limited` alert with no session, when you are away. The page offers
  Status alone; answering there is FUTURE_WORK.
- **The CLI.** `chatq -AutoContinue ask|off`, alone, with `-WhatIf`.
- **The reset time on the overlay**, asked for with it:
  [Get-ChatOverlayResetWindow](../src/overlay-data.ps1) picks the window a
  usage line shows the reset of, [Format-ChatOverlayResetAt](../src/overlay-data.ps1)
  words a reset ahead and [Format-ChatOverlayAskAt](../src/overlay-data.ps1)
  one passed; the lines view, the collapsed line and the tray tooltip show
  it.

What the automatic mode adds as `"on"`: the scan that queues by itself
(`Invoke-ChatqAutoContinueScan` and the watcher's own scan), `since`, the
per-chat `always`/`never`, the job fields, the watcher's hold, gone-skip
and streak, the states and their row words, **don't continue**, and the
`limited` alert about an `auto` job. It reads the ask's markers: a cut-off
answered `leave` is its `declined`, one answered `continue` already has
its job.

## Both modes, built

Built in 0.9.0 on top of the ask, as the two authors agreed:

- **One setting, three values.** [Get-ChatqAutoContinue](../src/queue.ps1)
  reads only the word `"on"` as on; `true`, as this spec once wrote the
  switch, still reads as ask, so nothing written before turns it on.
  [Set-ChatqAutoContinue](../src/queue.ps1) `-Value on|ask|off` is the one
  writer; turning it on writes `since` anew
  ([Reset-ChatqAutoSince](../src/auto-continue.ps1)), so only cut-offs from
  then on are continued. What each value prints is
  [Get-ChatqAutoSwitchSay](../src/auto-continue.ps1)'s. Its lines read
  `auto-continue: on|ask|off - ...`, the ask's shape.
- **One marker per cut-off, for both.** The automatic mode names its marker
  with [Get-ChatqCutKey](../src/queue.ps1) and writes the ask's shape -
  `at`, `answer: continue`, `source` (`overlay` or `watcher`), `seq` - plus
  what it reads back: `sessionId`, `cutUuid`, `cutAt`, `resetsAt`, `jobId`,
  and `error` when its job could not be made. The ask's answers carry
  `sessionId` and `resetsAt` too ([Get-ChatqAskExtra](../src/auto-continue.ps1)),
  so a later cut-off of that chat with the same reset (A3) is held by
  either. `leave` is `declined`; a `continue` whose job failed is `failed`.
  The job's `cutUuid` is the key's part after the session id
  ([Get-ChatqCutId](../src/auto-continue.ps1)): the uuid, or the record's
  UTC ticks.
- **Which runs when.** `on`: the scan, no ask. `ask`: the ask, and the scan
  only for chats set to `always`. `off`: the scan only for those. A mode
  that does nothing for a chat leaves its row as it was: no state, the old
  words (`cut off - resets 13:00`), open alone on its chip.
- **The surfaces.** The settings row is **Continue**, **Ask** and **Leave**
  ([Set-ChatOverlayAutoChoice](../src/overlay-windows.ps1)); the tray item
  and the Mac menu item are checked while it is `on`, and unchecking goes
  back to `ask` (verbs `auto-on`, `auto-ask`, `auto-off` through
  `overlay-cmd`, [Invoke-ChatOverlayAutoVerbs](../src/auto-continue.ps1)).
  The chip's actions are one list for both
  ([Get-ChatOverlayChipActions](../src/overlay-windows.ps1)), a release
  acting only on the chip it was pressed on
  ([Invoke-ChatOverlayChipRelease](../src/overlay-windows.ps1)). The palette
  command offers Continue, Ask and Leave. `chatq -AutoContinue` takes
  `on|ask|off|always|never|default`.
- **The overlay owner's comments** on this spec, applied: the chip records
  which chip was pressed and rebuilds its face per row - tooltips too - before
  it is measured; auto chips keep clear of the row's words, which their
  tooltip also carries in full; neither auto chip goes near the unread dot;
  the row's words are short, in full in the tooltip, the console detail and
  `-Print`; a row with no where mark keeps an empty slot so every title
  starts at one column; the seven-row box is checked with the panel at the
  screen's top; one confirm rule for Don't continue - one click, in the Cut
  off list and the queue alike, since Continue undoes it; the tray's toggle
  goes through `Invoke-ChatOverlayVerb`, held while the console runs a loop
  of its own; and the collapsed line counts `(1 auto)`.

## The chats a restart cut off (`restart`, built)

Built after 0.10.2: a VS Code window that reloads under working chats
cuts them off as a limit does, and the reset ask offers them with a reason
of their own, `restart`, next to `limit`. One way of continuing a chat,
not two.

- **The note.** Every look the extension runs before a reload - the update
  notice's, the wait's every 25 s, chatq's own reload check - ends with
  [Save-ChatHostWorkNote](../src/host-work.ps1): `data/host-work/<host
  pid>.json`, with the host's start (`hostStart`, from
  [hostStart](../extension/safe-restart.js)), when, and each chat at work -
  a turn, a prompt, background work, never a `claude -p` run - with its
  transcript, its size and its processes' oldest start. Nothing at work, or
  the window's chats not told apart, removes it. That makes it Windows
  only: off Windows a process's parent cannot be read
  ([Get-ChatProcessTable](../src/overlay-data.ps1) gives none), the look is
  never `Known`, and no note is written. Each save also removes any note
  past its 12 hours, so a host left after **Later** with no overlay asking
  does not leave its note for good.
- **Which chats.** The overlay's cut-off look runs
  [Get-ChatRestartCutOffs](../src/host-work.ps1) with the limit's look -
  once a minute, and at once when the live chats change, as they do after
  a reload ([Invoke-ChatOverlayCycle](../src/overlay-data.ps1)). It reads only notes
  whose host is gone ([Test-ChatHostAlive](../src/host-work.ps1): pid and
  start, to 5 s) and under 12 hours old, and writes `goneAt` the first time.
  A chat counts when nothing of it works now, no job is queued for it, no
  process of it outlived the host, nothing was written to it since the host
  went, and something was lost: its last message owes an answer
  ([Test-ChatRestartMid](../src/host-work.ps1) - a `tool_use`, a prompt, a
  tool's result; not an answer, a turn you stopped, a slash command) or a
  workflow or agent it started never reported. A tab the reload brought
  back, idle, still counts. A process that seems to have outlived the host
  is first only marked (`heldAt`), and the chat dropped when a look a
  minute on still finds it: the overlay's live list is up to 10 s old, so
  the old host's own process, killed, can read as alive for a moment. A
  last message that cannot be read keeps the chat for a later look. The
  whole transcript is read for background work only once the cheap checks
  on its tail left the chat in. The row is a cut-off row with `Why` `restart`,
  its `LimitUuid` the last message's uuid, plus `Mid` and `Tasks`.
- **The ask.** [Get-ChatqResetAsk](../src/queue.ps1) takes a restart row at
  once - no reset to wait for, no 5-minute hold - and counts it as
  `Restart`; while a window is limited it still asks nothing.
  [Format-ChatqAskHead](../src/queue.ps1) words it `VS Code restarted`, or
  `limit over at 13:00, and VS Code restarted` with both, on every surface
  the ask has on Windows - the banner, the tray's balloon, the console, the
  phone. The Mac menu's wording follows it too, but no restart chat is
  ever found there. The ask runs only on an overlay that is running, with
  `autoContinue` not `off`; with it off the chats are orange rows alone
  (`cutOff`). The answer marker carries `why: restart`
  ([Get-ChatqAskExtra](../src/auto-continue.ps1)). Leaving them drops them
  from their note, so their rows go, where a limit's stay orange
  ([Format-ChatqAskLeaveTip](../src/queue.ps1) words the tooltip by which).
- **Never by itself.** With `autoContinue` `on` the ask still runs, for the
  restart's chats alone (`-RestartOnly`), and a chat set to `always` is
  asked too: [Get-ChatqAutoState](../src/auto-continue.ps1) gives it the
  state `restart` (`cut off - VS Code restarted`), which the scan never
  queues. A reload is not a limit: what was cut off may have been a
  command you meant to stop.
- **The continue.** [Invoke-ChatqContinueChats](../src/commands.ps1) makes
  a `prompt` job, rule `restart`, in the chat's own mode, with
  [Get-ChatqRestartPrompt](../src/queue.ps1)'s text - the window restarted
  mid-turn, the workflow or agent by name that did not finish, since
  `claude --resume` brings back the chat but not its background work - and
  the cut-off's uuid as `restartUuid`. [Get-ChatqJobs](../src/queue.ps1)
  sorts it with the continues, ahead of other prompts, and
  [Invoke-ChatqJob](../src/watcher.ps1) skips it if the chat went on first.
- **Not found.** A reload no chatq look came before - Developer: Reload
  Window, the Extensions view's Restart Extensions, another extension's or
  VS Code's own update - leaves no note (FUTURE_WORK.md, "Continue the
  chats a reload stopped").

## What there is today

**How a cut-off chat is found.**
[Get-ChatqCutOffChats](../src/queue.ps1) walks the transcripts in
`~/.claude/projects/*/` that changed in the last `$Hours`. For each one,
[Get-ChatqLastTurn](../src/queue.ps1) reads the last record that carries a
message. A chat is cut off when that record is Claude's synthetic error
turn. It is a limit when `error` is `rate_limit`, or when an
`isApiErrorMessage` says "hit your ... limit". It is a 529 when
`apiErrorStatus` is 500 or more, or the text matches `$script:ChatqOverloadRx`.
The reset comes from the record's `quotaLimits.resetsAt`. The scan skips
chats a job is queued or running for, and chats its caller names as
working (`-Skip`). Only the default Claude home is scanned
(`$script:ChatClaudeHome`), never a `CLAUDE_CONFIG_DIR` account. Codex is
never scanned. Each row has `Id`, `Title`, `Group`, `At`, `ResetsAt`,
`Why` (`limit` or `overloaded`), `Path` and `Cwd`.

**Where it shows.**
- **The overlay** runs the scan once a minute in
  [Invoke-ChatOverlayCycle](../src/overlay-data.ps1), with a cache. It
  runs again at once when a chat's status or the queue changes. It looks
  back 168 hours and keeps a cut-off while its reset is ahead, or while it
  is under 12 hours old. [Get-ChatOverlayRows](../src/overlay-data.ps1)
  turns an open idle chat orange (rank 0.5). A chat that is not open gets
  a row of its own (`kind` `cutoff`). A chat a job is queued for loses the
  orange row to the job's row. [Format-ChatOverlayCutOff](../src/overlay-data.ps1)
  writes `cut off - resets 13:00`, `cut off - resets Mon 13:00`,
  `cut off - limit over`, or `529 - waits for Claude`.
  `overlay.cutOff: false` turns the rows and the scan off. (Since 0.9.0 a
  cut-off stays while its reset is under 12 hours ago, too, and the scan
  runs with `cutOff` false while the ask is on.)
- **The console** ([Get-ChatConsoleChatItems](../src/console.ps1)) lists
  those rows under **Cut off**. Each has **Continue**, and the section has
  **Continue all**. [Invoke-ChatConsoleContinue](../src/console.ps1) makes
  one `kind continue` job per chat and skips a chat that already has a job.
- **`chatqlist`** ([Write-ChatqList](../src/alerts.ps1)) prints
  `cut off, nothing queued: <title> (limit 12:40), ...` and the hint
  `chatq '<title>' -Continue queues a continue for one`.
- **`chatq <title> -Continue`** ([chatq](../src/commands.ps1)) queues the
  same job. [Write-ChatqJobInfo](../src/commands.ps1) warns when the chat
  was not cut off.

**What the watcher does with it.** A `continue` job waits for its lane
like any job: [Get-ChatqDueTime](../src/watcher.ps1) makes it due one
minute after the lane's reset. Then [Confirm-ChatqAllowed](../src/watcher.ps1)
probes. [Invoke-ChatqJob](../src/watcher.ps1) then checks whether the chat
moved on (`$checkStop`). A job of `kind continue`, or one the watcher
itself turned into a continue (`retryAs continue` with the job field
`autoContinue`), is completed `skipped`, "already continued - by you or by
Claude's own auto-continue", when the chat's last turn is no longer a
limit or a 529. A requeue you asked for ([Reset-ChatqJob](../src/commands.ps1))
clears the job field `autoContinue` and is sent regardless. Note that a
`chatq -Continue` job is `kind continue`, so it is dropped if the chat moved
on. The README's "one you asked for is always sent" means `chatqrun <n>`.

**The watcher's own continue.** When a run of its own ends `limited`,
`overloaded`, `network` or `auth`, [Test-ChatqPromptLanded](../src/queue.ps1)
checks whether the prompt reached the chat after `startedAt`. If it did,
the job comes back with `retryAs continue`, so the prompt is never sent
twice. After a limit or a 529 the job field `autoContinue` is set, so the
moved-on check applies. After `network` or `auth` it is cleared, since those
leave no record that would show the chat moved on. The job goes back to
`queued`, with "limited mid-run, continues at 13:00", and a `limited` alert.
`noProgress` stops a job after `maxRetries` (5) runs in a row with no reply.

**A 529.** For a run of chatq's own: the job is requeued,
[Enter-ChatqOutage](../src/watcher.ps1) watches status.claude.com every
minute, and the job is retried when it shows `operational`. It is also
retried after 1, 2, 5 and 10 minutes, then every 15. One alert is sent,
and a reminder after 6 hours. For a chat chatq did not run: with
auto-continue off or on Ask, the overlay row says `529 - waits for
Claude`, and nothing is queued; switched on, the scan queues a continue
for it as for a limit (see [After a 529](#after-a-529)).

**Chats you run yourself, on the phone.** [Update-ChatqLiveAlerts](../src/phone.ps1)
sends `done` when a chat goes from busy to idle while you are away.
[Get-ChatqLiveAlertText](../src/phone.ps1) words a turn the limit cut off
as `<title> · stopped by the usage limit until 13:00`. Its link is
`j=live`, and the page offers only **Send** and **Status**.

**Showing the chat afterwards.** A run into a chat a VS Code window holds
ends with [Show-ChatFresh](../src/chatrm.ps1) `-Via run`. The window shows
the chat by itself when you are away. Otherwise it asks, "A queued prompt
ran in X, which this window still has open. Show it?"
([message](../extension/extension.js)). The next run into that chat waits
out [Get-ChatShowHold](../src/chatrm.ps1).

## Claude Code's own auto-continue

"Claude's own auto-continue" in the code and the README is a Claude Code
feature. Read on 2026-09-26 from code.claude.com: *Wait for a usage limit
to reset* (interactive-mode), *You've hit your session limit* (errors),
`autoContinueAtUsageLimit` (settings reference), and *Week 33* (what's new).

**Confirmed by the docs:**
- **v2.1.234 and later.** "Claude Code waits in the open session and
  continues the task on its own after the limit resets." It is on by
  default "in interactive sessions signed in with a claude.ai
  subscription". It shows `Usage limit reached · continuing automatically at 3:45pm · esc to cancel`.
- **What it sends.** "a fixed prompt to pick the task up where it stopped.
  It doesn't resend your last message."
- **It gives up.** It re-arms at most twice in a row, then shows
  `Automatic continue stopped after repeated usage-limit hits · /rate-limit-options to try again`.
- **Setting.** `autoContinueAtUsageLimit` (default `true`), shown in
  `/config` as **Continue automatically at usage limit**. It is read from
  user, `--settings` and managed settings only.
- **When it does not wait:**
  - resets more than 24 hours away (a weekly limit);
  - an Opus or Sonnet limit while another family's model runs;
  - Remote Control and agent-team sessions;
  - background sessions and `-p` runs (so never chatq's own runs).
- **When the wait ends without a continue:** you send a prompt, you exit
  Claude Code ("the wait doesn't restart when you resume the session"),
  the conversation changes hands, or a `UserPromptSubmit` hook blocks it.
- **After sleep.** If the PC slept for more than about 30 minutes past the
  reset, it asks for Enter instead of continuing.
- **Claude Desktop** has its own **Auto-continue when limits reset**
  checkbox on the session-limit card. It resends the interrupted turn.

**Not confirmed:**
- **Whether a VS Code panel chat does this.** The docs never mention the
  extension, and the wait is a line in the terminal UI. The README's
  comparison row, "Claude Code's own auto-continue: the one open chat",
  and its "Claude's own auto-continue is running it" are older claims.
  Spike A1 settles it.
- **The exact text.** [queue.ps1](../src/queue.ps1) says Claude Code
  writes an `isMeta` user message reading `Continue from where you left off.`
  (`$script:ChatqContinueText`). The docs say only "a fixed prompt".
  Spike A2 checks the text on 2.1.234 or later.

**What it cannot do**, and what this spec is for:
- continue a chat nobody has open: a closed tab, a closed window, or a
  terminal that was exited;
- continue a chat whose process chatq ended;
- continue after the PC slept;
- say so on the phone.

## Which chats

| chat | auto-continued? | why |
|---|---|---|
| Claude chat not open anywhere (tab or window closed, terminal exited) | **yes** | the main case: nothing else will continue it |
| Claude chat open in a VS Code panel, idle | **yes**, 5 minutes after the reset | the panel may continue it itself (A1). If it does, chatq's job finds it moved on and is skipped |
| Claude chat open in a terminal's `claude` | **no**, while that terminal holds it | Claude Code's own wait is there, or you turned it off there. A headless run would make two writers. Once that `claude` exits, the chat is a candidate |
| Claude chat held by any other registry entry (a background session, `claude -p`, anything with a `kind` other than `interactive`) | **no** | two writers |
| a side chat (subagent) | **no** | the scan only reads top-level transcripts |
| Claude chat under another `CLAUDE_CONFIG_DIR` | **no** | not scanned (out of scope) |
| Codex chat | **no** | no scan exists. A Codex job chatq ran is already continued by the watcher |
| Copilot chat | **no** | nothing can resume one |
| any chat cut off by a **529** | **yes**, once Claude is back | the job waits as the watcher waits out its own 529 (see [After a 529](#after-a-529)) |

## Behaviour

### When a continue is queued

[Invoke-ChatqAutoContinueScan](../src/queue.ps1) (new) takes the rows of
[Get-ChatqCutOffChats](../src/queue.ps1) and the live registry entries,
and queues one continue for each cut-off that passes **every** check below.
In order, each failed check has the state it leaves the chat in (see the
state table):

1. **The setting.** Auto-continue is on for the chat: the chat is set to
   `always`, or it is not set to `never` and the global switch is on.
   Otherwise the state is `off` or `never`.
2. **A limit or a 529.** `Why` is `limit` or `overloaded`. A 529 with
   the switch not on (and the chat not `always`) keeps the row it always
   had, state `overloaded`, since Ask is for the limit only.
3. **Not open elsewhere.** No live registry entry holds the session,
   except an `interactive` one whose entrypoint is `claude-vscode`.
   Otherwise the state is `terminal`.
4. **Nothing queued for it.** No job for the chat is `queued` or
   `running`. The scan already skips those.
5. **New enough.** Three checks:
   - the limit record is newer than the first time auto-continue ran on
     this PC (`since`);
   - it is at most 12 hours old;
   - the reset is at most 24 hours after the record. A weekly limit days
     out is left to you, as Claude Code leaves it.
   Otherwise the state is `far`.
6. **Seen in time.** Either the reset is still ahead, or it passed at most
   30 minutes ago. A cut-off first seen long after its reset is one you
   came back to: it is left to you, as Claude Code asks for Enter after a
   sleep. Otherwise the state is `late`.
7. **Once per cut-off.** No marker exists for this cut-off. A cut-off is
   the session id plus the `uuid` of its limit record, which becomes
   `LimitUuid` on the scan's row. The marker is made before the job, with
   an exclusive create. So the overlay and the watcher never both queue
   one, and a continue you removed never comes back for the same cut-off.
   Otherwise the state is `declined` or `failed`.
8. **Not stuck.** Fewer than 2 auto-continues in a row for this chat ended
   `failed`. This is the same limit Claude Code uses. Otherwise the state is
   `stopped`.

The job is the one `-Continue` makes: [New-ChatqJob](../src/commands.ps1)
with `-Kind continue -Rule auto`, in the chat's own mode and model, ahead
of the prompts waiting and behind the continues queued before it -
[Get-ChatqJobs](../src/queue.ps1) sorts every continue there. (Built at
the back of the queue; moved ahead after 0.10.2.) It gets two new fields:

- `auto: true`, the job auto-continue made;
- `cutUuid`, the limit record's `uuid`.

The job field `autoContinue` keeps its old meaning ("the watcher made this
continue; drop it if the chat moved on"). A comment in
[New-ChatqJobRecord](../src/commands.ps1) says it is not the setting.
`kind continue` already turns on the moved-on check.

**When it runs:** a minute after the reset, as every job does
([Get-ChatqDueTime](../src/watcher.ps1)). Two differences:

- **A chat open in a VS Code panel** gets 5 minutes, not 1. The first time
  the watcher reaches the job, [Get-ChatqAutoHold](../src/watcher.ps1) (new)
  sees the chat live in a `claude-vscode` entry. It sets `deferUntil` to
  reset + 5 minutes and `deferWhy` to `vscode`. The same check runs at queue
  time, so the ETA says it from the start. This gives the panel's own
  auto-continue room to go first, if it has one (A1). Constant:
  `$script:ChatqAutoHoldMinutes = 5`.
- **A chat that is gone** by then is completed `skipped`, "the chat is
  gone", with no `failed` alert. It was never your job.

**Who scans.**
- **The overlay**, in [Invoke-ChatOverlayCycle](../src/overlay-data.ps1)
  right after the cut-off scan, when `$Ctx.WantAuto` is set. That is the
  Windows and macOS hosts, never `chatoverlay -Print` or a `-Peek` pass.
  It asks for the watcher with [Request-ChatqWatcher](../src/commands.ps1)
  `-Wake poke`. The scan runs when `overlay.cutOff` is false too, as long as
  auto-continue is on for anything. Then it draws no rows.
- **The watcher**, every 5 minutes in [Invoke-ChatqWatchLoop](../src/watcher.ps1),
  with a cache of its own (`$W.CutCache`). This covers a watcher already
  running for other jobs while the overlay is closed.
- **Nobody else.** A shell starting, `chatqlist` and `chatq` never queue.
  With no overlay and no watcher running, nothing is auto-continued, and
  `chatqlist` says so (below).

**The global switch does not touch chatq's own jobs.** A prompt you queued
that the limit cuts off mid-run still comes back as a continue. You asked
for that run to finish. Auto-continue is only about chats chatq did not
start. The README says so in one line.

### When a queued continue does not go

| what happened | what the watcher does | said where |
|---|---|---|
| you, or Claude Code's own wait, continued the chat | `skipped`, "already continued - by you or by Claude's own auto-continue" (unchanged) | `jobs.log`, the console's queue |
| the chat is working at run time | deferred, looked at again every 5 min (unchanged) | row: `#12 auto-continues 13:10 (chat busy)` |
| the chat was deleted (`chatrm`) or archived | `skipped`, "the chat is gone", no alert | `jobs.log` |
| you removed it (chatq, console, chip, phone) | gone. The marker stays, so this cut-off is not queued again | row: `· not continued` |
| the chat was set to `never` meanwhile | its `auto` jobs are removed at once by [Set-ChatqAutoChat](../src/queue.ps1) (new) | the command's own line |
| the global switch went off meanwhile | queued `auto` jobs are **kept**: they are on screen and each can be removed. Only new cut-offs stop | the command's line says how many are kept |
| the run hit the limit again at once | requeued, `noProgress` +1 (unchanged). When it gives up, `failed`, and the chat's streak +1 | `failed` alert, "gave up: ..." |

**Closing a chat's tab or window does not cancel.** That is when the
continue is most wanted. **Deleting or archiving does.** `chatrm` drops a
chat's `auto` jobs without `-DropJobs`, and says `dropped #12, its auto-continue`.
A chat with a job you queued is still kept, as today.

## States

[Get-ChatqAutoState](../src/queue.ps1) (new, pure) returns
`@{ State; Words; Job }` for one cut-off. It takes the cut-off row, the
jobs, the live entries, the settings, the markers and `-Now`. The overlay,
the console and `chatqlist` all word a chat from it.

| state | overlay row, right side | enters when | leaves when |
|---|---|---|---|
| `armed` | `#12 auto-continues 13:01` | the scan queued the job, reset ahead | the reset passes → `due` |
| `due` | `#12 auto-continues next` / `after #3` / `13:05 (open in VS Code)` / `13:10 (chat busy)` | reset passed; waiting on the probe, the queue, the VS Code hold or a busy chat | the run starts → `running` |
| `running` | `#12 running` (blue, unchanged) | the watcher runs it | `done` / `skipped`: the row goes. `limited` again: `due`. `failed`: `failed` |
| `failed` | `cut off - resets 13:00 · auto-continue failed` | the job ended `failed` and the chat is still cut off | a new cut-off, or you continue it |
| `declined` | `cut off - resets 13:00 · not continued` | its marker exists and its job was removed or skipped | a new cut-off (new `uuid`) → `armed` |
| `off` | `cut off - resets 13:00` (as today) | the global switch is off, and the chat is not `always` | the switch goes on → the next scan queues it if the other checks pass |
| `never` | `cut off - resets 13:00 · never auto` | the chat is set to `never` | set to `default` or `always` |
| `terminal` | `cut off - resets 13:00 · in a terminal` | a terminal's `claude`, or any non-panel entry, holds it | that process exits → the next scan |
| `far` | `cut off - resets Mon 00:00 · by hand` | reset over 24 h after the record, record over 12 h old, or before `since` | not by itself |
| `late` | `cut off - limit over · by hand` | first seen over 30 min after its reset | not by itself |
| `stopped` | `cut off - resets 13:00 · auto stopped` | 2 auto-continues in a row failed | a turn in the chat ends without a limit (the streak resets), or `-AutoContinue always` again |
| `overloaded` | `529 - waits for Claude` (unchanged) | a 529, the switch not on, the chat not `always` | the switch goes on → the next scan queues it if the other checks pass |

In `armed` and `due`, the row stays **orange** at rank 0.5, not the purple
of a queued job. It is still a cut-off chat, and the words say what will
happen to it. For a chat not open, it is the `kind cutoff` row, carrying
the job. For an open one, it is the session row. The job gets no row of its
own. [Get-ChatOverlayRows](../src/overlay-data.ps1) leaves an `auto` job
on its chat's cut-off row instead of taking the row away. The counts, the
collapsed line and the tray still count it as `cut off`.

## After a 529

Built 2026-10-01. A 529 has no reset time, so the checks above run with
the cut-off's own time in its place:
[Get-ChatqAutoState](../src/auto-continue.ps1) takes `Why` `overloaded`
as a cut-off to continue once the switch is on (or the chat is `always`);
`far` skips the reset checks, and `late` is over 30 minutes after the 529
itself. The words: a `ready` row still reads `529 - waits for Claude`,
its long line `cut off by a 529 · auto-continue queues it`; `due` is
`#12 auto · 529`, and its tooltip says it auto-continues when Claude is
back. A removed job leaves it `declined`
for this 529 only.

[New-ChatqAutoJob](../src/auto-continue.ps1) writes the marker with `why`
`overloaded`, `cutAt` the 529 and `resetsAt` null, and the job's history
note `auto - 529 13:02`. [Get-ChatqAutoHold](../src/auto-continue.ps1)
holds a panel chat 5 minutes after the 529, not after a reset.

The watcher: before it probes for such a job,
[Confirm-ChatqAllowed](../src/watcher.ps1) calls
[Enter-ChatqAutoOutage](../src/auto-continue.ps1), which puts the lane in
an outage as if the watcher had seen the 529 itself - `Since` now, so the
6-hour reminder counts from here, and `LastProbe` the 529, so
[Test-ChatqOutageOver](../src/watcher.ps1) lets the job go when
status.claude.com says Claude Code is `operational`, or 15 minutes after
the 529. No alert: the 529 was the chat's, and it was seen there. Not
when the lane is in an outage already, nor when a probe said allowed
since the 529, nor when the chat no longer stands where the 529 left it
([Get-ChatqAutoCutTurn](../src/auto-continue.ps1): the transcript there,
its last turn a 529, and that turn the job's `cutUuid`). That last check
is needed because the outage starts before
[Invoke-ChatqJob](../src/watcher.ps1)'s own moved-on, chat-gone and
terminal checks: a chat you retried in the panel - the usual case - would
otherwise hold every Claude prompt on the account for a job then skipped.
Other Claude jobs on that lane wait with it, as in any outage. The outage
keeps the job's id (`AutoJob`, carried over a handover), and
[Clear-ChatqAutoOutage](../src/auto-continue.ps1), first in each
Confirm-ChatqAllowed, ends it once that job is no longer queued (Don't
continue, run, skipped) or its chat has moved on.
[Enter-ChatqOutage](../src/watcher.ps1) drops `AutoJob` when a probe meets
a 529 itself: from then on the outage is the watcher's own, and stays.
The moved-on check is the one a limit has: a chat you continued yourself
is skipped.

## The settings and their files

- **`data/config.json`, `autoContinue`**: a string, `"ask"` (the default),
  `"on"` or `"off"`. The global switch.
  It sits at the top level, beside `liveIdle` and `maxRetries`, and not
  under `overlay`, because the watcher reads it too. `false` reads as
  `"off"`, `true` and anything unknown as `"ask"`
  ([Get-ChatqAutoContinue](../src/queue.ps1)).
  [Set-ChatqAutoContinue](../src/queue.ps1) is the one writer for every
  surface.
- **`data/auto-continue.json`**, written by
  [Save-ChatqAutoState](../src/auto-continue.ps1) through `Save-ChatqJson`:

  ```json
  {
    "v": 1,
    "since": "2026-09-26T04:00:00.0000000Z",
    "noticed": true,
    "chats": {
      "1a2b3c4d-0000-4000-8000-000000000001": { "auto": "never", "at": "2026-09-26T05:10:00Z", "title": "Parser rewrite and plugin unification" }
    },
    "streak": { "1a2b3c4d-0000-4000-8000-000000000002": 1 }
  }
  ```

  - `since` is written as the switch turns to `on`, and by a scan that
    finds none (the switch set by hand, or a chat set to `always`).
  - `chats.<id>.auto` is `always` or `never`. `default` removes the entry.
    `title` is only there so a person reading the file knows the chat.
- **`data/auto/<sessionId>_<limitUuid>.json`**: one marker per cut-off,
  shared by both modes and named by [Get-ChatqCutKey](../src/queue.ps1)
  (the record's UTC ticks stand in for a missing `uuid`), made with
  `FileMode.CreateNew`. The ask writes them now through
  [Save-ChatqAskAnswer](../src/queue.ps1):
  `{ at, answer, source, seq }`, where `answer` is `continue` or `leave`,
  `source` is `overlay`, `console` or `mac`, and `seq` the jobs it made.
  This mode's [New-ChatqAutoMarker](../src/auto-continue.ps1) writes the
  same shape, `answer` `continue` and `source` `overlay` or `watcher`, with
  `sessionId`, `cutUuid`, `cutAt`, `resetsAt` and `jobId` beside it, and
  treats a marker the ask wrote as already decided: `leave` is its
  `declined`, `continue` already has its job. A marker whose job could not
  be made holds `error` instead.
  That cut-off is never tried again, and the reason is logged once.
- **`data/auto/<key>.shown`**: an empty file once an ask about that
  cut-off was announced (toast, notification, phone), so a restarted
  overlay does not announce it again ([Add-ChatqAskShown](../src/queue.ps1)).
  Both kinds are deleted once over 8 days old, by any read of either
  ([Read-ChatqAskState](../src/queue.ps1), [Read-ChatqAskShown](../src/queue.ps1)).

Nothing is written outside `data/`.

## Every surface

### The overlay

**The row.** A chat the limit cut off, with a continue queued:

```
 Claude  5h 100% · week 46%                                       12:41
 ● ▭  api     Rate limiter                                   needs you
 ● ▭  parser  Parser rewrite and plu…         #12 auto-continues 13:01
      unify the parser entry points
 ●    cards   Card layout redesign     cut off - resets 13:00 · never auto
 ● >_ infra   Deploy script         cut off - resets 13:00 · in a terminal
 ● ▭  web     Search box                                          idle

 the middle three dots are orange (cut off); ▭ a VS Code panel, >_ a terminal
```

**The chip.** Resting on a cut-off row brings up the chip window, as
`open` does today. It now holds one or two chips, right-aligned:

```
 ● ▭ parser   Parser rewrite and plu… [ don't continue ][ open ]
 ●   cards    Card layout redesign      [ continue ][ open ]
```

- **don't continue**, on an `armed` or `due` row. It removes the `auto`
  job through [Remove-ChatqJob](../src/commands.ps1) `-By chip`. The marker
  stays, so the row turns `· not continued`, and the chip becomes
  **continue**, which undoes it. Tooltip:
  "Don't send "continue" to this chat after this reset. The next time the
  limit cuts it off, it is continued again - chatq '<title>' -AutoContinue never stops that."
- **continue**, on an `off`, `never`, `declined`, `failed`, `stopped`,
  `far` or `late` row. It queues a continue now, as the console's
  **Continue** does ([Invoke-ChatConsoleContinue](../src/console.ps1)).
  That is a job you asked for: `auto` false, and no marker. Tooltip:
  "Queue "Continue from where you left off." for this chat - it goes when the limit is over."
- None on a `terminal` or `running` row, beyond `open` where it applies.
- A click goes through the same arming as `open`
  ([Step-ChatOverlayChipState](../src/overlay-windows.ps1)), so a pointer
  parked on the spot never removes anything. The tray balloon confirms
  it: "Parser rewrite… will not be continued after this reset." or
  "Queued #13, a continue for Parser rewrite…".
- [Test-ChatOverlayRowOpenable](../src/overlay-windows.ps1) stays as it is.
  [Get-ChatOverlayChipActions](../src/overlay-windows.ps1) (pure, built in
  0.9.0 for the ask's banner and `open`) returns the chips for a row; this
  mode adds the auto chip by the row's `auto.state`. A cut-off row with no
  `cwd` still gets its auto chip. [New-ChatOverlayChipContent](../src/overlay-windows.ps1)
  already draws from that list, each chip with its own tooltip and arming.

**The settings box** has a seventh row since 0.9.0, **Cut off**, with
**Ask** and **Leave** ([Set-ChatOverlayAutoChoice](../src/overlay-windows.ps1)).
This mode makes it three chips, **Continue**, **Ask** and **Leave**, once
`"on"` exists; what follows is written for that row:

```
 ┌ settings ──────────────────────────────┐
 │ Opacity  ───────────●────────    94%   │
 │ Width    ─────●───  380  Rows ──●── 8  │
 │ Theme    [Dark] [Light] [System]       │
 │ Usage    [Lines] [Bars]                │
 │ Style    [Full] [Compact]              │
 │ Recent   [Off] [5] [10]                │
 │ Cut off  [Continue] [Ask] [Leave]      │
 └────────────────────────────────────────┘
```

- The label is `Cut off`, and the chips are `continue`, `ask` and `leave`,
  drawn as **Continue**, **Ask** and **Leave** by [New-ChatOverlayChips](../src/overlay-windows.ps1).
  Ask's tooltip stays as built: "Once the limit is over, say how many chats
  it cut off, and continue them on a click."
- The label's tooltip: "A chat the usage limit cuts off: Continue sends it
  "Continue from where you left off." a minute after the reset - after a
  529, once Claude is back. Ask says so once the limit is over, and
  continues it if you say so. Leave only marks it orange." (Built today
  without the Continue sentence.)
- [New-ChatOverlayChips](../src/overlay-windows.ps1) gains `-Tips`, a
  tooltip per chip:
  - Continue: "Continue each chat the limit cuts off, by itself."
  - Leave: "Only mark them - Continue in the console, or chatq '<title>' -Continue, queues one."
- A click runs [Set-ChatOverlayAutoChoice](../src/overlay-windows.ps1)
  (built for Ask and Leave; `continue` maps to `on`), which calls `Set-ChatqAutoContinue`. It is kept in `config.json`
  and drawn at once, like the other rows.

**The tray menu** already has, since 0.9.0, **Continue N cut-off chats**
and **Leave them** at its top while an ask is pending. This mode adds a
checked item under **Phone alerts...**:

```
  Open console
  Phone alerts...
✓ Auto-continue cut-off chats
  ─────────────
  VS-code-chat-manager 0.9.0
```

Its tooltip: "A minute after the limit resets, send "continue" to each
chat it cut off". [Update-ChatOverlayMenu](../src/overlay-windows.ps1)
keeps the check in step with `config.json`.

**macOS** gets the words on the rows, and a menu item
`Auto-continue cut-off chats` in the `CQ` menu. There is no chip there, as
today.

### The console

**The Cut off list.** Each item's state words come from
`Get-ChatqAutoState`. The button at the right follows the chip: **Don't
continue** on `armed` and `due`, and **Continue** otherwise. The section
header shows how many will auto-continue, beside **Continue all**:

```
 Cut off (3) · 1 auto-continues                  [Continue all]
 ┃● ▭ parser  Parser rewrite and plu…  #12 auto-continues 13:01  [Don't continue]
  ●   cards   Card layout redesign   cut off - resets 13:00 · never auto  [Continue]
  ● >_ infra  Deploy script          cut off - resets 13:00 · in a terminal  [Continue]
```

- **Continue all** skips chats already `armed`. They have a job.
- **Don't continue** needs no second click, since **Continue** undoes it.
  The status line says "#12 removed - Parser rewrite… will not be
  continued after this reset".

**The per-chat switch.** A Claude chat picked in the list (cut off, open,
or recent) gets a line under the target line:

```
 To  Parser rewrite and plugin unification · auto · D:\src\parser
 Auto-continue after a limit   [Default (on)] [Always] [Never]
```

- The **Default** chip names what the global switch says now:
  `Default (on)` or `Default (off)`.
- Tooltips:
  - Default: "Follow the setting in the panel's settings box."
  - Always: "Continue this chat after every limit or 529, even with the switch on Ask or Leave."
  - Never: "Never continue this chat by itself; its orange row stays until you do."
- A click runs [Set-ChatqAutoChat](../src/queue.ps1). **Never** also
  removes a queued `auto` job for the chat, and the status line says so.
- Hidden for a Codex chat and for **+ New chat**.

**The queue pane.** An `auto` job's words
([Get-ChatConsoleJobStatus](../src/console.ps1)) are
`auto-continues 13:01`. Its detail says "queued by auto-continue: the limit
cut this chat off at 12:40, and it resets at 13:00". **Remove** reads
**Don't continue** for an `auto` job, still clicked twice as today.

### The CLI: `chatq -AutoContinue`

```powershell
chatq -AutoContinue on                       # every chat the limit cuts off
chatq -AutoContinue off                      # none - they are only marked
chatq 'Parser rewrite' -AutoContinue never   # this chat: never
chatq 'Parser rewrite' -AutoContinue always  # this chat: even with it off
chatq 'Parser rewrite' -AutoContinue default # this chat: follow the switch
chatq 12 -AutoContinue never                 # the chat of job 12; drops #12 if it is an auto one
```

**Why on `chatq`.**
- The per-chat form needs a chat picked by title, with Tab completion and
  the pick printed, and only `chatq` does that
  ([Resolve-ChatqTarget](../src/commands.ps1)).
- `-Continue` already lives there, and this is its automatic form.
- `chatqrun` is about the watcher and job numbers.
- `chatnotify` is about alerts.
- A new command is one more name to learn and to put in the profile.
- With no title, the switch is global. That follows `chatq` alone
  showing the cheat sheet and the queue.

**Built** (0.9.0), the ask's first and then widened as below
([Invoke-ChatqAutoCommand](../src/auto-continue.ps1)): every line it prints
for the switch reads `auto-continue: on|ask|off - ...`, and it tells a
running overlay. The lines below are the spec's first wording; the colon
is the built one.

**The parameter:** `[ValidateSet('on', 'ask', 'off', 'always', 'never', 'default')][string]$AutoContinue`.
- `on`, `ask` and `off` only work without a title. With one, it says
  `-AutoContinue on|ask|off is the switch for every chat - for this one, always|never|default`.
- `always`, `never` and `default` need a title or a job number.
- With `-Prompt`, `-Continue`, `-Attach`, `-Paste`, `-At` or `-In`, it
  refuses: `-AutoContinue sets a switch and queues nothing - run it on its own`.
- `-WhatIf` shows the pick and changes nothing.

**What it prints**, with the colours `chatq` uses:

```
PS> chatq -AutoContinue off
  auto-continue off - chats the limit cuts off are only marked; chatq <title> -Continue queues one
    1 already queued is kept: #12 Parser rewrite… (chatqrm 12 drops it)
    1 chat set to always is still continued: Card layout redesign

PS> chatq -AutoContinue on
  auto-continue on - a chat the limit cuts off gets "continue" a minute after the reset
    chatq <title> -AutoContinue never keeps one out

PS> chatq 'Parser rewrite' -AutoContinue never
  -> 'Parser rewrite and plugin unification' (2h)  claude · contains
  'Parser rewrite and plugin unification': never auto-continued
    dropped #12, its auto-continue

PS> chatq 'Card layout' -AutoContinue always
  -> 'Card layout redesign' (1h)  claude · contains
  'Card layout redesign': always auto-continued, even with auto-continue off
```

**Where the state shows:**
- `chatq` alone (the cheat sheet) gets
  `chatq [<title>] -AutoContinue on|off|never  continue what the limit cuts off, by itself`.
- The comment-based help gets `.PARAMETER AutoContinue`.
- A Codex chat gets `auto-continue is for Claude chats - a Codex job chatq runs is continued anyway`,
  and nothing is saved.

### `chatqlist` and the board

- **A job line.** An `auto` job's prompt column reads `continue (auto)`.
  Its "sends" column is the ETA as for any job.
- **A new line under the usage line**, printed only when there is a
  cut-off chat, an `auto` job, a chat set to `always` or `never`, or the
  switch is off:
  - `  auto-continue on · 1 chat never · 1 always`
  - `  auto-continue off · chatq -AutoContinue on turns it on`
  - `  auto-continue on - but nothing is watching for cut-off chats: chatoverlay starts the overlay`
    (Yellow). This is printed when no overlay and no watcher runs.
- **The cut-off line** tags each chat that is not continued with its state,
  as in the row words. The hint line stays:

  ```
  cut off, nothing queued:  Card layout redesign (limit 12:40, never auto), Deploy script (limit 12:38, in a terminal)
  ```

- **The board** (`data/queue.md`, [Write-ChatqBoard](../src/alerts.ps1))
  shows `continue (auto)` in the prompt column. The job's section line
  reads `... · picked by auto`.

### The phone

**The alert.** When a chat you run yourself is cut off by the limit and a
continue was queued for it,
[Update-ChatqLiveAlerts](../src/phone.ps1) sends event **`limited`**
(priority 0) about the `auto` job. It sends this in place of today's `done`
about the live chat. The link then carries `n=12` and `j=queued`:

```
chatq · limited
Parser rewrite and plugin unification · stopped by the usage limit · auto-continues 13:01
```

- **Only when you are away,** as every live alert.
- **Order.** In one collector pass, the cut-off scan and the auto scan
  run before the live alerts. A `done` fires 5 s after busy→idle, so the
  job is already there. When no job was queued, the alert stays `done`
  with today's words and the state added:
  `... · stopped by the usage limit until 13:00 · never auto`.
- **Events.** A `-Events` list that leaves out `limited` now drops this
  alert, where it used to go as `done`. The CHANGELOG says so.

**The page** ([docs/reply.html](reply.html), `buttonsFor`) gets one case.
For `e === 'limited'` and `job === 'queued'`, it shows **Send**, **Don't
continue** and **Status**:

```
 ┌──────────────────────────────────────┐
 │ chatq · limited   #12                │
 │ Parser rewrite and plu…              │
 │ ┌──────────────────────────────────┐ │
 │ │ Next prompt - goes after the     │ │
 │ │ continue                         │ │
 │ └──────────────────────────────────┘ │
 │ [ Send ]                             │
 │ [ Don't continue ]  [ Status ]       │
 └──────────────────────────────────────┘
```

- **Don't continue** is `{ act: 'skip', label: "Don't continue", confirm: 'Tap again - it will not continue' }`.
  It is an act the watcher already knows, so **no new act and no wire
  change**. It still needs the two taps, half a second apart.
- The same case covers a `limited` alert about a job chatq ran: there it
  skips your job. The label is true for both.
- The placeholder is `Next prompt - goes after the continue`.
- [Invoke-ChatqReply](../src/phone.ps1) `skip` on an `auto` job answers
  `#12 skipped - Parser rewrite… will not be continued after this reset`.
  Its marker stays, so the next scan does not queue it again.

**The phone cannot turn auto-continue on or off,** for all chats or one.
- Turning it **on** grants unattended runs. Claude Code refuses even
  `/config autoContinueAtUsageLimit=true` for that reason, and a reply
  never widens what runs (the `reply.maxMode` rule).
- Turning it **off** from a phone that may not be yours would be a quiet
  way to stop work.
- **Don't continue** acts on one cut-off, and only a paired phone's MAC'd
  reply gets there. That is as far as the phone goes.
- The settled phone choices all hold: no key in any push, MAC-verified
  replies, the `reply.maxMode` cap, pairing by code, and the rate limits.

### The phone setup window: not there

`chatnotify -Setup` ([Start-ChatqPhoneSetup](../src/phone-setup.ps1)) sets
up where alerts go and who may answer them. Auto-continue decides what
runs. It would be a fourth place for the same switch, in a window about
something else. The window's **What reaches the phone** boxes already
include `limited`, which is the alert this adds to. So the only change
there is the tooltip of the `limited` box: "the limit came back mid-run,
or cut off a chat you run yourself that auto-continue will continue".

### VS Code

- **No `chatManager.*` setting.** `config.json` is the one store, as for
  `overlay.autoStart`. A VS Code setting is per profile, could disagree
  with the overlay and the CLI, and would not exist for someone who uses
  the terminal only.
- **A palette command,** **Chat Manager: Auto-continue cut-off chats...**
  (`chatManager.autoContinue`). It is built like
  [overlayAutoStart](../extension/extension.js): a quick pick of **On**
  ("a minute after the limit resets, each chat it cut off gets
  "continue"") and **Off** ("they are only marked orange"). It runs
  `chatq -AutoContinue on|off` through the tool folder's loader. It checks
  the script's line `auto-continue on|off`, then shows
  "Chats the usage limit cuts off are now continued by chatq." or
  "chatq no longer continues chats the limit cuts off.". On failure it
  shows "Auto-continue could not be set. Chat Manager: Show log has the details."
- **The Show it message after an auto run.** [Show-ChatFresh](../src/chatrm.ps1)
  gains `-Auto`, which writes `"auto": true` into the request.
  [message](../extension/extension.js) then says:
  "chatq continued X after the usage limit reset, and this window still has
  it open. Show it?" For the reload fallback it says "... Reload to show it?".
  A new `texts.ranAuto` holds the wording.

## Log lines

| file | line |
|---|---|
| `data/logs/jobs.log` | `#12 queued (continue, auto - limit 12:40, resets 13:00) · Parser rewrite and plugin unification` |
| `data/logs/overlay.log`, `-Always` | `auto-continue: queued #12 for 1a2b3c4d (Parser rewrite…), resets 13:00` |
| `data/logs/overlay.log`, once per cut-off | `auto-continue: 1a2b3c4d not queued - in a terminal` (also `never auto`, `off`, `far`, `late`, `stopped`, and `error: <text>`) |
| `data/logs/watcher.log` | `auto-continue: queued #12 for 1a2b3c4d (scan)` when the watcher queued it |
| `data/logs/watcher.log` | `#12 held: auto-continue waits until 13:05 - the chat is open in VS Code` |
| `data/logs/watcher.log` | `#12 skipped: the chat is gone` (auto) and `#12 skipped: already continued` (unchanged) |
| `data/logs/watcher.log` | `auto-continue stopped for 1a2b3c4d: 2 in a row failed` |
| `data/logs/jobs.log` | `#12 removed by chip (was queued)`, `by console`, `by chatq -AutoContinue never`, `by chatrm`. `Remove-ChatqJob`'s `-By` already writes this |

## Alerts

| event | when | text |
|---|---|---|
| `limited` (0) | a live chat cut off, a continue queued, you away | `<title> · stopped by the usage limit · auto-continues 13:01` |
| `done` (1) | a live chat cut off, nothing queued, you away | `<title> · stopped by the usage limit until 13:00 · <state words>` |
| `started` (0) | the auto job starts | `<title> · <mode> · auto-continue` (in place of `continue`) |
| `done` (1) | it finished | unchanged: title, how long, the end of the reply |
| `failed` (2) | the second auto-continue in a row failed | `<title> · auto-continue stopped: 2 tries in a row got no reply - continue it yourself` |

Nothing is sent when an auto job is skipped because the chat moved on,
nor when it is removed.

## First run, for people who already use chatq

Amended: with the default `"ask"`, this mode's first run is the first
time someone chooses `"on"`, not an update. `since` and the balloon still
apply then, worded for a switch made on purpose.

- **On, but only for what is new.** The first scan after the update writes
  `since`. Cut-offs from before it are `far`: shown, never queued. Without
  this, an update would send a batch of continues into chats from hours
  ago.
- **They are told once.** The first time the Windows overlay starts on
  this version, and `noticed` is not set, the tray shows a balloon for 10
  seconds. Then `noticed` is set:

  > chatq now continues chats the usage limit cuts off, a minute after the
  > reset. Settings (the two sliders) → Cut off → Leave turns it off.

- **The first auto job** also shows a balloon:

  > Parser rewrite… will be continued at 13:01. Rest on its row for
  > "don't continue".

- **Everyone else** (no overlay) finds it in the CHANGELOG, the README,
  the `chatq` cheat sheet line, and `chatqlist`'s auto-continue line.

## What could surprise someone

- **A continue arriving while you type in that chat.** If the chat is open
  in a VS Code panel, the run holds 5 minutes after the reset. The row
  says `#12 auto-continues 13:05 (open in VS Code)` the whole time. If you
  send anything in the chat first, the chat is working, the job defers,
  then finds the chat moved on, and is skipped. If you start typing but
  have not sent when the run starts, the run goes into the transcript
  while your panel has the old view. That is the case every queued prompt
  has today. The run ends with **Show it**, and the alert's `$reload` words
  say "Show it in VS Code before typing in this chat". This spec adds
  nothing on top.
- **Two windows on one chat.** Still one row. The Show it request goes to
  every window that held the chat
  ([Show-ChatFresh](../src/chatrm.ps1)), as today.
- **The panel continues it too** (if A1 says it does). The panel's
  continue starts shortly after the reset. chatq's comes at reset + 5
  minutes, finds the chat busy or moved on, and is skipped. Nothing runs
  twice, since the moved-on check reads the transcript right before the run.
- **The PC stays awake until the reset.** A queued job due within 6 hours
  holds off sleep ([Set-ChatqKeepAwake](../src/watcher.ps1)). Every
  cut-off now does this, where before only one you queued did. The README
  says so. A closed laptop lid still sleeps.
- **A laptop that slept past the reset** runs the continue as it wakes,
  since the job was queued before the sleep. A cut-off only *seen* after
  waking, more than 30 minutes past its reset, is `late` and waits for you.
- **The overlay and the watcher both scanning.** They never both queue:
  the marker is made with an exclusive create before the job.
- **Plan mode.** A chat last in plan mode continues in plan mode and stops
  at a plan. Anything that would ask is denied, as for every run (the job
  lands in `needs input`).
- **The mode is the chat's own,** even `bypassPermissions`. Continuing a
  task runs in the mode it was already running in. `reply.maxMode` does
  not apply, because no reply is involved.
- **Global off keeps what is queued.** Turning auto-continue off does not
  cancel continues already queued. The line printed says how many are kept
  and how to drop them.

## Functions (new, house naming)

Built in 0.9.0 for the ask, and for this mode to build on:

| function | file | what |
|---|---|---|
| `Get-ChatqAutoContinue` | [queue.ps1](../src/queue.ps1) | `config.json`'s `autoContinue` as `'ask'` or `'off'` (`'on'` once built); `-Cfg` a config already read |
| `Set-ChatqAutoContinue` | queue.ps1 | `-Value ask\|off`: writes the top-level `autoContinue`, prints nothing, returns the value. This mode adds `on`, and its lines about jobs kept go to the caller |
| `Get-ChatqCutKey` | queue.ps1 | pure; a cut-off's marker name |
| `Save-ChatqAskAnswer`, `Read-ChatqAskState`, `Read-ChatqAskShown`, `Add-ChatqAskShown` | queue.ps1 | the markers in `data/auto/` |
| `Get-ChatqResetAsk` | queue.ps1 | pure; which cut-offs are asked about now |
| `Invoke-ChatqContinueChats` | [commands.ps1](../src/commands.ps1) | a continue job for each chat; the console's and the ask's loop |
| `Complete-ChatqResetAsk` | [overlay-data.ps1](../src/overlay-data.ps1) | an answer, from any surface |

Built for this mode, in 0.9.0 - in [auto-continue.ps1](../src/auto-continue.ps1)
unless named otherwise, so the mode is one file:

| function | file | what |
|---|---|---|
| `Get-ChatqAutoConfig` | auto-continue.ps1 | `config.json`'s `autoContinue` and `auto-continue.json`, as `@{ Mode; On; Since; Chats; Streak; Noticed; Told; Exists }`. Read again only when either file's write time moved |
| `Set-ChatqAutoChat` | auto-continue.ps1 | one chat: `always`, `never`, `default`. Removes its `auto` jobs on `never`. Returns `@{ Messages; Removed }` |
| `Save-ChatqAutoState`, `Update-ChatqAutoState`, `Reset-ChatqAutoSince` | auto-continue.ps1 | writes `auto-continue.json` |
| `New-ChatqAutoMarker` | auto-continue.ps1 | exclusive create of `data/auto/<key>.json`; `$true` when this caller made it |
| `Get-ChatqAutoState` | auto-continue.ps1 | pure; the state and words for one cut-off |
| `Invoke-ChatqAutoContinueScan` | auto-continue.ps1 | the checks, the marker, `New-ChatqJob`, the log line. Returns `@{ Queued; Skipped; Error }`. Never throws |
| `Get-ChatqAutoHold` | auto-continue.ps1 | the VS Code hold for an `auto` job, or `$null`; [Invoke-ChatqJob](../src/watcher.ps1) calls it |
| `Set-ChatOverlayAutoChoice` | [overlay-windows.ps1](../src/overlay-windows.ps1) | the settings row: Continue, Ask, Leave |
| `Get-ChatOverlayChipActions` | overlay-windows.ps1 | pure; the chips for a row: the ask's, the auto chip, `open` |
| `Invoke-ChatOverlayAutoChip` | auto-continue.ps1 | don't continue / continue from the chip |
| `Set-ChatConsoleAutoChat` | auto-continue.ps1 | the console's per-chat chips |

Changed:
- [Get-ChatqCutOffChats](../src/queue.ps1): rows gain `LimitUuid` (done
  in 0.9.0).
- [Get-ChatOverlayRows](../src/overlay-data.ps1): an `auto` job stays on
  its cut-off row, and rows carry `auto = @{ state; words; seq }`.
- [Format-ChatOverlayCutOff](../src/overlay-data.ps1): `-Auto`.
- [Get-ChatqEta](../src/alerts.ps1): `deferWhy vscode` reads `(open in VS Code)`.
- [Invoke-ChatqJob](../src/watcher.ps1): the hold, the quiet gone-skip, the streak.
- [New-ChatqJobRecord](../src/commands.ps1): `auto`, `cutUuid`, `deferWhy`.
- [chatq](../src/commands.ps1), [Write-ChatqList](../src/alerts.ps1),
  [Write-ChatqBoard](../src/alerts.ps1), [chatrm](../src/chatrm.ps1),
  [Update-ChatqLiveAlerts](../src/phone.ps1),
  [Get-ChatqLiveAlertText](../src/phone.ps1),
  [Invoke-ChatqReply](../src/phone.ps1), [Show-ChatFresh](../src/chatrm.ps1),
  `buttonsFor` in [reply.html](reply.html), and
  [extension.js](../extension/extension.js).

## Tests

**Automated, a new `tests/sections/auto-continue.ps1`**, in the sandbox the
other sections use (`New-FakeChat -CutOff -ResetsAt`):
- Every row of the chat table:
  - a closed chat queued;
  - a panel chat queued with the 5-minute hold;
  - a terminal's chat not queued (`terminal`), and queued at the next
    scan once its entry is gone;
  - a non-interactive entry not queued;
  - a 529 queued, its marker's `why` `overloaded`, its job waiting on
    the status page, and one first seen over 30 min after the 529 not;
  - a second config dir not scanned.
- Each check in order, with the state it leaves: global off, `never`,
  `always` with global off, a job already queued, `since`, 12 h, 24 h,
  30 min late, the marker, the streak.
- **The marker.** Two scans at once (two runspaces) make one job. A
  removed job's cut-off is not queued again. A new `uuid` on the same
  chat is. Markers over 8 days are deleted. A marker with `error` is never
  tried again.
- **The job** is `kind continue`, `rule auto`, `auto` true, `cutUuid` set,
  in the chat's mode and model. `job-core`'s field list gains `auto`,
  `cutUuid` and `deferWhy`.
- **The watcher:**
  - the hold sets `deferUntil` to reset + 5 min and `deferWhy vscode`;
  - moved on → skipped (existing);
  - gone → skipped with no alert, where a job you queued still fails and
    alerts;
  - the streak counts failed `auto` jobs and stops at 2, with its alert;
  - a finished turn resets the streak;
  - the watcher's 5-minute scan queues when no overlay runs.
- **`Get-ChatqAutoState`:** every row of the state table, words exact.
- **`chatq -AutoContinue`:**
  - each value's printed lines;
  - `on`/`off` with a title refused, and `always` with none refused;
  - with `-Prompt` refused;
  - `-WhatIf` saves nothing;
  - `never` removes the chat's `auto` job and leaves a job you queued;
  - a job number;
  - a Codex chat refused;
  - global off keeps queued jobs and says how many.
- **`chatqlist`:** the new line in each of its three forms, `continue (auto)`,
  and the cut-off tags. The board's column.
- **`chatrm`** drops `auto` jobs without `-DropJobs` and keeps a chat with
  your own job.

**Automated, elsewhere:**
- `tests/sections/overlay.ps1`:
  - `Get-ChatOverlayRows` keeps an `auto` job on the orange row, for an
    open chat and a closed one, with the counts;
  - `Get-ChatOverlayChipActions` for every state;
  - in the Windows panel child: the seventh settings row, its two chips
    and tooltips, a click saving `autoContinue`, the tray item's check
    following `config.json`, and the chip window with two chips;
  - `-Print` and `-Peek` passes queue nothing.
- `tests/sections/phone.ps1`:
  - a live cut-off with an `auto` job sends `limited` about the job (`n`,
    `j=queued`), and one with none sends `done` with the state words;
  - `skip` on an `auto` job answers with its own words and leaves the
    marker;
  - no act turns auto-continue on or off.
- `tests/reply-page-check.js`: `buttonsFor('limited', 'claude', false, 'queued')`
  gives Send, Don't continue (`skip`, with a confirm) and Status. `ACTS` is
  unchanged.
- `tests/extension-check.js`:
  - `chatManager.autoContinue` in `package.json` and registered;
  - On and Off run `chatq -AutoContinue on|off` through the loader, and
    the script's line is checked;
  - a failure is said;
  - `message()` words an `auto` request.
- `tests/overlay-mac-check.js`: the menu item.

**By hand, TESTING.md S35**, on a real subscription, with a limit reached
on purpose (a cheap way: a model's weekly limit, with the reset brought
within 24 h by waiting):
1. A panel chat cut off and left open, you away:
   - the row reads `auto-continues`;
   - the phone gets `limited` with **Don't continue**;
   - the run holds 5 minutes, then runs;
   - the window shows it by itself.
2. The same with you at the PC: **Show it** is offered with the auto words.
3. A chat whose tab was closed: continued at reset + 1 minute.
4. A terminal chat: chatq leaves it, and Claude Code's own wait continues
   it. After exiting that `claude`, the next scan queues one.
5. **Don't continue** from the chip, from the console, and from the
   phone's two taps. Each time the row reads `not continued`, and nothing
   runs.
6. The settings box's **Leave**, the tray item, `chatq -AutoContinue off`
   and the palette command each turn it off. Each one shows in the other
   three.
7. An update from 0.8.0 with an old cut-off on screen: not queued, the
   balloon once.

## Spikes before building

- **A1: does a VS Code panel chat continue itself?** On Claude Code
  2.1.234 or later, with `autoContinueAtUsageLimit` unset: let a panel chat
  hit the limit and leave it open past the reset. Does the transcript get
  a continuation turn with nobody typing? If it reliably does, then a
  panel-open chat should be left alone like a terminal's (state
  `panel`, words `· VS Code continues it`), and the 5-minute hold goes.
  If it does not, the hold stays as a guard for later versions.
- **A2: the text.** What does that continuation write: an `isMeta` user
  record with `Continue from where you left off.`, as
  `$script:ChatqContinueText` assumes? If the words changed, the moved-on
  check is unaffected, since it reads the last turn's error shape. But the
  comment in [queue.ps1](../src/queue.ps1) and the README should say what
  is true.
- **A3: the cut-off's identity.** Is the `uuid` of the synthetic limit
  record stable? Does anything rewrite that record, for example a panel
  retry, a `/rate-limit-options`, or Claude Code's own wait arming? The
  marker relies on this. If it is not stable, key the marker on the
  record's `timestamp` instead.
- **A4: other registry kinds.** Which `kind` values do
  `~/.claude/sessions/<pid>.json` entries carry for background sessions
  and agent-view sessions on this machine, and are they read by
  [Read-ChatqSessionRegistry](../src/live-chats.ps1) today? Check 3 must
  see them.

**What the build found** (2026-09-27, read-only; TESTING.md has each in
full). A3: the uuid is stable, so the marker keys on it. A chat woken
before its reset can hit the limit again under a new uuid with the same
reset, so a removed continue holds for every cut-off of that chat with that
reset. A4: every live entry was `interactive` and `claude-vscode`, and a
`claude -p` registers as `interactive` with `sdk-cli`, so check 3 reads
the entrypoint as well as the kind. A1 and A2 stay open. Four panel
cut-offs on 2.1.282 and 2.1.283 got nothing after the reset until a typed
`continue`, so the hold stays.

## Out of scope

- **Codex chats chatq did not run.** There is no cut-off scan for Codex
  rollouts. Goes to FUTURE_WORK.md.
- **Other `CLAUDE_CONFIG_DIR` accounts.** The cut-off scan reads only the
  default home.
- **A chat a terminal holds.** That is Claude Code's own to continue, and
  chatq never makes a second writer.
- **Weekly limits days out.** Left to you, as Claude Code leaves them.
- **Changing auto-continue from the phone**, either way (above).
- **A heads-up toast a minute before the run.** The row says it all along,
  and the 5-minute hold covers the chat on screen. Reconsider if S35 item
  2 shows people typing into a chat just as it runs.
- **A per-project switch**, and a daily cap on auto-continues. The
  per-chat `never` and the 2-in-a-row stop cover what has come up.
- **Setting Claude Code's own `autoContinueAtUsageLimit`.** chatq never
  writes Claude's settings.
- **Linux.** There is no overlay there. The watcher's scan works while a
  watcher runs, and that is all.

## Docs

- **README:**
  - "Auto-continue" under *Queue prompts for when the limit resets*: the
    chat table, the checks in plain words, the switches, and what could
    surprise;
  - the overlay's row words, chip and seventh settings row, and the tray
    item;
  - the console;
  - `autoContinue` in the settings;
  - the `chatq` command table and flags;
  - the phone's `limited` buttons;
  - correct the comparison row: Claude Code's own auto-continue covers "the
    open terminal session, reset within 24 h"; a VS Code panel is as A1
    finds.
- **CHANGELOG:** opt-in (`"on"`; the default stays `"ask"`), and only for
  cut-offs after it is chosen.
  The live cut-off alert is now `limited` when a continue is queued, so a
  `-Events` list without `limited` drops it. `chatrm` drops `auto` jobs.
- **TESTING:** the new section and checks, S35, and A1 to A4 in the
  spikes table.
- **FUTURE_WORK:** the 529 and Codex entries.
- **extension/README.md:** the palette command.

## Decisions (accepted 2026-09-27)

1. **Ask by default** (amended 2026-09-27; was "on by default, for
   cut-offs after the update only"). The owner asked that the default ask
   first: [Ask at the reset](#ask-at-the-reset-the-default-built), built
   in 0.9.0. This mode is the opt-in `"on"`, for cut-offs after it is
   chosen only (`since`), with one balloon.
2. **The CLI is `chatq -AutoContinue`**, not a new command.
3. **Not in the phone setup window**, and not changeable from the phone.
   The phone gets **Don't continue** for one cut-off only.
4. **No VS Code setting**, only a palette command that writes `config.json`.
5. **A terminal's chat is never auto-continued** while that terminal holds
   it.
6. **Limit only**, not a 529 (amended 2026-10-01: a 529 is continued too,
   with the switch on - see [After a 529](#after-a-529)).
7. **The switch leaves chatq's own jobs alone.** A prompt you queued is
   still run to the end.
8. **A 5-minute hold for a chat open in a VS Code panel**, until A1 says
   whether it can go.
9. **Don't continue declines one cut-off.** `never` is the per-chat
   off switch.

## Order of work

1. Spikes A1 to A4.
2. The core: the settings and markers, `Get-ChatqAutoState`, the scan, the
   job fields, the watcher's hold, gone-skip and streak, `chatq -AutoContinue`,
   `chatqlist`, the board, `chatrm`. Then its tests.
3. The overlay: the rows, the chip, the settings row, the tray, the first
   balloon. The console.
4. The phone: the alert, `buttonsFor`, the `skip` words.
5. The extension: the palette command, and the Show it words.
6. The docs, then S35.
