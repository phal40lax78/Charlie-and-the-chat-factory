# Changelog

## 0.10.3 — A reload asked for on the overlay, continues first, and phone replies in the chat's own mode

- **The phone at the PC too: `phoneWhilePresent`.** Phone alerts waited
  until nobody had used the PC for `quietMinutes`, but being at the PC is
  not watching that one chat. `"phoneWhilePresent": true` in
  `config.json` sends them at once: the live chats' needs input and done,
  the reset ask, and chatq's own job alerts. `quietMinutes` 0 could not do
  it - that is never away, so live alerts never went. Reloads still wait
  for you to be really away.
- **Phone alerts end with usage and the chats at work.** Each phone
  alert gets a last line read as it goes: how much of each usage window
  is used and how many chats are busy or waiting on you - `Claude 5h 42%,
  week 18% · 3 working, 1 waiting`. The chats are counted as the overlay
  counts them, its own figures while it runs: a chat whose turn is over
  but whose workflow, background agent or background shell still runs is
  working. A provider at 0% in every window is
  not in use and left out - Claude or Codex alike. The reply page shows
  the same line under the title (the link's `s=`). Not on replies,
  pairing or permission pushes; the toast and `alerts.log` keep the alert
  as it was.
- **A phone reply runs in the chat's own mode.** A prompt, retry or allow
  from the phone was brought down to `acceptEdits` unless
  `reply.maxMode` said otherwise - so a chat in `auto` ran in
  `acceptEdits` from the phone, and lost Ultracode, which needs `auto`.
  The default is now `keep`: the chat's own mode, and a Codex chat's
  sandbox, as at the PC. `chatnotify -ReplyMaxMode <mode>` (new) sets a
  cap as before; `-ReplyMaxMode keep` lifts it. A `reply.maxMode` already
  in `config.json` is kept, read past a hand edit's case and spaces -
  `Keep` is keep, `Plan ` is plan; a word that is no mode caps at
  `acceptEdits`.
- **The collapsed overlay shows only the usage in use.** Its line showed
  Claude's usage always, and never Codex's. It now shows each provider
  with some window above 0% - the alert footer's rule - so a Codex user
  sees Codex, named; Claude alone stays unnamed, as before.
- **Codex usage no longer reads a window long reset.** `chatqlist` and the
  phone's status showed the last Codex rollout's percent even after
  that window reset - `Codex 5h 3%` days later, where the overlay said
  0%. A window whose reset passed now reads 0%, as the overlay has it;
  Claude's cached figure too.
- **A continue no longer waits behind other chats' prompts.** Continue,
  Continue all, the reset ask, the phone's continue, `chatq -Continue`
  and auto-continue queued in turn, so a chat the limit cut off waited
  behind every prompt queued for other chats. A continue only picks up
  work the limit cut off, so the queue now puts continues ahead of the
  prompts waiting, in the order they were queued - Continue all's in its
  list's order - with a job put first still ahead of them. Continue says
  `queued 3 continues ahead of the prompts waiting - one at a time, ...`.
  The watcher still runs one job at a time.
- **`chatq -New <folder>`: a new chat from the shell.** Only the console
  and the phone could queue a prompt for a chat that does not exist yet.
  `chatq -New . 'Release notes' -Prompt '...'` queues one for a new Claude
  chat in that folder - relative to the shell's - named as given, or by
  the prompt's first line. Without `-Prompt` the editor opens, as for any
  chat; `-Paste`, `-Attach`, `-Mode`, `-Model`, `-At`, `-In`, `-First`
  and `-WhatIf` work as well. Its first run makes the chat, and chatq
  says how to reach it: `chatq <first 8 of its id>`, or
  `claude --resume <id>` in a terminal.
- **Now is Next.** The console's **When** choice **Now** read as if it
  sent the word "now"; it is **Next** - the front of the queue - and its
  button says **Send**. Each When chip has a tooltip. A draft kept with
  Now comes back as Next.
- **A reload asked for shows on the overlay too.** A reload VS Code asks
  about after a delete, an archive or a queued run was only a notice,
  which slides into the notification centre in seconds. While one is
  unanswered the overlay now has a banner - *projA needs a reload -
  "Old chat" deleted - the chat list still shows it* - and its chip
  offers **reload** (or **reload anyway**, where the notice's button is
  that), which is the notice's button with the same checks, and
  **later**, which takes it off the overlay and leaves the notice in VS
  Code. The window reads the answer within 2 s. Collapsed, the panel and
  the tray's tooltip count it; `chatoverlay -Print` and the macOS panel
  show it as a line. The window lists its questions in
  `data/reload-pending/`; the overlay answers in `data/reload-answer/`.
- **A delete no longer finds working chats that are not.** Right after a
  delete, the reload notice named every other chat of the window as
  working, though the overlay called them idle. A window reloading - or
  a chat's process starting or ending - writes records with no turn in
  them to each chat it had open, and "written in the last minute" went by
  the file's date. It now goes by the time of the last turn in the
  transcript, before a reload, in the reload's own check and in the
  folder's judgement alike; a chat held only by that is named *(written
  in the last minute)* rather than by its title alone.
- **A chat opened from Session history after its run keeps Ultracode.**
  A queued run into a chat with Ultracode kept it, but when the run ended
  with its live view closed, chatq only asked; picking the chat from
  another tab's **Session history** instead started it without Ultracode
  or its session-only level, since chatq carried them only into an open
  of its own. Now the run's end arms that carry at once, for 30 minutes,
  so the chat takes them however it is opened again - Session history,
  the side bar, or chatq's **Open chat**, which still takes over. A spike
  also settled that the run's own `"ultracode": true` works: a new print
  run writes `ultra_effort_enter`, a resume with it writes nothing new -
  the history already says on - and one without writes the exit.
- **A run's end asks if you are back.** A run into a chat idle in a
  tab opens the chat again by itself when it ends only while nobody is
  at the PC, and asks (**Open chat**) while someone is. Away was judged
  as the run started, so a prompt queued for the night, started with you
  away, took its tab back under your hands in the morning. Now it is
  judged again as the run ends.
- **The overlay's chips take the first click.** A chip that came up
  under a resting pointer took no click until the pointer had moved off
  it, so open and delete always said **click again**. Now a click on it
  in its first 300 ms - one on its way to what is under the panel - is
  the only one it refuses, timed by the mouse's own clock.
- **An open from the overlay no longer pushes the rows down.** Its
  `opening '<title>' - 3s` was a line added above the rows, so every row
  moved down a line as the click landed, and a second click fell on
  another chat. It now says `opening '<title>' in VS Code - 3s` on a line
  at the foot of the panel, under every row, as it says how an open, a
  delete or a reload went; that line's room is kept free, so no row moves
  or is cut as it comes and goes.
- **The started alert says when the chat is still open.** Sometimes a
  run goes in beside a view of the chat that is still open. That can be
  a tab the handover could not close, the side bar, the handover turned
  off, a window with no chatq extension, or a tab whose idle process
  `liveIdle stop` ended. For these runs the `started` alert now ends
  `open in VS Code: do not type in it until done`. When a terminal's
  claude holds the chat, the alert ends `open in a terminal too: do not
  type there until done`. Anything typed into that view starts a second
  agent on the chat, and it works on the same files as the run. If the
  handover closed the tab, there is nowhere left to type, and the alert
  adds nothing.
- **A Cancel during the handover no longer counts a try.** A Cancel
  clicked while the windows are being asked, or while `liveIdle stop`
  ends the chat's process, puts back the job's attempt count and its
  start time from before. The run never went in, so a `chatqrun <n>`
  afterwards says attempt 1, or the earlier go's number. A job like this
  that never started at all, when requeued, looks for its prompt in the
  chat only after the moment it ended. Before, an older turn in the chat
  that opened with the same words could make the requeue send `continue`
  in place of a prompt that was never sent.
- **The 30 s hold after a handover only follows a tab that was closed.**
  A window that closes the chat's tab for a run puts the tab back when
  the run ends. The chat's next run still waits 30 s for that to happen.
  A handover that closed no tab (the tab was in use, or could not be
  told apart) no longer holds the next run 30 s for a put-back that
  never comes. The hold also still applies when the handover fails
  partway after a window has already closed its tab.
- **A wait that changes to a busy chat now says so.** A busy chat is now
  a wait reason of its own, `busy`. A job that goes from waiting on a
  background command, or on you leaving its tab, to waiting on a busy
  chat now writes that change to its history and to jobs.log. A busy
  wait right after queueing, or after a start, writes nothing new, as
  before.
- **A wait reads the same everywhere.** `chatqlist`, the job's history,
  the overlay, the console and the phone now all build a wait's text in
  one place, so they cannot drift apart. A background command started 6
  or more days ago now shows its date (`Sep 24`), not a weekday, which
  made a months-old start look like last week.
- **Two requests inside one of the extension's polls are both acted
  on.** `data/reload-request` and `data/open-request` each held one
  request. Two inside the window's 2-second look (say, a `chatrm` right
  after a queued run, or two clicks of the open chip) lost the first
  without anyone seeing it. Each file now holds the newest request,
  whole as before, plus the few written in the minute before it (at most
  three) under `earlier`. `data/signal.lock` is held while a file is
  written, so two writers never drop each other's requests. A writer
  that cannot get the lock within 3 s writes its request alone. Each
  window acts on every id it has not seen yet, oldest first. It keeps
  the last 16 ids in globalState and also in its own memory, so another
  window's write cannot drop them. A run's request carried under a later
  one still holds back the next run into its chat for 30 s.
  Compatibility: an older extension reads only the newest request, as it
  always did, and a file from an older script reads as its one request.
  The first look after updating from an older extension treats every
  request the file carries, up to the last one that extension took, as
  seen. So a delete or an open it already acted on is not asked or
  opened again after the reload.
- **After a Show it nobody took, the open chip does what Show it does.**
  After a run went in beside a chat's tab, a window offered **Show it**.
  If the answer was **Not now** (or nothing), the tab kept showing the
  chat from before the run. Its process never rereads the transcript, so
  the chip only brought that stale tab forward. Now, while that tab's
  process is still idle in the window, the chip does what Show it does.
  It checks the chat, closes the tab, ends the process if it outlived
  the close, and opens the chat again from disk. Where Show it would ask
  to reload instead (the chat working by then, or its check failing),
  the chip opens as it always did and never asks. The window forgets the
  offer when it reloads, when Show it runs, when a run takes the chat's
  tab, when a newer run's request for the chat comes in, or when the
  chip finds no process holding the chat or one working in it. That
  run's notice may still sit in the notification centre. Once the chip
  has acted, clicking the notice's **Show it** does nothing more, so the
  fresh tab is not closed and reopened again. Where windows cannot be
  told apart, as on a Mac, the chip opens as it always did.
- **The stale warning for a run beside a tab now comes once per run, not
  once per job.** Before, a job that ran beside the chat's tab, went
  back into the queue at the limit and then ran beside it again got no
  second warning in that window. The warning is now keyed to the run:
  its handover's id, or the 'running' write's own id when there was no
  handover. Later writes of the same run still say nothing more.
- **The live view's pinned todo stays up past the 5000 kept rows.** The
  parser now keeps the last TodoWrite's list apart from the rows.
  Before, once its row was dropped nothing was pinned until the next
  TodoWrite came.
- **A live view VS Code keeps but never shows again no longer holds the
  chat for two days.** Take a watch tab sitting behind others after a
  window reload. It now holds the chat's put-back for 10 minutes at
  most. The 10 minutes count from the first look after a window's start
  that finds the run ended, and they start over if the job runs again
  before the tab comes back. Once they run out, the chat is put back as
  for a closed view: opened where its tab was if nobody is at the PC,
  otherwise asked. If the tab is shown later, it says how the run ended,
  with **Open chat**.
- **Show it no longer ends a tab that Claude Code reopened by itself
  just after an extension-host restart.** From 2.1.284, Claude Code
  reopens the tabs it lost after **Developer: Restart Extension Host**
  or **Restart Extensions**. Most come back within 5 to 10 seconds, and
  such a tab looks just like the new tab Show it opens. For 30 seconds
  after a restart, a new tab now gets a second check that only judges
  and ends nothing. The notice then says to close the side bar's copy if
  there is one. Restart and reload are told apart the way Claude Code
  tells them: each activation saves `vscode.env.sessionId` in the
  workspace state, and the same id at the next activation means a
  restart. A lost tab Claude Code reopens later is still not caught: one
  behind others comes back only when you select it, and one whose chat
  is busy elsewhere is retried about once a minute. That gap is recorded
  in FUTURE_WORK.md.
- **Open chat... knows which window holds a chat, on Windows.** The
  picker reads each live chat's process once, in one Windows PowerShell
  call. A registry entry whose pid another process has taken since no
  longer counts as live, so that chat shows no state and opens from
  disk. A VS Code panel's parent process says whether the chat is in
  this window or another, and the list says `in this window` or `in
  another window`. The list first appears from the registry alone, then
  updates when that check comes back. A chat working in another window
  is now handed to that window, which brings its tab forward, instead of
  being refused. One open and idle there asks **Show it there** first,
  beside **Open here too**. If the chat moved meanwhile, say to this
  window's side bar, Show it there does nothing and says so, because a
  second copy was not asked for. If it was closed meanwhile, it opens
  here from disk, the only place left to show it. Off Windows nothing is
  looked at, and the picker works as before.
- **The picker finds a title written near a large chat's start.** Where
  the last 256 KB of a transcript hold no rename or Claude title, the
  first 256 KB are read too, as `chatfind`'s index does. A long chat
  renamed early no longer shows its first prompt.
- **The queue in the status bar.** `chatq 3 queued · 16:05` shows how
  many prompts wait and when the next one sends, by the board's rules:
  `next`, `after #15` while a run goes, a time, `when Claude is back`
  during an overload, or `watcher stopped` when nothing would send. A
  job put off because you are in its tab, or because a background
  command runs, has no send time. Its stored time is only the watcher's
  next check, so like the board the item reads `waits for you to leave
  its tab` or `waits for a background command`, and any real send time
  comes first. A click, or **Chat Manager: Show the queue**, opens the
  board. The item is hidden when nothing is queued, and it rereads a job
  file only when that file changed.
- **Ultracode goes with a queued run where a Workflow rule allows it.**
  A run into a chat that had Ultracode used to carry it only in auto or
  bypassPermissions mode. In any other mode Claude Code asks before each
  Workflow, and nobody can answer a run. Now a `Workflow` (or
  `Workflow(*)`) allow rule carries it in any mode but plan. chatq reads
  the rule from the settings the run loads: the user's `settings.json`
  in the job's config dir, the project's `.claude/settings.json` and
  `.claude/settings.local.json`. `watcher.log` names the file that
  allowed it. A deny or an ask rule for Workflow holds Ultracode back in
  every mode, and the history names the file: `Ultracode left off (the
  project settings deny Workflow)`. Plan mode holds it back even with an
  allow rule, because a plan run is meant to change nothing and a
  workflow's agents would: `Ultracode left off (plan mode changes
  nothing, and a workflow's agents would)`. A `CLAUDE_CODE_EFFORT_LEVEL`
  in the `env` of the user's or the project's settings now counts as
  set, like one in the watcher's environment, so no `--effort` goes with
  the run.
- **A queued run's Ultracode and level are what it took, not what it
  asked for.** Claude Code refuses neither. It drops Ultracode without a
  word, and it lowers a level the model or an org cap does not allow. So
  the history, the console and the live view said only what the run was
  started with. As a run ends, chatq now reads the run's own records. An
  `ultra_effort_exit` it wrote means Ultracode was not taken, and the
  effort on its first turn is the level it ran at. chatq updates the job
  to match, and its end in the history says `Ultracode not taken` or
  `ran at effort high, not max`. An Ultracode that is on but idle
  (workflows off, or a model below xhigh) may still read as taken. That
  is not yet checked.
- **Auto-continue after a 529.** With auto-continue on, a chat cut off
  by `529 Overloaded` used to stay `529 - waits for Claude` with nothing
  queued. It now gets "Continue from where you left off." too. It goes
  through the same checks as a limit, with the 529's own time in place
  of the reset: one first seen over 30 minutes after the 529 is left to
  you. A 529 has no reset to wait for. The watcher waits as it does for
  a 529 on one of its own jobs, with no alert, and sends the continue
  when status.claude.com says Claude Code is operational, or 15 minutes
  after the 529. While it waits, every other Claude prompt on that
  account waits too, as in any outage the watcher sees. That wait starts
  only while the chat still stands where the 529 left it, and it ends as
  soon as that stops being true. A chat you retried in the panel, or a
  continue you removed with Don't continue, holds nothing up. A chat
  open in VS Code is never sent one within 5 minutes of the 529. The row
  reads `#12 auto · 529`, and Don't continue skips it for this 529 only.
  With the switch off or on Ask, a 529 is handled as before: the reset
  ask is for the limit only.
- **A close by hand keeps the overlay closed.** The panel's ×, the
  tray's **Quit** and `chatoverlay -Stop` closed it only until the next
  shell or VS Code window started it again a moment later; `-AutoStart
  off` was the one lasting off. Now a close by hand is kept in
  `data/overlay-state.json` against this Windows sign-in (when its
  `sihost.exe` started), and the auto start leaves the overlay closed
  until you next sign in. A balloon says so as it goes: `Closed until
  you next sign in. Type chatoverlay to bring it back sooner.` For the 4
  s the balloon shows, `chatoverlay`, the hotkey, a click on the tray
  icon or the console takes the close back and the panel stays. An
  update's restart in those 4 s only ends it, and the close is kept.
  After that, `chatoverlay`, `chatconsole` or `chatoverlay -AutoStart
  on` lift it, and so does `chatuninstall`, so a reinstall in the same
  sign-in starts it again. Where the sign-in cannot be read, and on
  macOS, the close works as before. An update's restart is not a close.
- **The overlay keeps up with its own code.** It loaded the script once,
  so a `git pull` in a checkout or files copied in by hand left the old
  code running for days, and `chatnotify` could only say `the overlay
  runs an older copy`. The overlay now notes each file's write time and
  size as it starts and looks again once a minute. When something
  changed and has stood still for 5 s, it restarts on the new code the
  way `chatinstall` restarts it. It waits while the console shows, the
  settings box is open, a slider or a drag has not come to rest, an open
  is under way, a close is on its way, or a full screen holds it off.
  The macOS host does the same. The "older copy" status line is gone.
- **The overlay steps aside for a full screen.** While a full-screen
  app, a game or a presentation has the screen (Windows'
  `SHQueryUserNotificationState`, the same check Windows uses to hold
  back its own notifications), the panel hides and comes back once that
  ends. Nothing is saved. The tray's **Show**, the hotkey or
  `chatoverlay` bring it back during one.
- **A panel at the screen's foot keeps one unit clear, not five.**
  Dragged by its top edge, a panel at the foot of the screen stopped
  five units above it. The room kept for the `+N more` line was a guess
  of 18 units, and it is now that line's measured height.
- **Recent changes at once.** Picking Recent off, 5 or 10 in the
  settings box now runs a pass straight away. Before, the list changed
  on the next pass, up to two seconds later.
- **A waiting job's mode and model change in the console.** Before, only
  a queued prompt's text could be edited in place. To change anything
  else you had to Remove the job and send it again. A waiting Claude
  job's details now show **Mode** and **Model** chips, the same ones as
  under the prompt box. A click changes them for that job before it
  sends, the first chip gives back the chat's own, and the status line
  says what changed. A job the watcher started meanwhile, or one
  removed, is refused rather than put back in the queue.
- **Open in VS Code from the console.** A waiting or ended Claude job
  whose chat has a transcript gets **Open in VS Code** in its details.
  It opens the chat in its window, as the overlay's open chip does.
- **Every argument to npm's `claude.cmd` is quoted for cmd.exe.** A
  `.cmd` or `.bat` runs through cmd.exe, which acts on `& | < > ^ ( )`.
  Only a new chat's title was cleaned for it. Now every argument holding
  one of those is quoted for a `.cmd`/`.bat`, so a folder or file name
  with `&` or brackets reaches Claude whole. A lone `%`, as in a folder
  named `100%`, still goes.
- **What cmd.exe cannot carry is refused, not run.** cmd.exe cannot be
  handed a `"` or a `%name%` at all. Before, one could end the argument
  early and hand the rest of the line, an `&` and all, to cmd as a
  command of its own. Now a `-Model` holding a space, quote or `%` is
  refused when you queue it, in `chatq` and in the console's chips. A
  job that would still pass one is failed with the reason instead of
  started with a broken command line. That covers a job queued with such
  a model before this version, a job file edited by hand, or a data
  folder or attached image whose path holds a `"` or a `%name%`. The
  watcher fails only that job. The jobs behind it run, with no lane
  blocked and no "can't reach claude" alert.
- **The console maximizes again.** As the panel's mode it had no
  maximize. **Maximize** beside **← Panel**, or a double-click on the
  header, fills the screen's working area with the taskbar left clear.
  **Restore**, or another double-click, gives back the size it had, even
  after Windows' own Win+Up. A maximized console does not move when you
  drag its header. A console left maximized opens maximized, and
  `console-state.json` keeps `max` again.
- **The console's size holds across monitor scales.** Its size was kept
  in screen pixels, so a console sized on a 150% monitor held half as
  much again on a 100% one. `w` and `h` are now kept in WPF's units
  (`units: true`) and turned into the panel's screen's pixels as it
  opens. An older file's pixels are read as they are until the next
  save.
- **A stale reset-ask answer in the console says so.** An answer that
  came after the cut-off chats changed did nothing and said nothing
  while the console showed. The console now redraws the list and its
  status line says `the chats changed - here they are now`, still
  without going back to the panel.
- **The board's chat view says the chat's own mode.** It used to say `at
  most acceptEdits` for every chat. Now it says the mode the chat runs
  in, as Older chats does. With a cap set (`reply.maxMode`) and the
  mode above it, it says the cap - `acceptEdits (phone's limit)`. An
  open chat's mode is read along with its title and newest prompt. That
  first read now goes past a long turn's tool output to find the mode,
  so a chat already deep in a turn when the overlay starts still shows
  it. A cut-off or Recent chat's mode comes from its transcript.
  `at most <cap>` is left only for a chat whose mode the PC could not
  read, or a Codex job, which has no row on the board, and only under a
  cap; with none, the default, those say `the chat's own mode`.
- **The board's cut-off rows say what auto-continue will do.** The phone
  showed `cut off` where the overlay showed `#12 auto 13:01`. A cut-off
  row now has the overlay's short words. The chat view shows them in
  full: `cut off - resets 13:00 · auto-continue queues it`. This holds
  whether or not the overlay is running, because the board's own scan
  works out the same states.
- **A board from a scan shows a job at once.** With no overlay running,
  a board was sent again unchanged for 40 s. So a job that started or
  ended on its own could show up to 40 s late. The scan of the chats is
  still kept 40 s, because it is the slow part. The queue and each row's
  jobs are now read again on every ask.
- **The continue chip in every auto-continue mode.** With auto-continue
  set to ask or off, a cut-off row had no **continue** chip. It now has
  one in every mode, and its words stay the plain `cut off - resets
  13:00`. The exception is a chat that a terminal's `claude` holds.
  Claude Code's own wait continues it there, so a second continue would
  mean two writers on one chat.
- **One job maker for a reply and the board.** An alert reply's prompt
  now makes its job the same way the board's Send does
  (`New-ChatqPhoneJob`). The steps are the same as before: text check,
  cap, Codex sandbox, and the chat's own mode once it was typed into at
  the PC. They now live in one place, so a fix to one reaches both.
- **A job you answered in the chat stops saying it needs you, overlay or
  not.** Only the overlay's pass skipped a job waiting on input once its
  chat was typed into after it stopped. With the overlay off,
  `chatqlist` and the phone's **Status** kept listing the job as `needs
  you` until `chatqrm`. Both now skip it, `answered in the chat`, before
  they list. They read a transcript's tail only for a job whose chat
  moved after it stopped.
- **The phone sees a Codex chat that went on at the PC.** A **Send** or
  **Retry** from an old alert or board checked only a Codex chat's job,
  so it could still go into a thread typed on in the Codex panel since.
  The rollout is now read the way a Claude transcript is: a prompt typed
  after the alert refuses the act, and a job waiting on input is closed
  as answered. Codex's AGENTS.md preamble, its environment block and a
  compaction's copies of old messages don't count. Codex does not record
  who typed a prompt, so one sent while a job of the phone's ran counts
  as that job's own.
- **Replies through your own command: `chatnotify -CommandLinks on`.**
  With neither Join nor ntfy over https there was no way to carry a
  reply link, so a phone could not be paired. `-CommandLinks on` (or
  **Give it the reply link too** in the setup window) gives your command
  the link as `$env:CHATQ_LINK` and makes it a phone channel. It runs
  where Join and ntfy would go, past the same gates. At the PC it still
  runs, with no link. The pairing push can go through it. Off by
  default: the link is a key to the reply page, and chatq cannot tell
  where your command sends it.
- **A pairing confirmed while the setup window saves keeps its key.**
  Every writer read `config.json`, changed its part and saved the whole
  file, with no lock. A Save landing in the same instant as a pairing
  confirm could put back the copy with no key, and the phone was not
  paired after all. Now `data/config.lock` is held around every
  read-change-save: chatnotify and the setup window, the pairing, the
  overlay's settings, the ask and auto-continue switches. Each one reads
  the file again under the lock. A confirm whose pairing was replaced
  meanwhile says so and saves nothing. If the lock is held for more than
  3 s, chatnotify saves nothing and says `config.json is busy`.
- **A phone-made chat with no name no longer carries its prompt in
  alerts.** Every alert about such a chat (started, done, needs input,
  and the live alerts once you run it at the PC) carried its title
  through the push service, and that title was the prompt's first line.
  It now goes by `phone chat 14:02` until Claude titles the chat, then
  by Claude's title. The neutral title is kept in
  `data/held-titles.json`, so it holds after `chatqrm -Finished` or the
  console's Remove takes the chat's jobs.
- **A `claude -p` is told by its entrypoint too.** Claude Code 2.1.283
  registers a `claude -p` as `interactive`, just like a chat you type
  in. Only its `sdk-cli` entrypoint gives it away, so chatq could not
  tell someone's own `claude -p` from a window's chat. Show it, the open
  chip, the busy check, a reload's wait, the list repair, the phone's
  live alerts and the watcher's check for a window that opened the chat
  during a run now treat an `sdk-*` entry as the print-mode run it is,
  whether a queued prompt or your own script. Show it no longer ends a
  window's process while such a run is going into the chat. Workflows
  that run left behind are no longer read as dead while it goes on. The
  phone no longer sends a *done* or *needs input* for a queued run as if
  it were a chat you typed in. A run is no longer marked stale because
  your own `claude -p` went into the chat while it ran.
- **The open chip keeps the dot on a chat it cannot open in a tab.**
  Claude Code never lists a chat whose transcript starts as an SDK's,
  which is every chat **+ New chat** made. Its window offers to open it
  in a terminal instead, and the unread dot used to go even when you
  dismissed that offer. The chip still asks the window, but now exits
  `21`, which the overlay does not count as shown. The dot stays until
  you read the chat, and the tray says the window offers a terminal.
  When that window was not brought forward either, the chip exits `26`
  (other folders open), `42` (no `code` command) or `43` (`code`
  failed). The tray then gives both reasons as a warning, and `43` still
  points at `watcher.log`. Otherwise you would look for the offer in a
  window that may still be behind others.
- **A reload waits on a `claude -p` into a chat whose process chatq
  ended.** Show it and `liveIdle: stop` end a window's idle process, and
  a queued run's handover closes its tab. The side bar may still show
  that chat afterwards, and reloading it would load a run part way
  through. chatq now records in `data/idle-ended.json` which window each
  process was ended in, or left with its tab. That window's reload waits
  while any `claude -p` goes into one of those chats, chatq's or not. A
  note lasts while its window lives and at most seven days. Two writers
  at once take turns under `data/idle-ended.lock`, so neither note is
  lost. A window's own processes are looked up by pid, not by listing
  every process, so Show it does not wait longer before the window
  reopens the chat. Only chatq's own runs counted before. Counting every
  `claude -p` anywhere would have held every reload.
- **Screenshots pasted into a cancelled prompt are cleaned up.** VS Code
  saves a pasted image in `data/queue/` straight away, so cancelling the
  prompt tab left the image there for good. The watcher now **deletes**
  files there that no prompt links to once they are a day old, and says
  how many in `watcher.log`. It runs when the watcher starts and every
  six hours after. It never removes anything sooner, because another
  shell's open tab may be taking a screenshot at that moment. Job
  folders, the queue's own files and anything a prompt links to are
  always kept. If any prompt cannot be read, nothing is removed.
- **A reload no longer leaves its cut-off chats unnoticed (Windows).** A
  VS Code window that reloads while its chats work ends their `claude`
  processes. That can leave an answer half written, a permission prompt
  gone, or a workflow's agents dead, and nobody was told. Now every look
  chatq runs before a reload leaves a note of the chats at work in
  `data/host-work/<host pid>.json`: the update notice and its **Reload
  now**, a reload after **Later**, and **Reload anyway**. Within a
  minute of the reload the overlay asks about what was cut off, as it
  does when the limit is over: `VS Code restarted · 2 chats it cut off
  can continue`. The ask appears in the same banner, tray balloon,
  console header and phone alert. When there are both kinds it reads
  `limit over at 13:00, and VS Code restarted`. A chat is offered when
  its last message still owed an answer, or when a workflow or
  background agent it started never reported back. It is not offered if
  it finished, is working again, was written to since, or was held by
  another window. A chat whose process from before the reload still runs
  is kept and offered once that process is gone. The offer needs the
  overlay running with `autoContinue` not `off`; with `off` the chats
  show only as orange rows. Finding them needs each extension host's
  process chain, which only Windows gives.
- **Continuing a chat a restart cut off says what was lost.**
  **Continue** queues a prompt in the chat's own mode, ahead of the
  prompts waiting. The prompt says the window restarted mid-turn and
  names any workflow or agent that did not finish, since `claude
  --resume` does not bring background work back. It then adds Claude
  Code's own *Continue from where you left off*. The prompt is dropped
  if the chat went on first. **Leave them** drops a restart's chat for
  good, where a limit's chat keeps its orange row, and the chips'
  tooltips say which. Auto-continue never continues these chats by
  itself, even when switched on, because a reload may have stopped
  something you meant to stop. A reload with no chatq look before it is
  not found: Developer: Reload Window, Restart Extensions, or another
  extension's update.

## 0.10.2 — Charlie and the Chat Factory, in the tray, and a reopened tab keeps Ultracode

- **A new name: Charlie and the Chat Factory - Claude Code & Codex**,
  was Chat Manager for Claude Code & Codex, after the Charlie on the
  icon. The notices, the settings section and the log's output channel
  carry it; the commands keep their **Chat Manager:** names and the
  settings their `chatManager.*` keys. Every other name follows: the ID
  `redaechan.charlie-and-the-chat-factory`,
  `Charlie-and-the-chat-factory.ps1` in
  `~/Tools/Charlie-and-the-chat-factory`, the repo
  github.com/phal40lax78/Charlie-and-the-chat-factory, and the phone's
  reply page at phal40lax78.github.io/Charlie-and-the-chat-factory. A
  new ID is a new Marketplace extension, so
  `redaechan.claude-codex-chat-manager` never updates to it: install this
  one and uninstall that - both installed would act on every request
  twice. A profile line naming the old loader is still recognised, and
  `chatinstall` replaces it. The reply page's site is the same, so the
  phone stays paired; bookmark it again, as GitHub Pages does not
  redirect a renamed repo.
- **Charlie in the Windows tray, and the tray says her name.** The tray
  icon was a plain coloured dot; it is now the extension's icon, with
  that dot at her bottom right in the most urgent chat's colour, drawn
  at the size Windows shows small icons at the screen's scale. The
  console and the phone alerts window carry her on their taskbar button
  and in Alt+Tab. What was still called chatq there is Charlie now: the
  tooltip (`Charlie: 2 new, 2 working`), the balloons (`Charlie - limit
  over at 13:00`), and the windows (`Charlie - console`, `Charlie - phone
  alerts`). The tooltip now runs to the 127 characters Windows keeps,
  not the 63 .NET Framework allowed, so the longer name leaves 5h's reset
  whole. The commands keep their names, and so do the phone alerts'
  titles (`chatq · done`), which a Tasker profile may match. The icon
  ships inside `src/icon.ps1`, a new part `docs/make-icon.py` writes,
  since every install copies `src/*.ps1` and nothing else.
- **The icon is transparent inside, and closer.** Charlie is cut out of
  her dark purple background and outlined in the dark rounded frame's own
  stroke, as a sticker is, on whatever colour the theme has, the edge
  redrawn as a smooth curve rather than the cutout's bumps, its bangs'
  spikes and the shoulder's notch kept sharp; her head
  fills two thirds of the icon's width, which reads at the Extensions
  view's size. `docs/cut-icon.py` cuts her out and `docs/make-icon.py`,
  which replaces `docs/make-icon.ps1`, frames and outlines her; both need
  Python with OpenCV.
- **A tab chatq opens again keeps Ultracode and its effort level.** Show
  it, the chat put back after a queued run and the live view's **Open
  chat** close a chat's tab and open it again, which starts a new claude
  process - without Ultracode or a level set for the session only, so its
  input box held `/effort ultracode` or `/effort max` to send. chatq now
  hands both to that process as it starts: the tab comes up with them on,
  the effort chip showing so, nothing in its input box and no notice;
  the log says `carried`. Only what the process being replaced had counts:
  Ultracode switched on two days ago, in a process a VS Code restart or a
  Claude Code update ended since, is not brought back - chatq notes when
  each chat's process started and reads the chat's history no further
  back than that. Where they did not go in within a minute - a
  tab only revealed, not started again, or a Claude Code that starts
  claude another way - the notice then names what to type. A remote
  window (WSL, SSH), where claude starts on the other machine, keeps the
  pre-fill at once, as before. `chatManager.keepSessionSettings: false`
  (on by default) turns it off, back to the pre-fill. **Why:** a chat
  refreshed by chatq should be the chat you left, not one to set up
  again.

## 0.10.1 — Remove in the console, and the overlay's chips, say what they do

- **Remove in the console works, and says what it did.** Its first click
  turned the button into **Remove - sure?** for good, while only a second
  click 0.4-5 s later removed: one after longer - back from VS Code, say -
  asked again under the same label, and the second half of a double-click
  was dropped, both with nothing said. "Sure?" now lasts 5 s, in red, and
  goes back to **Remove** after, saying so; each click says what it did in
  the status line; the clicks are timed by the mouse's own times, not by
  when a busy window got to them. A removed job now stays removed: the
  watcher, checking it at that moment, wrote it back - queued, or failed -
  and a continue could still be sent. `Remove-ChatqJob` goes by the job's
  file, not the caller's copy, and says when it could not remove it;
  `chatqrm` and **Don't continue** say so too.
- **The overlay's delete and open chips say what they do.** A delete
  that asked and then deleted, or kept the chat, said so only in a tray
  balloon, which Focus Assist hides: the panel's line says it now, as it
  does for an open, and the second half of a double-click is no answer.
- **The open chip says what it is doing.** A line on the panel says
  `opening '<title>' - 3s` from the click, then `opened` or why not - every
  exit code, a crash and no answer in 60 s among them, which said nothing
  before - and the chip counts the seconds. A click the chip was not armed
  for - one that came up under a resting pointer, as it does right after
  a delete - says **click again** rather than nothing. The open no longer
  waits on `claude agents` to start: it reads Claude's session registry,
  as the panel and **Show it** do.

## 0.10.0 — a new name, queued runs you can watch, and Claude's questions on the phone

- **A new name: Chat Manager for Claude Code & Codex**, was VS Code Chat
  Manager, with a shorter Marketplace description, and a new ID:
  `redaechan.claude-codex-chat-manager`. It is a new Marketplace
  extension, so the old `redaechan.vs-code-chat-manager` never updates to
  it: install the new one and uninstall the old - both installed would
  act on every request twice. The notices, the settings section and the
  log's output channel carry the new name; the settings keep their
  `chatManager.*` keys. **Why:** search weights the name most, and "VS
  Code" matched every extension while "Claude" and "Codex" were missing.
- **The script, the folder and the repo renamed too:**
  `claude-codex-chat-manager.ps1` in `~/Tools/claude-codex-chat-manager`,
  from github.com/phal40lax78/claude-codex-chat-manager, and the phone's
  reply page at phal40lax78.github.io/claude-codex-chat-manager. A
  profile line naming the old `VS-code-chat-manager.ps1` is still
  recognised, and `chatinstall` replaces it. Bookmark the reply page
  again: GitHub Pages does not redirect a renamed repo.
- **Delete a chat from the overlay.** The row's chip has **delete**
  beside **open**. The first click turns it to **sure?** for 4 seconds; a
  second deletes the chat and its leftovers as `chatrm` does, and the
  window offers its reload. On a chat at work, waiting on you, or run by a
  terminal `claude` it is greyed rather than gone, so the chip does not
  change width as the chat's state does. A chat held by a queued prompt is
  kept, and the tray says why. There is no undo; `chatrm -Archive` still
  puts a chat away instead.
- **Resize the overlay by its edges, as any window.** With the buttons up,
  drag a side of the panel for its width, its top or bottom for its rows -
  a row for each row's height of travel - or a corner for both; the side
  across from the one dragged stays where it is. The pointer turns to that
  edge's arrows, and a blue line marks the side it sizes. The top grows
  the panel upward over its bottom, and by the screen's foot brings back
  the rows the foot had cut. Collapsed, the sides and corners size the
  width alone. Resting just outside the panel's edge brings the buttons
  and edges too. The width slider and `chatoverlay -Width` still hold the
  right edge.
- **The resize handle is gone** from the row of buttons, seven now. It was
  one spot to hold at the panel's top-right corner, and which way it sized
  was not what it looked like: left widened, down added rows.
- **A reply from the phone acts only on what the phone was shown.** An
  alert, and a board's handle, keep the chat and the job as they showed
  them. **Send**, **Continue**, **Retry** and **Allow edits & continue**
  do nothing when the chat took a prompt since - at the PC, or another
  job's - and those and **Skip** and **Stop** do nothing when the job was
  queued, run or stopped again since; the watcher's own requeue after a
  limit or a dropped network does not count, nor do the phone's own
  prompts or a background task's notice. Only what was written to the
  transcript after the alert is read, so a long turn or a compaction after
  a prompt at the PC hides nothing. An alert's push says so,
  `Radar viewer moved on at the PC since that alert`, with a link about the
  chat as it is now; the board says `the list is out of date`, goes back to
  a board asked for afresh, and keeps the text. A `needs input` job
  whose chat was answered at the PC is closed as the overlay closes one,
  with no overlay running too. **Why:** a text written for the old turn
  answered a newer question it was never meant for; an old **Allow** raised
  the mode for a stop nobody had seen; an old **Stop** ended a later run.
- **A job's own mode no longer outranks the chat's.** A phone **Send**
  after a job runs in that job's mode only while nothing went into the chat
  after it; then in the chat's own mode as the PC left it, when lower -
  `runs in plan, the chat's own at the PC`.
- **Half an hour for a reply to arrive.** A reply the phone sealed more than
  30 minutes before the PC reads it - 10 for **Status** and a whole answer
  asked again - is refused as too old, as the board's changes already were;
  it was `reply.hours` and 10 minutes. **Why:** replies left on ntfy.sh
  while the watcher was down ran when it came back, hours after the chat
  went on at the PC.
- **A usage limit's reset no longer restarts every chat's timer.** The
  overlay's and the phone's `working 40m` read `working 0m` on every chat
  at once when the 5-hour limit reset. Claude Code rewrites each chat's
  registry file then and stamps its status time anew, status changed or
  not; a chat still in the same status now keeps the time it entered it.
- **Work sent to the background shows on the overlay.** A chat whose turn
  started a workflow, a background agent or a background command stays a
  green row until the work ends, and says what runs and for how long:
  `workflow 12m`, `2 agents 3m`, `shell 5m`. The phone's board lists it
  under Working. It was `idle` - in every folder, not only another repo's -
  since Claude calls the chat idle the moment that turn ends. A command
  counts while one of Claude's own shells runs under the chat's process, so
  one stopped from the task list goes idle at once, and a dev server reads
  `shell` for as long as it runs.
- **A killed workflow no longer holds a reload for good.** An interrupt of
  the turn that started a workflow kills it without a `<task-notification>`,
  and `TaskStop` ends a task without one, so the check before a reload - and
  the wait before an update loads - took the work for still running until
  the chat's process ended. The workflow's run record now ends it, as does
  a `TaskStop`, and an agent whose own transcript finished its turn: eleven
  agent runs here finished unannounced.
- **A queued run takes the chat's tab's place, and you can watch it.** A
  run into a chat open idle in a VS Code tab now asks that window first
  (`data/run-state`, answered in `data/run-ack/`): the window opens the
  run's live view in the tab's group and closes the chat's tab, and Claude
  Code ends that process itself - nothing is killed. As the run ends,
  whatever the outcome, the view turns back into the chat's tab, loaded
  from disk - at once while the view is in front or you are away, else
  with **Open chat**. The tab in front of you is never taken: the job
  waits, `waits for you to leave its tab`, looking again after 1, 2, then
  5 minutes, with **Hand over now** for that one job. A tab that cannot
  be told apart is left, the view opens beside it, and the window says the
  old view is stale until the run ends. A Cancel during the handover ends
  the job there, and the next run into the chat waits 30 s while the
  window puts it back. `chatManager.watchRuns` (on) and `"handover"` in
  `data/config.json` (on) turn it off. **Why:** Claude
  Code has no way to send a prompt into an open tab, so the run went in
  beside it, hidden - nothing showed a job going, and a message typed in
  the stale tab forked the chat.
- **The live view.** An editor tab, `▶ #15 <title>`, that follows the
  run's log as it is written: the prompt, Claude's text, each tool with
  its argument and a running clock, results cut to 3 lines, subagents
  indented, edits as `+2 -1`, errors coloured, the todo being done pinned
  (`Now: run the tests (3/7)`), a permission waiting on the phone, and the
  end. **Cancel** (asked first), **Log**, **Open chat** once it ends. It
  takes the theme, survives a window reload, and keeps the last 5000 rows.
  It opens from the handover, a status bar item in windows on the job's
  folder (`chatq #15 running`), **Chat Manager: Watch the running queued
  prompt**, the overlay's chip (which reads **watch** on that row), the
  console's **Watch in VS Code**, and **Open chat...** on that chat - all
  of which refused a running chat before.
- **Show it closes the tab before it ends anything.** The check now only
  judges; the chat's own tab is brought forward by its id and closed, and
  a process that outlives the close by 8 seconds is ended then - only this
  window's, started before the click. A tab it cannot be sure of is left
  with its process, and a run's end no longer ends a process at all, away
  or not. **Why:** Show it ended the idle process first, and the Claude
  extension let go of the tab as the process died; the reopen made a
  second tab and left the old one reading *Claude Code process exited
  with code 1* (seen 2026-09-28, twice).
- **A queued run's background work survives.** Claude runs get
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` - commands run in the turn -
  with the Bash tool's timeouts at an hour (`BASH_MAX_TIMEOUT_MS`) and 30
  minutes (`BASH_DEFAULT_TIMEOUT_MS`), and print mode's wait for a
  workflow or agent at an hour (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`),
  each only where the environment does not set it already. A run stopped
  at the 4-hour deadline after a turn that ended well counts as done, with
  a note. **Why:** `claude -p` kills a background shell 5 s after the turn
  ends (2.1.283), and a queued run's test suite died with it.
- **Never into a chat whose own work is out.** A run waits while the
  chat's own process has an agent or workflow out, as for a busy chat, and
  while it has a background command running - 20 minutes at most, then it
  goes in beside the chat without closing its tab, which would end a
  server; that wait never counts toward the 24-hour give-up. `chatqlist`,
  the overlay, the console and the phone's board say `waits for a
  background command (since 14:02)`.
- **A queued run keeps the chat's Ultracode and session-only effort.**
  Claude Code keeps both only in the chat's running process, so a run
  started plain dropped them. A run into a chat that had Ultracode on
  starts with it - `"ultracode": true` in the run's own settings, not
  `--effort ultracode`, which would force xhigh - and one whose effort
  was set for the session only - max always, or a level `/effort` set
  `(this session only)` - with `--effort <level>`. Only on the chat's own
  model: never with `-Model`, never a new chat's first run, never Codex;
  and no level where `CLAUDE_CODE_EFFORT_LEVEL` is set, which outranks
  it. The history, `watcher.log`, the console and the live view say
  `with Ultracode, at effort max`. **Why:** every queued run dropped them.
- **Ultracode only in a mode where a run can use it.** Claude Code asks
  before each Workflow unless the mode is auto or bypassPermissions, and
  a queued run has nobody to answer: every Workflow would be denied and
  the job end `needs input`. In any other mode the run goes without
  Ultracode, its level still carried, and its history says `Ultracode
  left off (default mode asks before each Workflow)`.
- **A tab chatq opens again holds `/effort ultracode`.** A tab closed and
  opened again - Show it, the chat put back after a run - is a new
  process, without Ultracode or a session-only level. Its input box now
  holds `/effort ultracode`, or `/effort max`: press Enter there. With
  both lost, the notice names the level to type next - typed, `/effort`
  leaves Ultracode on, where the tab's effort menu would save a level
  below max as every new session's default. It says `Ctrl+Enter`
  (`Cmd+Enter` on a Mac) where `claudeCode.useCtrlEnterToSend` is on. A
  chat whose tab is still there, or that a process holds again by the
  time you click **Open chat**, gets no pre-fill. **Why:** a refreshed tab
  dropped them without a word, and the effort menu offers Ultracode only
  at max.
- **How a chat's settings are read.** From its transcript, backwards, 16
  MB at most: `/effort`'s answers, the notices Claude Code writes with a
  prompt when Ultracode changed, and the level each turn a prompt of
  yours started ran at - so a max picked in the tab's effort menu counts
  as well. A compaction and a queued run's own notices are read as Claude
  Code reads them, so a chat switched off after either reads off.
- **A watcher started from a chat's terminal** no longer hands that
  chat's VS Code settings to its runs:
  `CLAUDE_CODE_SDK_READS_SESSION_STATE` (Claude Code 2.1.284) and
  `MCP_CONNECTION_NONBLOCKING` join the variables dropped.
- **A queued run's chat is marked as one.** Claude Code registers
  `claude -p` as an SDK run (`sdk-cli`), which the overlay drew as a
  terminal, `>_`; it is a play triangle now (`|>` in `chatoverlay
  -Print`), the delete chip stays greyed, the phone says `a queued
  prompt`, and the picker reads it as running.
- **Claude's questions on the phone.** A chat you run yourself that asks
  with `AskUserQuestion` shows the question on the board, `a question:
  Stability log` in place of `input needed`, and on the page of its `needs
  input` alert: every question, header and option, with each option's whole
  description. A very long text is cut and says so; a preview is not shown.
  The push says only `waiting on you: input needed (a question)`, and the
  question travels only on the sealed down topic. No hook, no setting: it
  is read from the chat's transcript, as the overlay reads it. **Why:** the
  alert said `input needed` and nothing more, so you went to the PC to
  find out what was asked.
- **Answer them from the phone, off by default.** `chatnotify -Ask on`, or
  **Answer Claude's questions from the phone** in the setup window (also
  `-AskWait <min>`, 240; `-Manual`), adds a small Claude Code hook as the
  plugin `chatq-ask`, through Claude Code's own CLI - your `settings.json`
  is never written. The hook runs beside the VS Code dialog, holds the
  question for the phone, and the first answer, the PC's or the phone's,
  counts. The phone picks options or types one under **Other**; it is
  text to Claude, never a deny, believed only on the phone's own sealed
  message, and refused above `reply.maxMode`. The watcher then checks the
  answer landed, and pushes `did not take the answer from the phone` or
  `went on without your answer` when it did not. `chatuninstall -All`
  removes the plugin first, and stops if it cannot. A question asked
  before the hook was loaded in that chat, a terminal chat, and a queued
  run's are shown, not answered. Each held question is a hidden Windows
  PowerShell of about 130 MB, 5 at most (`ask.maxOpen`), 4-8 seconds to
  start. **Why:** the question waits on you, and a phone that can show it
  can as well take the answer. It rests on how Claude Code 2.1.283 treats
  a hook on this tool, which its documentation does not describe, hence
  the landed check and the default of off. docs/phone-ask-spec.md has the
  design and what the spike saw.
- **The watcher starts under any execution policy.** The setup window and
  the outbox's sender, Windows PowerShell 5.1, start a watcher to listen
  for the phone's replies. For someone who only ever set a policy in
  PowerShell 7, 5.1's is still `Restricted`: that watcher could not load
  the script, said nothing, and no reply was read until a shell started
  one. It now starts with `-ExecutionPolicy Bypass` for the load alone,
  as the sender does, and drops it again before the loop, so the jobs it
  runs and your own alert command run under your policy. A watcher that
  fails to load says so in `data/logs/watcher.log`.
- **chatclean lists hidden chats again.** Since 0.8.1 a chat Claude Code
  left out of its lists is mended as a run into it ends, or as the window
  opens it. One hidden before that, or by a watcher that died mid-run, and
  neither run into nor opened since, stayed out of every window's history.
  `chatclean` now lists every such Claude chat again first, with the same
  one line at its end, and names each. A chat in use is left, and named;
  `chatclean` again once it is idle. Side transcripts are left alone.
- **The console moves from anywhere on its header.** A press on the
  header's padding, its grip or its counts drags the window; only its
  controls keep the press. Before, only the counts' own text took it.
- **One look for the panel and the console.** The console opens at the
  panel's opacity instead of fully opaque, and its header has the panel's
  **Opacity** slider and **Theme** chips: a change made there is the
  panel's when it comes back, kept in config.json, and the settings box
  shows it.
- **Continued one at a time, and said so.** The watcher runs one job at a
  time, so the chats one limit cut off are continued one after another,
  never side by side - with **Now** or **In turn** alike, since **When**
  is for Send alone and Continue always queues in turn. The queue said
  `sends 16:51` on every one of them all the same. Now only the first
  does; each of the rest says `after #9`, the job before it - in the
  console, the panel, the phone's board and `chatqlist`, and on an
  auto-continue's row. The console's queue gives the jobs behind a
  chat's first their time too, where they said only `queued`. Continue
  says `queued 4 continues - one at a time, each when its limit is
  over`; **Continue all**'s tooltip says it, and that When is for Send;
  Send's line says when **Now** waits for a job running, and the soon
  alert `3 queued · they go then, one at a time`.
- **A job's number is its own.** A new job took one past the highest
  number a saved job held, and `chatq` without `-Prompt` saves its job
  only once its editor tab is closed: a job queued meanwhile - from the
  console, the phone, auto-continue or another `chatq` - took the same
  number, and for the same chat the same prompt file, over the text in the
  open tab; removing either job then took the other's prompt, and
  `chatqrm <n>` reached only one of them. A prompt file in `data/queue`
  now holds its number from the moment the job takes it, and a number is
  taken holding `data/job-numbers.lock`, so a shell, the overlay and the
  watcher never take one between them.
- **Nor two jobs one id.** Two processes queueing for one chat in the same
  second could give both jobs the same id, and the second job's file
  replaced the first's. The id is taken under the same lock, and held by
  the job's folder until its file is saved.

## 0.9.0 — the overlay and permissions on the phone, cut-off chats continued, updates that wait

Five pieces of work land together: the phone gets the overlay, Claude's
whole answer and a queued run's permission prompts; usage heads-ups,
quiet hours and a spoken line come with them; a chat the usage limit cut
off is asked about at the reset, or continued by itself; and a new
version of the extension waits for the window's chats before it reloads.

### The overlay on the phone, and Claude's whole answer there

- **Claude's whole answer on the phone.** A `done`, `needs input` or
  `failed` alert's page now shows the chat's whole last turn above the box
  you answer in - its text, a line per tool it used (three or more fold
  into one), code blocks, and a limit or a 529 as a note - rather than the
  alert's 200 characters. **Show all** and **Copy**; while the keyboard is
  up it folds to one line, so **Send** stays in sight. Over 30,000
  characters (`reply.fullMax`) the start is left out and the page says how
  much. Nothing decrypted is kept on the phone: a reload fetches it again,
  and **Ask the PC for it** has it sent again once ntfy.sh has dropped it.
  `chatnotify -FullText off` leaves the excerpt only.
- **The overlay on the phone.** The reply page opened from a bookmark or a
  home-screen shortcut - no alert - is the board: usage with a bar per
  window, the chats waiting on you, working, cut off and idle, the queue
  with when each job sends, and Recent, in the overlay's order and
  colours, with a search over them; **Older chats** adds the PC's 30
  newest, Codex's too. Tap a chat for its view: where it runs, what a
  message would wait on, its newest prompt, **Send**, and what the
  overlay's chips and the console offer for it - **Send now**,
  **Skip**, **Stop**, **Continue**, **Allow edits & continue**, **Retry**,
  **Continue at reset**, **Don't continue** - and **Read the last answer**.
  **+ New chat** starts one in a folder chatq already knows, in
  `reply.newMode` (`default`). It refreshes every 30 s while it is on the
  screen, for 10 minutes. `chatnotify -Compose off` turns it off.
- **Listen all the time.** The PC reads the phone while an alert is out, as
  before; `chatnotify -Listen always` (or the setup window's **Listen all
  the time**) keeps a hidden PowerShell listening while a phone is paired,
  so the board works with no alert out: about 60-120 MB, and an ntfy.sh
  request every 20 s, 6 s for two minutes after the phone asked for
  something. It never keeps the PC awake. `chatqrun -Stop` ends it until
  the next shell or overlay start.
- **Within ntfy.sh's free limits.** The PC now also posts to a second
  topic, the down topic, worked out from the phone's key and in no push,
  link or file: sealed as a reply is (AES-256 and HMAC-SHA256, under a key
  of its own), raw-deflated first so most answers fit in one 4 KB message
  that ntfy.sh keeps 12 hours - a longer one goes as one attachment, kept 3
  hours. An address without an account gets 250 messages a day, which
  alerts through ntfy share, so whole answers stop at `reply.downPerDay`
  (150) and boards and acks 50 after that; the board says when few are
  left. Nothing the phone sends names a chat, a job or a folder - only
  handles the PC gave it - and every job it makes runs within
  `reply.maxMode`, as a reply's does. A phone paired on 0.8.0 needs no new
  pairing. The push that goes beside an act's sealed answer names no more
  than a push may: a new chat's says `new chat queued as #15 - runs in
  default`, never the title or first line typed on the phone, nor the
  folder.
- **Continue at reset is an answer, as the overlay's are.** It marks the
  cut-off in `data/auto/` as the reset ask's Continue does, so a
  continue you then skip from the phone (**Don't continue**) stays
  skipped: neither auto-continue nor the reset ask takes the chat up
  again for that reset.
- **A board with no overlay running** - built from a scan of the registry
  and the transcripts - is sent again for 40 s, past the page's 30 s
  refresh, and its cut-off look reads a transcript again only once it
  changed: inside a run, the scan held up the run's own output and its
  permission requests. A folder on another machine is offered without
  being looked at, as the overlay's Recent does.
- **Why:** "if I can open a browser and use it, why not display the whole
  overlay on it? - on the phone". An alert showed only the end of the
  reply, and the phone could reach a chat only through an alert about it.

### A queued run's tool call, approved from the phone

- **Approve a queued run's tool call from the phone.** A queued Claude run
  that meets a permission prompt - a `git push`, an edit its mode does not
  allow - was told no, and parked as `needs input` until you were back.
  With `chatnotify -Permit on` (or **Approve tool calls from the phone** in
  the setup window) it asks the phone instead: a `chatq · permission` push
  that names the chat and the kind of call, and a page that shows the call
  itself - sealed for the phone, so neither Join nor ntfy can read it -
  with **Allow once** and **Deny** (with a note for Claude). The run waits
  `permit.waitMinutes` (10) and goes on; a call nobody answered is denied,
  and the job ends `needs input` as before. Off by default: it lets a
  paired phone make a command run on this PC. An Allow is that one call,
  as shown - no "always allow", no other mode, no later call - and the
  bridge that answers claude believes it only when it opens the phone's
  sealed answer itself and it names that very request. Claude runs only,
  in `default`, `manual`, `acceptEdits` or `auto`; never for a question,
  a plan, chatq's own `data/` or a Claude settings file. 10 asks a run, 20
  an hour. A bridge that does not start costs that run once, retried
  without it. `-PermitWait`, `-PermitTools`, and `permit.*` in
  `config.json`. Spike S35 settled the contract against claude.exe
  2.1.283 (TESTING.md). The push goes even while you are at the PC and
  in quiet hours: the run waits on it, and a held one could only expire.
- **What the page shows is what Allow runs.** The PC works out the
  request's digest again from the request as it sends the card, and
  declines one whose file was changed after it was asked; the card hides
  only plain values that look like secrets - never one with `$( )`, a
  backtick, `|`, `;`, `&`, `<` or `>` in it - and when anything was hidden
  or cut to fit, the page says *Not all of this call is shown ... If you
  cannot tell what it does, Deny.* A write to a path on another machine
  says so, and is never looked at from the PC.
- **chatq's own files by any name.** The rules that never ask the phone
  now see `data/` and a Claude settings file however a tool names them:
  Git Bash's `/c/Users/...`, a `\\?\` or `\\localhost\c$` prefix, an
  NTFS stream (`::$DATA`), trailing dots, the 8.3 short name, `~` and
  `$HOME`, and a relative `data\` from chatq's own folder. A path that
  cannot be read counts as `data/`.
- **A permission push whose request could not be registered** - replies.json
  locked, say - no longer goes: it opened nothing on the phone for a request
  already declined.
- **The bridge reads past a byte-order mark.** A parent on .NET Framework
  whose console input is UTF-8 - a GitHub runner's Windows PowerShell -
  writes one into a child's stdin before anything else, and the bridge
  left `initialize` behind it unanswered. claude sends none; the bridge
  now skips one wherever it comes from.

### Usage heads-ups, quiet hours, read aloud, and Tasker

- **Usage heads-ups, with Send now.** A new phone event, `usage`. The
  overlay (Windows) alerts once when a 5-hour or weekly window, Claude's
  or Codex's, reaches `-UsageAt` (90% by default; up to three, `75, 90`),
  so a long task is not started into a wall. The watcher alerts 10
  minutes before a limit resets with prompts queued - its page offers
  **Send now**, which asks the PC to try at once, a probe first, so
  nothing is typed while the limit still holds - and once more when it
  has reset with two or more waiting. Each goes once, recorded in
  `data/usage-alerts.json` before it is sent. `-UsageAlerts off`,
  `-UsageReset off`; a `phoneEvents` list gets them only once `usage` is
  ticked, and `chatnotify` says so.
- **Quiet hours.** `chatnotify -QuietHours 00:00-07:00` holds the phone's
  alerts in that window, this PC's clock, except the urgent ones (`failed`,
  or `-Urgent`), and sends one summary when it ends - `held 00:00-07:00:
  2 done, 1 needs input`, a line each - from the next alert, the watcher
  or the overlay, whichever sees it first. Nothing is dropped: a summary
  that fails goes back and is tried again. The toast and your command
  still run; the command is told `CHATQ_QUIET=1`. Tests, replies and the
  pairing push always go.
- **Read aloud.** `chatnotify -Say 'needs input', failed` has Join speak a
  short line for those events - `Parser rewrite needs input`, in Korean
  for a Hangul title - not the alert's text. Off by default: Join speaks
  through the phone's speaker as well as headphones. Never in quiet
  hours, never for a reply, the pairing push or the summary.
- **A reply typed outside the browser.** An alert's link now takes
  `&text=...`, which the page puts in the box - it never sends it. A
  Tasker profile can turn a notification's reply field, or its own dialog,
  into one tap on **Send**; README has the recipe. A link that sent by
  itself could be opened by anything and would send with the phone's
  key, so the tap on Send stays the one thing that sends.
- **The setup window** has all four: Read aloud under Send test, quiet
  hours with what still comes through, usage and resets.

### What the limit cut off: asked about, or continued by itself

- **Once the limit is over, the overlay asks.** Five minutes after the
  reset, the chats the usage limit cut off are counted, and one prompt
  offers to continue them all: a toast, `chatq - limit over at 13:00`,
  `3 chats it cut off can continue: ...`, and a banner at the foot of the
  panel's header, `limit over at 13:00 · 3 chats it cut off can continue`.
  Rest on the banner for its chip, **continue 3** or **leave them**; the
  tray's menu has **Continue 3 cut-off chats** and **Leave them** at its
  top, gone again once it is answered; the console's **Cut off** header
  says it, with **Leave them** beside **Continue all**. A click on the
  toast opens the console, where the chats are listed - with
  `overlay.cutOff` off too - and it never answers by itself, since a toast
  is often clicked only to be rid of it. Continue queues *"Continue from
  where you left off."* for each, the job `chatq <title> -Continue` makes.
  Each cut-off is asked about once, and announced once, across restarts.
- **Left out of the ask:** a 529, which has no reset to wait for; a chat a
  terminal's `claude` holds - Claude Code continues it itself there, and a
  second writer would clash - named in the banner's tooltip instead; a
  reset over 12 hours ago; an old limit record with no reset time; and,
  while a 5 h or weekly window is still at its limit, everything, until
  that reset too. A chat with a job already queued or running is not
  asked about.
- **The reset time on the usage line.** Claude's line reads
  `5h 100% resets 13:00 · week 46%`: the window you wait on - the latest
  of those at their limit, else the 5 h one - with its reset, red while it
  is at its limit. The collapsed line and the tray dot's tooltip say it
  too (`5h 43%, resets 13:00`), and the tooltip counts `2 can continue`
  apart from the rest cut off. A narrow panel wraps the line rather than
  hiding a window. The bars view already had a countdown.
- **Ask is the default, and one switch turns it off.** The settings box
  has a seventh row, **Cut off**: **Continue**, **Ask** or **Leave**. From
  a shell, `chatq -AutoContinue ask|on|off`, which tells a running
  overlay. Both write `autoContinue` at the top of `data/config.json`,
  beside `liveIdle`. Off is how it was: the rows are only marked orange.
  Continue is the automatic mode, below.
- **Cut-off rows stay longer.** A row now stays while its reset is under
  12 hours ago, or while the cut-off is under 12 hours old, so a chat asked
  about overnight still has its orange row in the morning.
- **The scan runs with `overlay.cutOff: false` while the ask is on.** That
  setting still hides the rows; the ask needs the scan to count them. With
  both off, nothing is scanned, as before.
- **The phone, when you are away.** The ask goes to the phone as one
  `limited` alert, `limit over at 13:00 · 3 chats it cut off can continue -
  answer on the PC`, through the same gates as the alerts for the chats you
  run yourself. Its page offers Status alone: the answer is given at the PC
  (FUTURE_WORK).
- **macOS** (untested): the `CQ` menu has **Continue N cut-off chats** and
  **Leave them** at its top while there is an ask, a notification says it
  once, and the lines view shows the reset time. An answer names the
  chats the menu showed, so one cut off while the menu was open is not
  continued with them.
- **Auto-continue, chosen: `autoContinue: "on"`.** A Claude chat the
  usage limit cuts off gets *"Continue from where you left off."* queued
  for it by itself, a minute after the limit resets - above all the chat
  nobody has open any more, which nothing else would continue. Opt-in: the
  settings box's **Cut off** row is now **Continue**, **Ask** and
  **Leave**; `chatq -AutoContinue on|ask|off`, the tray's **Auto-continue
  cut-off chats** (checked while on; unchecked goes back to Ask), the Mac
  menu's item and **Chat Manager: Auto-continue cut-off chats...** in VS
  Code set the same `autoContinue`. Only the word `"on"` turns it on -
  `true` still reads as ask - and only for what the limit cuts off from the
  moment it is chosen: older cut-offs are shown, never queued, and the
  Windows overlay says what it does once, in a balloon.
  `chatq '<title>' -AutoContinue always|never|default` sets one chat,
  `always` continuing it even with the switch on ask or off. While it is
  on nothing is asked; ask and off leave the rows as they were.
- **What it leaves alone:** a chat a terminal's `claude` holds, a 529, a
  weekly limit days out, a cut-off you came back to more than 30 minutes
  after its reset, and one the reset ask answered. A chat open in a VS
  Code panel waits 5 minutes past the reset, for the panel's own
  auto-continue to go first. The overlay scans once a minute and the
  watcher every 5 while it runs. Each cut-off is queued once - one marker
  in `data/auto/`, the file the ask's answer is, so the two never both act
  on it; a continue you remove stays removed for that reset, even when a
  background task's note wakes the chat into the limit again before it;
  and 2 that fail in a row stop it for that chat. The streak and the
  chats set to always or never, in `data/auto-continue.json`, are changed
  under a lock, so the overlay and the watcher writing at once lose
  neither's change. It never touches what chatq runs itself: a prompt you
  queued still comes back as a continue when the limit cuts it off.
- **Every surface says what it will do with a cut-off chat,** and takes it
  back: the overlay's orange row reads `#12 auto 13:01`, `resets 13:00 ·
  never` and so on, in full in its tooltip; its chip has **don't continue**
  or **continue** beside open, left of the row's words; the collapsed line
  counts `(1 auto)`; the console's Cut off list has **Don't continue**, one
  click in the list and the queue alike, and a per-chat **Default / Always
  / Never**; `chatqlist` says what the switch is and whether anything runs
  to act on it, tags each cut-off, and shows `continue (auto)`; the board
  too.
- **The live alert for a chat the limit cut off is now `limited`** when
  auto-continue queued a continue for it - priority 0, about that job,
  with **Don't continue** on the phone's page - where it was `done`. So a
  `-Events` list without `limited` now drops it. The phone cannot turn
  auto-continue on or off.
- **`chatrm` drops a chat's auto-continue** without `-DropJobs`; a job you
  queued still keeps the chat. A chat deleted or archived before its
  continue runs is skipped without a `failed` alert.
- **The overlay's chip holds one chip or more,** made for each row - its
  tooltips too - a click counting only when it goes down and up on the
  same chip, the banner's answers included. Every row's title starts at
  one column, a row with no where mark keeping its place. **continue**
  clicked twice before the list redraws queues one continue, not two.
- **A kept auto-continue never hides.** With the switch turned to ask or
  off, a continue auto-continue had already queued stays in the queue and
  still runs at the reset: it now has a row of its own, where it had
  folded onto a plain orange row that no longer said so.
- **Why:** the owner asked on 2026-09-27 for an option to be told about
  a reset and continue on a confirm, as the default, and for the automatic
  continue beside it; both land here. Claude Code continues an open
  terminal session by itself, but not a chat whose tab was closed, a
  process chatq ended, or a PC that slept - and never says so on the phone.
  The spec, with how the two modes were fitted together, is
  [docs/auto-continue-spec.md](docs/auto-continue-spec.md).

### An update, and the chats a reload would stop

- **An update no longer ends the chats of a window by surprise.** A new
  version of the extension runs in a window only once that window
  reloads, and a reload ends every `claude` process the Claude extension
  started there: a turn in flight, a permission prompt, a workflow or a
  background agent, in every Claude tab of the window. On 2026-09-27 that
  happened twice, each time after a new VSIX was installed from the
  command line while chats worked. Now the running version notices the
  new one - by VS Code's event, or its `extensions.json` changing, which
  also tells the same version installed again - and says so once per
  install, naming what a reload would stop: *VS Code Chat Manager 0.9.0 is
  installed. Loading it reloads this window, which stops the 2 chats
  working here: ...*, with **Reload when they're idle**, **Reload now** and
  **Later**; with nothing working, a one-line notice and **Reload the
  window**, looked at again as it is clicked. **Reload when they're idle**
  puts an item in the status bar (a click cancels it) and looks every 25
  seconds; it reloads the window once every chat of the window has been
  idle for a minute straight, and never while a queued prompt goes into
  one of them - a chatq job running counts even when no process of the
  window holds its chat any more. Right before the reload the registry is
  read once more, so a turn begun during the last look still holds it. A
  reload that fails is said, with **Try again**. It lives in memory only:
  a window closed meanwhile does nothing. Which chats are the window's,
  and which work, is the script's word (`Get-ChatHostWork`,
  `src/host-work.ps1`): a `claude` whose parents lead to this window's
  extension host, busy, waiting on a prompt, with a workflow or background
  agent out, or with a queued run going in - the judgement `Test-ChatIdle`
  makes of a folder, made of one window. A background shell still does
  not count.
- **A reload, not Restart Extension Host.** VS Code's Developer command
  starts the extension hosts again from the extensions it already had:
  checked in VS Code 1.108.2, a VSIX installed from the command line is
  never loaded by it, and the old version comes back up. A reload loads
  the new one; the terminals survive it. Tool-folder scripts too old to
  look at the chats (before 0.9.0) are said as that, in the log and the
  status bar.
- **chatq's own reloads look at the window's chats first.** A reload the
  window takes by itself - after a delete with `autoReload`, or after a
  queued run - and a plain **Reload** clicked on a request that found
  nothing working, maybe minutes later, now look at this window's chats
  again right then, whatever folder they are in. One working, and the
  window says which and asks, with **Reload anyway**; one that cannot be
  looked at stops a reload the window would take by itself. **Reload
  anyway**, clicked on a warning within a minute, reloads as before;
  clicked later, the window's chats are looked at again, and any working
  that the warning did not name is asked about first.
- **Why the reload and the second look:** a review of the integrated
  0.9.0, before release, found that the restart never loaded the update,
  and that a Reload anyway could be clicked hours after a warning that
  named one chat, over another's workflow started since.
- **chatrm waits for a safe reload by default.** What `-WaitForIdle` did
  is now what every delete does while a VS Code window is up: it blocks
  until the project's chats have been quiet for a minute, then says the
  window is safe to reload. `-NoWait` says whether now is safe and
  returns, as a delete did before; `-WaitForIdle` is still accepted.

## 0.8.1 — chatnotify, and hidden chats listed again

- **chatqnotify is chatnotify.** It is no longer only about chatq's queue:
  the same command sets up replies from the phone and the alerts for the
  chats you run yourself in VS Code or a terminal. The help, the cheat
  sheet, the setup window's hints and VS Code's **Phone alerts...** all
  say `chatnotify` now. `chatqnotify` still works, as an alias, and
  `Get-Help chatqnotify` finds the same help.
- **A chat a queued prompt runs into stays in Claude Code's list.**
  Claude Code leaves a chat out of its session list - and will not restore
  it into a tab - when the first `entrypoint` in its transcript's first
  64 KB, or with none there the last one in its last 64 KB, is an SDK's. `claude -p` stamps
  `sdk-cli`, so one queued prompt or phone reply hid a chat whose first
  prompt was a pasted screenshot. Now, as a run ends, the watcher adds one
  line at the chat's end - `{"type":"chatq-listed",...}`, a type Claude
  Code's loaders skip - that lists it again. The file keeps its write
  time.
- **A hidden chat opens from the overlay again.** Before the open chip,
  **Chat Manager: Open chat...** or **Show it** opens a chat in a tab, the
  extension checks it as Claude Code does, and mends one hidden by its
  last records the same way - one hidden before this version, or whose
  run was cut short. One busy in a process right now, or whose line
  cannot be written, is left, and said, rather than opened blank. One
  hidden by its first records can never be listed - every chat **+ New
  chat** started, or your own `claude -p` - so instead of a blank tab it
  is offered in a terminal, `claude --resume`.
- **A chat opened from the overlay has its header again.** Its tab showed
  the chat with nothing above it - no title, no **Session history**, no
  **New session** - and an edit to approve came without its diff. The
  extension opened it with Claude Code's `primaryEditor.open`, which makes
  every tab a "full editor", a mode without them. It now opens an ordinary
  Claude tab, as a tab's own **New session** does, in the same group as
  before, still making no group and locking none, and leaving
  `claudeCode.preferredLocation` alone. An edit to approve shows its diff
  again; with editor groups not locked, it opens in the chat's own group,
  in front of the chat, as it does for any Claude tab. A tab opened the old
  way keeps its mode through a reload: close it once and open the chat
  again. With Claude Code older than 2.1.281, or one that refuses the new
  way, it opens as it did.
- **A chat a queued run went into shows the run, even with you at the
  PC.** A reply from the phone into a chat open in a VS Code tab ran
  beside that tab's own process, and the window only asked **Show it?**.
  A message typed into the tab instead went on from the tab's memory:
  the chat forked, and the run's turn stayed on a branch neither the tab
  nor its process ever saw. Now, when the chat's process here is idle,
  the window does **Show it** by itself as the run ends - at the PC too,
  and while other chats work, since it touches that one chat alone: its
  idle process ended, its tab closed and opened again from disk. And
  when you are away, a chat nothing holds opens in a tab by itself even
  while another chat works. `chatManager.autoReloadAfterRun: false`
  still makes the window always ask.
- **A job you answered in the chat stops saying it needs you.** A queued
  prompt parked on input - a tool it was not allowed, with nobody there -
  kept its chat's row amber, and `chatqlist` and the phone's status saying
  `needs you`, long after you had gone on in that chat yourself. Now the
  overlay skips such a job once anything is typed into its chat after it
  stopped, `answered in the chat`, as a reply from the phone already did.
- **No reload for a new chat.** A window on the folder a **+ New chat**
  started in is only told of it now: Claude Code lists no chat `claude -p`
  started, so the reload it used to offer showed nothing, and cut off
  whatever else worked in that window.
- **The phone's status shows Claude's usage as it is.** It read the figure
  from Claude Code's own cache, which moves only when Claude Code asks: on
  2026-09-27 it said 37% of the 5 h window, 35 minutes old, while the
  overlay showed 62%. It now takes the overlay's live figure when that is
  newer, and `chatqlist` does too.
- **Why:** on 2026-09-27 a chat answered from the phone vanished from VS
  Code's list, and each open from the overlay made a blank chat instead.
  Its first prompt was a screenshot, and the reply, run as `claude -p`,
  wrote `sdk-cli` last. TESTING's S25 had left open whether VS Code lists a
  chat `claude -p` started: it does not (S37). A run under an entrypoint of
  chatq's own would list both kinds, but Claude Code also turns on for it
  what it keeps off for `claude -p` - the Artifact tool, autoDream - so
  runs stay `sdk-cli` (FUTURE_WORK).

## 0.8.0 — replies from the phone, and alerts for the chats you run yourself

- **Phone alerts in a window.** `chatqnotify -Setup` opens one window for
  all of it: the Join key - the key itself, or the whole push URL Join's
  page shows - **Find devices**, the device to send to, and **Send test**;
  replies from the phone and **Pair phone**; which events reach the phone,
  the quiet minutes, the chats you run yourself and the desktop toast; and,
  folded away, ntfy and your own command. **Save** goes through the same
  code as `chatqnotify`'s switches, so the two never disagree about
  `data/config.json`. The overlay's tray has it as **Phone alerts...**, and
  VS Code's command palette as **Chat Manager: Phone alerts...**. It is WPF,
  so Windows only; elsewhere `chatqnotify -Setup` prints the switches that
  do the same.
- **Alerts for the chats you run yourself.** A chat you drive in VS Code or
  a terminal's `claude` now reaches the phone too, not only what chatq
  runs: `needs input` once it has waited on you for 20 seconds, `done` when
  a turn ends. Only while you are away - no keyboard or mouse for
  `quietMinutes` - and then whichever window is in front, its own VS Code
  window included. Never about a chat chatq is running a prompt in, and one
  alert per chat and event every 3 minutes at most. The overlay sends them,
  so it must be
  running (it starts by itself on Windows), and one started before this
  version has to be restarted: `chatqnotify` says when it runs an older
  copy. `chatqnotify -LiveAlerts off` keeps the phone to what chatq runs.
- **Reply from the phone.** With `chatqnotify -Reply on` and a phone
  paired, a tap on an alert opens a page to type the chat's next prompt, or
  press **Allow edits & continue**, **Continue**, **Retry**, **Skip**,
  **Stop** or **Status**, as the alert allows. The phone seals the reply and
  posts it to an ntfy.sh topic; the watcher polls that topic, does what it
  says, and answers with a push - itself an alert that can be answered.
  After an alert that can be answered goes out, the watcher listens for
  `reply.hours` (12) - one is started just for that when none runs - and
  never keeps the PC awake for it. `chatqrun -Stop` stops the listening
  too, until the next such alert.
- **A reply never runs a job above `acceptEdits`.** A job a reply queues or
  requeues runs in its old job's own mode, or the chat's, brought down to
  `reply.maxMode` in `config.json` - `acceptEdits` unless set otherwise -
  and a Codex one in `workspace-write` at most. Nothing in a reply picks a
  mode, and links in its text pull no files from `data/queue`.
- **Pairing, confirmed by a code.** `chatqnotify -Pair`, or **Pair phone**,
  sends one push; the page it opens makes a key on the phone, sends it back
  sealed, and shows a six-digit code. The phone is paired once you confirm
  the same code on the PC - `chatqnotify -Pair` asks, or
  `chatqnotify -Confirm 123456`, or the window's **Confirm**. Pairing again
  replaces the phone at once, and every link already out stops working.
- **No secret in an alert.** After the pairing, an alert's link names the
  alert and nothing else, so Join - whose push is a GET, logged in full -
  and whoever reads an ntfy alert topic cannot answer one. ntfy.sh sees the
  reply topic and the sealed text only, and GitHub Pages serves a static
  page that loads nothing. `chatqnotify -ReplyPage <https URL>` serves that
  page from a copy on a site of your own.
- **One notification per chat.** Join shows the alerts about one chat as
  one notification: `done` replaces `started` instead of piling up under it
  (`join.perChat`, on unless false). Join's alerts carry chatq's icon
  (`join.icon`; `""` for none).
- **Which events reach the phone.**
  `chatqnotify -Events done, failed, 'needs input'`, or the window's
  boxes, keeps the rest off the phone; the toast and your command still get
  every one. `all` puts them back. Tests, replies and the pairing push
  always go.
- **`chatqnotify -Devices`** lists the devices on the Join key saved, or on
  `-ApiKey`, with Join's groups after them.
- **`chatqnotify` alone says more:** the events the phone gets, whether the
  chats you run yourself alert and what stops them, whether replies are
  on, the phone paired and since when, how long the watcher listens, the
  last reply, and the answers to a pairing waiting for their code.
- **Why:** on 2026-09-26 Join was set up, its test reached the phone, and
  then no alert came. Nothing was broken: only prompts queued with `chatq`
  alerted, and the chats run straight in VS Code never passed through
  chatq. They alert now, through the overlay, while you are away. The
  replies were asked for at the same time, so an alert can be answered
  where it is read; the pairing, its code and the mode cap are there
  because a push is read by more than the phone it goes to.

## 0.7.2 — chats open as tabs, and the overlay starts by itself

- **The open chip opens a tab.** A click on a row's **open** opens the chat
  in an editor tab of its own in its window, or brings forward the tab that
  already shows it. It ends no process and judges nothing busy, so a tab
  there already comes forward as it is: a queued run that ended while that
  tab's process lived shows through **Show it**, or once the tab is closed
  and the chat opened again. The chip no longer depends on
  `chatManager.showFresh`; with no Claude Code extension the window says it
  cannot open the chat.
- **Never a second copy of a working chat.** A chat working in its window
  outside the tabs - in the side bar, most likely - is not opened: a tab
  would start a second process on it mid-answer. The window says so; click
  open again once it finishes. One idle there still gets a tab and a second
  process, since nothing reaches the side bar's chat, and the window says to
  close the side bar's copy. A working chat opens only when exactly one
  Claude tab here carries its label and no other chat of its folder would:
  two tabs of one label, a label another chat has - the same title, or the
  same first 24 characters, open or not - or a chat of no title, count as
  no tab, since a tab carries no session id and that one may be the other
  chat's; renaming one of the two tells them apart. The other chats looked
  at are those of every folder of the window as well as the chat's own,
  the newest 200 of each; a look not done in 1.5 s counts as shared, and
  says so in the log. On a Mac, where the window holding a chat cannot be
  told, a working chat with no tab of its own here is left the same way.
- **A terminal's chat is turned away, working or not.** Whose a chat was
  used to be looked up only once it was idle, so a terminal's `claude`
  mid-turn read as a window's working chat and was sent on to VS Code. The
  tray now says it is open in a terminal, and nothing is written.
- **The chat's tab group is left unlocked.** Claude Code locks the editor
  group it makes for its tabs (`claudeCode.lockEditorGroups`, on by
  default), and a chat's tab opens into such a group, so the next file went
  to another group, or a new one. Once the chip, Show it or the picker has
  the tab up, the group holding that chat's tab is unlocked - only while it
  is the active group, since the command acts on that one, and only when it
  holds Claude tabs alone; one holding other editors is left as it is.
  `claudeCode.lockEditorGroups` set to `true` in any settings scope makes
  the lock your choice, and no group is unlocked. Claude Code's own **Open
  in New Tab** still locks the group it starts;
  `"claudeCode.lockEditorGroups": false` stops that.
- **Show it uses a tab too.** After a queued run the chat's old idle
  process is ended as before, and the chat opens in a tab of its own,
  loaded from disk. Reload Webviews is gone. Where the old process is still
  there, the window offers a reload, as before - with **Reload anyway** when
  the chat, or another in its folder, is working. The warning says which:
  when only another chat works, it says that chat is still working and a
  reload now would cut it off - no longer that the old process could not
  be ended, with a plain **Reload**. Where the window had the chat outside
  its tabs, it says that copy is stale now and can be closed.
- **A stale tab is found by Claude's label.** A chat already open in a tab
  has that tab closed and opened again. Claude shortens a title over 25
  characters to its first 24 and `…`, and a tab labelled that way was not
  recognised, so it stayed stale. Both forms count now. A tab whose label
  another Claude tab shares, or another chat of the folder would carry, is
  never taken as sure - closing the wrong one would cut off the other
  chat - and a chat with no title never is, since every such tab reads
  "Claude Code"; you are told to close the tab yourself. A new tab that
  turns up just before the close is taken as the chat's, and nothing is
  closed. A Claude tab is known by its `viewType` alone, the Claude Code
  extension's `claudeVSCodePanel`: Cline's tabs, whose name holds "claude"
  too, and a markdown preview are never closed or taken for a chat.
- **Resize the overlay.** A handle beside the grip: drag it sideways for
  the width, up and down for the rows, with the panel's right edge held
  under the buttons. The settings box has **Width** (260-800) and **Rows**
  (1-30) sliders, and `chatoverlay -Width 460 -Rows 12` sets both from a
  shell, refusing a value out of range. The panel never runs past its
  screen's bottom from wherever it sits - moved lower, it draws fewer rows,
  and moved up again, more - and the rows that do not fit are counted on
  the `+N more` line.
  Dragged down, it never ends with fewer rows than were set, even with
  fewer chats open than that. Near the screen's left edge it widens to the
  right rather than off the screen. The sliders show the size a drag left,
  and where a change of width moved the panel is kept for its next start.
- **The overlay starts by itself** on Windows: with every new shell, and
  when a VS Code window starts - as soon as the scripts are in place. On a
  first install that is the moment the extension has copied them, before
  it asks about the profile line, and that question may never be answered.
  It is where a chat is opened from now. Three ways stop that, all one
  switch: **Chat Manager: Overlay: start by itself...** in the command
  palette, On or Off - Off also closes a running overlay, and no terminal
  or profile line is needed; `chatoverlay -AutoStart off`; or
  `overlay.autoStart` false in `data/config.json`. A missing `config.json`
  reads as on. One that is there but
  cannot be read reads as off: it may be the file that said off. On macOS
  it stays off until `-AutoStart on`. A start that fails says why in
  `overlay.log`. During an update it starts from the new scripts once they
  are all copied, and not while another window is copying them.
- **Open chat... in VS Code.** **Chat Manager: Open chat...** in the command
  palette lists this window's Claude chats, newest first and 200 at most.
  Each shows its title - a rename, Claude's own title, else the first
  prompt - how long ago it was written, and what runs it: open, working,
  a terminal, or a queued prompt running. Picked, it opens in a tab as the
  overlay's chip opens one. A chat in a terminal, one a queued prompt or
  any `claude -p` is going into, or one working elsewhere in VS Code, is
  not opened. One open and idle elsewhere - another window, or the side
  bar - asks first, with **Open here too**. What runs it is read again
  after that question and right before the open, so one that began to
  work meanwhile is refused as it would have been at once. A tab here
  counts as the chat's only while no other chat of its folder would carry
  its label, as with the chip: working, such a chat is refused; idle, it
  asks. The list is up at once; a title not read within a quarter of a
  second shows the chat's id until it is. A `$(` in a title is shown as
  typed, not as an icon.
- **Recent in the overlay.** Under the open chats, a faint **Recent** list
  of the newest Claude chats not open, one line each: project, title, how
  long ago. Rest on one and **open** opens it as a tab, as on an open row.
  Five by default. The settings box's **Recent** row picks off, 5 or 10,
  and `chatoverlay -Recent 12` any count from 0 to 20 (`overlay.recent`; 0
  is none). Lines the screen cannot hold are left off. Side transcripts,
  empty ones and chats whose folder is gone are never listed; whether a
  folder is there is asked again every 3 minutes, and never of one on a
  network share or mapped drive, which counts as there - a share asleep
  would hold the panel. `chatoverlay -Print` lists them too, the whole
  count at once; the Mac panel does not yet.
- **A dot for a turn you have not seen,** on Windows only. A chat that
  finished a turn - went from working or waiting to idle - while you were
  elsewhere has a small blue dot before its state, and the collapsed line
  and the tray dot's tooltip say `2 new`. A chat whose window was in front
  as it finished gets none: any window of its VS Code counts, or for a
  terminal's `claude` any tab of the terminal that draws it. A console
  that Windows handed off to Windows Terminal cannot be matched to it, so
  that chat gets the dot even with its tab in front. The chip clears it
  once its open sent the window its request (`ended 0`, `25`, `40` or `41`
  in `overlay.log`); one turned away - a chat at work (`10`), a
  terminal's, a queued prompt running in it - one that failed before the
  request, or one not answered within 60 s leaves it. A new turn, or its
  session ending, clears it too. The overlay keeps it in memory only: a
  restart clears every dot, and reading the chat in VS Code clears none.
  The Mac panel has no dot: it has no chip to clear one, and no window in
  front to spare a chat one.
- **Where each chat runs.** After a chat's dot, a small window outline for
  a VS Code panel, or `>_` for a terminal's `claude`, from its entry in
  `~/.claude/sessions/`. `chatoverlay -Print` and the Mac panel put `>_`
  before a terminal's chat.
- **Compact rows.** The settings box has a **Style** row: **full**, each
  chat with its newest prompt under it, or **compact**, one line a chat.
  `chatoverlay -Compact on` does the same from a shell; it is `prompts`
  turned off. The box is laid out afresh to stay short: Width and Rows
  share a row, and Style and Recent come under Theme and Usage.
- **A quicker open chip.** It comes after a 400 ms rest on a row, not a
  whole second: a pointer crossing the panel seldom rests even that long on
  one row. `chatoverlay -ChipDelay 250` sets it, 100 to 3000 ms
  (`overlay.chipDelayMs`).
- **The console opens in the panel's place.** It is no longer a window of
  its own: the console button, the tray's **Open console**, the console
  hotkey and `chatconsole` turn the panel itself into the console, grown
  from its top-right corner - its right edge and top held, kept on the
  panel's screen - at the size it was last left, else 980 x 680. While it
  is the console it is a window like any other: it takes clicks and the
  keyboard, has a taskbar button and a place in Alt+Tab, and is not kept
  on top, so another window can cover it and files can be dragged onto it
  from Explorer. Its header moves it and the grip at its corner resizes
  it. The buttons, the open chip and the panel's rows rest meanwhile.
  **Esc**, **← Panel** in its header, the console hotkey again while it
  is in front, or Alt+F4 bring the panel back exactly as it was - its
  place, width, rows and fold, and the tray if it was hidden there - and
  the draft is kept. The hotkey on a console another window covers brings
  it forward instead; the tray's item and `chatconsole` only ever bring it
  forward, as a command from a shell can arrive a couple of seconds late.
  Hide, collapse, lock, unlock, Move to top right and Quit go back to the
  panel first - after the folder picker closes, or a drag of the header
  is let go, when they come during one; a theme change keeps what is
  typed, in the console still. A width set from a shell meanwhile holds
  the panel's right edge as it comes back, and where that leaves it is
  kept for the next start. A size kept from a screen at a lower scale
  opens no smaller than 640 x 420 on this one, its right edge still at
  the panel's. Its list draws each chat as the panel's rows do - the
  dot, where it runs, the state, the unread dot - one line each, the
  picked one with an accent bar, and a recent chat faint as in the
  panel's Recent. `console-state.json` keeps its size and the draft, no
  longer a place or a maximized state: where it opens comes from the
  panel.
- **Logs.** Every click on open goes in `overlay.log` with the chat's short
  id, and so does how it ended, 0 included. `watcher.log` gets one `show`
  line per show: how it was asked for, the old process, busy, the windows,
  the outcome. The extension's log says whether each open made a new tab,
  revealed one, failed or was not opened, and which verdict Show it and a
  show on its own acted on. A command the extension runs for a show - an
  open, a tab closed, a reload - gets 15 s: one that never answers is
  logged and taken as failed, and the shows after it still run.
- **Why:** on 2026-09-25 a click on open ended the chat's idle process, and
  the window then opened the chat and ran Reload Webviews. That left two
  views, each resuming the chat with a process of its own. A second click
  ended both, and the stale tab was not recognised by its shortened label,
  so both views were left on "Claude Code process exited with code 1".
- **Fixed:** an overlay row for an open chat nothing had titled yet is
  titled by its first real prompt again. With two or more user records at
  the transcript's start, they were read as one line, and no prompt was
  found in it.
- **Fixed:** the overlay's buttons stuck under the panel. They go under it
  when the panel sits too near the screen's top, and they kept to that side
  for as long as there was room under it - so a panel started at the top
  and then dragged down had them under it until the overlay restarted.
  They now keep their side only while they are up, so opening the settings
  box, or a drag short of the screen's edge, still never moves them out
  from under the pointer; the next time they come, they are on the panel's
  top edge wherever there is room.

## 0.7.1 — a new icon, and releases from CI

- **A new icon:** the Marketplace and the Extensions view show a photo in
  place of the chat bubble, on the same rounded square. The photo meets the
  square halfway: a little of its left end is cut, and bands filled with
  its own background make up the rest above and below.
  `docs/make-icon.ps1` makes it from `docs/icon-source.jpg`.
- **The Marketplace listing shows the terminal too:** Tab filling in a
  title for `chatrm`, `chatq` queueing a prompt, and `chatqlist`. vsce
  takes no SVG there, so `docs/make-demo.ps1` now also draws those three
  frames as PNGs, with headless Edge.
- **Updating, said plainly:** a window runs a new version of the extension
  once you click **Restart Extensions** or reload; VS Code restarts none by
  itself. An extension installed from a `.vsix` file is pinned and never
  updates by itself until **Auto Update** is turned on for it.
- **Releases from CI:** `.github/workflows/publish.yml`
  publishes a `v*` tag and makes its GitHub release, signing in as an
  Entra app rather than with a PAT. Run by hand, it publishes nothing: it
  builds the VSIX, signs in, and checks that the publisher accepts the app
  (docs/marketplace-spec.md, Publishing).

## 0.7.0 — one extension on the VS Code Marketplace

- **Install from the Marketplace.** **VS Code Chat Manager**
  (`redaechan.vs-code-chat-manager`) carries the PowerShell scripts as
  well as the VS Code half. On its first start it puts them in
  `~/Tools/VS-code-chat-manager` (`chatManager.folder` moves it), asks once
  before adding the profile line - **Add**, **Not now**, **Never** - and,
  where the execution policy would stop that line, offers to allow local
  scripts for your user. VS Code's own extension updates then keep the
  scripts up to date, and each moves a running watcher and overlay onto the
  new copy.
- **What it never does:** write into a git checkout - the folder or any
  folder above it; it says when the scripts there are another version -
  write over a newer copy or one whose version it cannot read, write into
  a folder that holds other files, or act in two windows at once. A
  `chatManager.folder` that is not a full path is refused for the default.
  Where the policy would stop the profile line, **Add** says so and allows
  local scripts first; where a line is already there but never runs, it
  offers that once. "Added." comes only once the line is really there; a
  copy or an add that fails says so. The answers live in
  `data/extension.json`, beside the rest. Every process it starts is logged
  with its command line under **Chat Manager: Show log**; **Chat Manager:
  Install terminal commands** asks again, even after Never.
- **One version for both halves.** The extension was 2.1.0; it is now the
  tool's own, 0.7.0, and `extension/build.js` refuses to pack the two apart.
- **The old extension retires.** `phal40lax78.chat-manager-reload`, which
  was copied into `~/.vscode/extensions/` by hand, is replaced. While it is
  still installed and watches the same file, the new one handles no
  request, since both would act on each, and offers to uninstall it. Settings move from `chatManagerReload.*`
  to `chatManager.*`; the old ones are still read where the new ones are
  unset, and `signalFile` gives way to `chatManager.folder`.
- **Why:** nothing kept the two halves in step. On 2026-09-25 the script
  was 0.6.0 while every window still ran the 2.0.0 extension, which ignores
  the overlay's open requests, so the open chip did nothing.
- **`chatinstall -NoRestart`**, for the extension, which installs into
  each PowerShell in turn and restarts the watcher and overlay once, after
  the last. `chatinstall` now names `chatManager.folder` where it named
  `chatManagerReload.signalFile`.
- **The one-liner stays**, for the terminal alone.

## 0.6.0 — show the chat fresh

- **Show it, not Reload.** A chat a VS Code window still holds shows a
  queued run only once that window redraws it. 0.5.0 reloaded the whole
  window for that; now the window redraws only its web views (**Developer:
  Reload Webviews**) and opens the chat where you read it - the side bar
  here. It does this by itself under 0.5.0's rules: you away, nothing in the
  folder working, a window on exactly that folder, and that judgement at
  most 20 s old. Otherwise the notification offers **Show it**. The click
  ends the chat's old idle process and judges the folder again, right then;
  with a chat working it opens the chat fresh in an editor tab of its own
  instead, and nothing is cut off. Terminals, editors and other extensions
  keep running either way. Whether other web views (a Codex chat, a
  preview) and an unsent draft come through is still to be checked (S30
  items 14 and 2).
- **The old process.** Reload Webviews alone is not enough: the chat's old
  `claude` process keeps the old memory. While you are away, chatq ends it
  as the run finishes, so your next message there starts from disk even if
  nothing redraws the view. While you are at the PC it is left alone until
  you click Show it - what a side bar does when the chat on screen loses its
  process is still to be checked (S30).
- **The overlay's open chip.** Move onto a Claude row and rest a second, and
  a small **open** appears at its right end - a window of its own, like the
  buttons', that takes no focus and is in neither Alt+Tab nor the taskbar;
  the rest of the panel stays click-through. It shows once per visit to a
  row, and a pointer it came up under has to move off it before a click
  counts. A click shows the chat up to date in its window, the same way,
  and brings that window forward with `code -n <folder>` - or opens one
  there, which shows the chat as it starts. The tray says when it could not:
  a queued prompt running in that chat, a terminal holding it, a window with
  other folders open, no `code` command. A window on exactly the folder is
  told from its title, a profile's name after the folder's included.
- **The overlay's buttons can be pointed at directly.** They came up only
  after the pointer rested on the panel, so reaching them meant going to the
  panel, waiting, and crossing to them before they went. Resting on the spot
  they go - above the panel, or below it near the screen's top - brings them
  too, and the gap between them and the panel counts as theirs. The same
  350 ms rest applies: a pointer passing over that corner on its way to the
  window underneath must not find buttons that take its click. No rest
  counts while a mouse button is held, so a tab or a file dragged across
  that corner in the app below is never dropped onto them.
- **What is never ended.** Only a VS Code window's process is ever ended -
  its registry entry says `claude-vscode` and its parent is `Code.exe` -
  never a terminal's, and never one busy, waiting, or with a workflow or
  background agent in flight; its registry file is read again just before.
  A chat open in a terminal is never shown in VS Code as well: that would be
  a second writer, and the alert says to type there. `liveIdle: stop` now
  goes through the same checks, and with background work in flight it
  waits, as for a busy chat. Ending a process ends the background shells it
  runs too, dev servers included. Background work is told apart by who
  started it - each transcript record names its writer, `claude-vscode` for
  the window, `sdk-cli` for a `claude -p` run - never by when: a workflow
  the window's own process started holds it whenever it began, even during
  a queued run, and one a finished queued run left behind never holds it.
- **Never beside a run.** A queued prompt going into the chat, or any
  `claude -p` writing into it, makes Show it and the chip leave it alone
  and say so: showing it then would load it part way through. After a run's
  or the chip's request, the next queued run into that chat waits 30 s
  while the window shows it; a run into a chat a window opened while the
  run went on is followed by the same Show it, since that window loaded it
  part way.
- **The window's other idle chats.** Reload Webviews ends their processes
  as well; each starts again, from disk, when you open it.
- **The alert** says what to do by what became of the old process: `Show it
  in VS Code to see the run`, `... before typing in this chat` when it was
  left running, or to type in the terminal that holds it.
- **The extension** is 2.1.0, with `chatManagerReload.showFresh` (on); off,
  or without the Claude Code extension, it reloads as 0.5.0 did. The overlay
  asks through a file of its own, `data/open-request`, so a click and a
  run's request never overwrite each other. **Update the extension too:** a
  2.0.0 one would now offer a reload after `liveIdle: stop` runs as well.
- **Unchanged:** deletes, archives and new chats still reload the window.
  Whether Reload Webviews would do for them is S30.
- **Fixed:** the command lines chatq builds for its own child processes -
  the toast on PowerShell 7, the watcher, the console's index sync, the
  overlay - doubled only `'`. PowerShell also ends a quoted string on a
  curly quote, so a reply's excerpt with one could end the string early; all
  four are doubled now.
- **Which `code`.** The chip's `code -n` uses the `code.cmd` beside the VS
  Code that is running, before the one on PATH: a machine with two installs
  may have the other first on PATH. On the machine this was built on that
  was a system install left half-updated, whose `code` crashed every time,
  so the first real clicks raised no window. `watcher.log` now names the
  `code` that failed. `CHATQ_CODE` still overrides it.
- **Fixed:** a new index that could not be swapped in was dropped without a
  word. Anything reading the index at that moment - the overlay's console,
  its 10-minute sync, a virus scan - fails the swap, and a restored or new
  chat then stayed missing from Tab until the next sync. The swap now tries
  five times over about 0.4 s, then warns.
- **Layout: the script and `src/`.** The one file had passed 13,000 lines.
  `VS-code-chat-manager.ps1` now loads fourteen parts from `src/`, in the
  order the file had them; nothing they do changed, and the profile line,
  the watcher and the overlay still load the same path. Copying it by hand
  means copying `src/` with it; without a part it says which and loads
  nothing. The one-line installer downloads the repo as one zip, since
  files fetched one by one from raw.githubusercontent.com can come from two
  versions for minutes after a push. The self-test is split the same way,
  into `tests/sections/`.

## 0.5.0 — chatq in a window

- **`chatconsole`**, the overlay's window for chatq: pick a chat - cut off,
  open in VS Code, recent, or found by search - write to it, and send it now
  or queue it. Also the speech bubble on the overlay's buttons, **Open
  console** in the tray, and **Ctrl+Alt+Shift+Q** (`-ConsoleHotkey`). It
  takes the keyboard only when you open it, and closing it keeps the draft -
  the chat, the text, the files, the choices - across restarts too.
- **Files by drag and paste.** Drop files on the prompt, or paste a
  screenshot or files copied in Explorer with Ctrl+V; each is copied aside at
  once, off the window's thread, and moves into the job on Send.
- **Send now.** The job goes to the front and runs within seconds; a chat
  working in VS Code is looked at every 30 s rather than every 5 minutes. A
  line says beforehand what Send will do: a limit, a busy chat, a reload.
- **New chats.** + New chat starts a Claude chat in a folder, named by you or
  by the prompt's first line. Its session id is chosen when it is queued and
  handed to `claude -p --session-id` with `--name` (spike S25), so a retry
  after a limit continues that same chat, never a second one. The extension
  offers a window on that folder a reload to pick it up; whether VS Code's
  chat list then shows it is still to be checked (S25).
- **Cut off, marked.** The overlay colours chats the limit or a 529 stopped
  orange - `cut off - resets 13:00` - and gives one not open a row of its
  own; the console continues one, or all of them. It looks a week back for
  a limit still ahead, and otherwise at the last 12 hours; it looks again
  at once when a job or a chat's state changes, never reads a chat that is
  working, and reads a transcript again only once it changed.
- **The queue as a console.** Each job says where it stands; pick one for
  its reply, its log, and Try now, First, Remove, Cancel, Requeue or Write to
  this chat; a waiting prompt can be edited in place.
- **One job core.** `chatq`, `chatqrm`, `chatqrun`, `chatqlog` and the
  console make and change jobs through the same functions, and the commands
  print exactly what they did. The index is now written whole and swapped
  in, so a reader never sees half of it.
- **Fixed:** `chatqlog` on a job still running failed with "being used by
  another process" - the run holds its log open. `chatqrm -Force` on a job
  that ended meanwhile, with no watcher left, marked it failed and lost its
  result; it now says it had already ended.
- **No Reload to click on coming back.** A chat open in a VS Code window never
  shows a chatq run until that window reloads, and until now the window only
  ever asked. It reloads by itself now when, as the run ended, nobody had used
  the PC for `quietMinutes` (5 — the same clock that sends the alert to the
  phone) and no other chat in the folder was working or had been written in
  that time. It still asks at the PC (you may be typing in that very window),
  on an idle clock that cannot be read or `quietMinutes` 0, and in a window
  with more than one folder or opened on a parent one, since only the chat's
  own folder was judged. A window opened after the run already shows it, so
  it neither asks nor reloads - nor for a new chat a run started, which it
  lists already. A new chat is never reloaded for by itself.
- **The chat the run just wrote no longer counts as busy** for having just
  been written. What Claude says of its own open process still counts: after
  the run that can only be a window's, and it may be mid-answer.
- The busy check asks the job's own Claude home (`CLAUDE_CONFIG_DIR`) for its
  open sessions, not the watcher's.
- **A refused login says what Claude said.** Every 401 and 403 read as
  `Claude is logged out · run claude, then /login`, and nothing kept what
  Claude had actually said. A subscription that has run out is refused the
  same way, so on 2026-09-23 a lapsed plan was reported as a lost login, and
  afterwards there was no telling which it had been. The alert now quotes the
  API's own message — `Claude login refused: OAuth token has expired. (401) ·
  run claude, then /login, or check the subscription` — and so do
  `data/logs/watcher.log`, the `chatqlist` status line, the console's line
  before Send (which had called it "limited until") and the job's result.
  Codex the same, with `codex login`.
- **The watcher log keeps the whole error too**, on an `error text:` line of
  its own, type and all — the message alone does not say what kind of refusal
  it was.
- **The extension** has words for a new chat, and reloads by itself after a
  queued run as above; `chatManagerReload.autoReloadAfterRun: false` makes it
  always ask. Copy its files over the installed ones to update it (see the
  README for the update line).

## 0.4.0 — every running chat at a glance

- **`chatoverlay`** keeps a small panel in the top-right corner, above other
  windows. It shows every open Claude chat: its project, title, newest prompt,
  and a dot for what it is doing. Amber is waiting on you and goes to the top,
  green is working, grey is idle. A chat open in two windows is one row.
  Queued prompts appear on their chat's row, or as a purple row of their own
  when that chat is not open.
- **A slash command is the newest thing sent.** Claude Code does not count one
  as a prompt: after `/compact` its own record of the last prompt still names
  the one before. So the overlay reads the command from the transcript. While
  `/compact` runs nothing on disk names it yet, and the row says a command is
  running instead of showing the older prompt as current.
- **Usage at the top, live.** A line each for Claude, Codex and Copilot, as
  the collapsed panel has it, ending with when that figure is from - or, from
  the settings box or `-UsageView bars`, a bar in the server's own colour and
  a reset countdown per window. Claude's five-hour and weekly windows, and one
  model's weekly window once used; Codex's; Copilot's monthly quotas. Claude
  Code caches its figure only when a window opens its usage view, and here
  that copy read 55% while the account stood at 79%. So the overlay asks
  Claude's usage endpoint itself: every five minutes while a chat works, every
  fifteen while all are idle, as a window resets, and on the refresh button.
  It uses the login Claude Code saved, reads the token for that one request,
  and never stores, logs or refreshes it. An expired login or a refusal falls
  back to the cached figure, marked with its age. `-LiveUsage off` keeps to
  the cache.
- **Copilot's quota through the GitHub CLI.** VS Code keeps only the plan on
  disk, so the overlay runs `gh api copilot_internal/user` - what VS Code's
  Copilot status reads - every fifteen minutes and on refresh. `gh` keeps its
  own login and hands the overlay no token. No `gh`, or one not logged in,
  means no Copilot line; `-CopilotUsage off` stops asking.
- **It keeps to the endpoint's own wait.** Asked once a minute, the endpoint
  refused after about an hour and said to wait 48 minutes. So the overlay now
  asks every five, and when refused it waits as long as `Retry-After` says,
  showing `retry 11:22`. The refresh button does not ask inside
  that wait. The last live figure and the wait survive a restart.
- **Out of the way.** It never takes focus and clicks go through it. The tray
  dot, in the most urgent chat's colour, shows and hides it and has a menu.
  **Ctrl+Alt+Shift+O** unlocks it for dragging (`-Hotkey` changes the key),
  and it locks itself two minutes after the pointer leaves.
- **Buttons on its top edge when you point at it,** outside the panel and
  flush with its top-right corner: a grip to drag it by, collapse to one line
  (counts and usage), refresh usage, a settings box, hide to the tray, and
  close. Refresh turns while it asks and then says when Claude answered;
  Codex's figure is never asked for - it moves when Codex runs - and says it
  is from Codex's last run, with its date once over a week old. The settings
  box has an opacity slider, the theme (Dark, Light, or System to follow
  Windows' light or dark mode), and usage as lines or bars. The buttons are a
  small window of their own, so the panel never takes a click. The choices
  are kept in `config.json`; `chatoverlay -Theme`, `-Opacity`, `-UsageView`,
  `-Collapse` and `-Refresh` do the same from a shell.
- **Cheap.** One hidden Windows PowerShell, about 160 MB and under 0.1% CPU on
  this machine with ten chats open. It re-reads a file only once it changed,
  and a transcript only from where it stopped: the first look at a 20 MB chat
  reads its last 256 KB, where Claude Code writes each turn's prompt and title.
- **`chatoverlay -AutoStart on`** brings it back with every new shell, as the
  watcher comes back. Nothing is registered with the OS. `chatinstall` restarts a
  running overlay on the new copy, and `chatuninstall` stops it.
- **`chatoverlay -Print`** draws the same in the console. That is Linux's only
  view.
- **macOS, untested:** a floating panel and a `CQ` menu bar item, drawn by
  JavaScript for Automation, so nothing needs installing. Live usage is off
  there by default, since reading the login from the keychain asks for a
  password.
- **The watcher reads the same session list.** When `claude agents` cannot
  run, its fallback now reads `~/.claude/sessions/` the overlay's way. It also
  keeps what a chat is waiting for. A macOS-style `procStart` no longer rejects
  every session as a reused pid.

## 0.3.1 — no "safe to reload" while another chat is working

- **A chat running a workflow or a background agent is no longer called
  idle.** The turn that starts one ends at once, and the work writes only to
  its own files, so a minute later the check read the chat as finished. The
  terminal then said `safe to reload now`, and a reload would have killed the
  work. Now the transcript is searched for a start with no
  `<task-notification>` after it. Only starts since the chat's process began
  count: anything older died with an earlier process.
- **Claude's own word comes first.** A chat that `claude agents` lists as
  `busy` or `waiting` is active, whatever its transcript looks like.
- **The window's Reload offer says so too.** The request left for the
  extension now carries `busy`. While a chat works, the window warns — *A chat
  in this workspace is still working, and reloading now would cut it off* —
  with **Reload anyway**, and `autoReload` does not fire. Before, the button
  appeared the same either way, and the warning was only in the terminal. Copy
  `extension/` again to get this (see the README for the update line).

## 0.3.0 — files and screenshots with a queued prompt

- **`chatq <title> -Attach a.png, spec.pdf`** sends files with the prompt —
  images, text, code, PDF, as many as you like, a wildcard too
  (`.\shots\*.png`). They are copied into the job, `data/queue/<id>/`, before
  the prompt is written, so the originals can move or change in the hours
  before it sends. A file missing, or one that cannot be copied, queues
  nothing; the same file twice goes once.
- **`chatq <title> -Paste`** takes the clipboard as it is now: a screenshot, files
  copied in Explorer, or text — which becomes the prompt, or goes under the one
  given, quotes and all, and helps pick the chat as a typed prompt does.
  Windows only.
- **Ctrl+V in the editor tab.** VS Code saves a pasted image beside the prompt
  file, in `data/queue/`, and links it; chatq moves it into the job and points
  the link there. Checked again just before the job sends, so an image pasted
  into a prompt reopened with `chatq <n>` counts too. A link to any file
  outside `data/queue/` is left exactly as written and never opened by chatq:
  it names a file where it is, for the chat to open or change there — a copy
  would have it edit a snapshot, `../config.json` would reach chatq's own data,
  and a `\\host` path would open a connection to that host.
- **`chatq <n> -Attach` / `-Paste`** adds files to a job while it waits.
- **How each chat gets them.** Claude gets every path under the prompt,
  `Attached files - read each one:`, and opens them with its own Read tool — it
  sees an image as a picture and reads PDF — with `--add-dir` for the job's
  folder. Codex gets images properly, one `-i` each and a `--` so the thread id
  is never read as another image, and the other files under the prompt. A
  "continue" sends no files; they went with the prompt.
- `chatqlist` counts a job's files (`+2 files`), `chatq <n>` names them,
  `chatqrm` removes them with the job, and more than 10 files or 20 MB draws a
  warning.

## 0.2.1 — what a first day of real use turned up

- **A prompt typed after the title is caught.** `chatq <title> <some words>`
  reads every word as the title — that is what lets a title be typed without
  quotes — so the words meant for the chat went looking for one instead, and
  the pick was a guess. When the pick is a guess and what was typed reads like
  a prompt (six words or more, or a path or URL in it), `chatq` now says so and
  shows the `-Prompt` form.
- **The cut-off list names the chat.** It fell back to the transcript's uuid
  when the index had no row for that chat yet — which is exactly the state a
  chat the limit has just stopped is in. The title is read from the transcript
  instead, so it can go straight into the `-Continue` line printed under it.
- **The usage line no longer contradicts the status line above it.**
  `Claude 5h 0%` sat next to `Claude limited until 11:50`, because both
  providers' figures come from caches that refresh only when that tool itself
  runs. The window that is blocked now reads `limited` — `5h limited` for the
  five-hour one, `week limited` for a weekly one, a 529 neither — and a figure
  an hour old or more is marked `stale`.
- **`data/logs/jobs.log`** keeps a line per job event — queued, every state it
  moves through, and removals. A job's own history goes with its file, so until
  now a `chatqrm` left no trace at all, and where a job went could only be
  guessed from the watcher logging an empty queue.
- **`chatqnotify -ApiKey` takes the whole Join push URL**, quoted, and reads the
  key and device out of it. Unquoted it never arrives — PowerShell stops at the
  first `&` — so the help now says to paste the key alone.
- `chatq`'s cheat sheet said phone alerts went through Join. They also go to a
  desktop toast and to ntfy.

## 0.2.0 — chatrm and chatq in one tool: VS-code-chat-manager

The repo was chatq; it is now VS-code-chat-manager, and chatrm 1.3.0 is inside
it. The chatrm repo stays as it was.

- **One file, one index, one install.** chatrm's proven code is the base and the
  queue sits on top of it; chatq's copy of chatrm's index, readers, providers
  and scoping is gone.
  - Every command keeps its name. `chatqinstall` and `chatquninstall` fold into
    `chatinstall` and `chatuninstall`.
  - `chatinstall` replaces a profile line for chatrm or chatq with its own,
    since they define the same commands.
- **One Tab for all three.** The completer serves `chatrm`, `chatfind` and
  `chatq`, and `chatq` gets chatrm's one-line Tab cycling, so a multi-word title
  needs no opening quote any more. Subagent chats are no longer offered (the
  search skipped them, so Tab offered what it then could not find), `chatq` is
  never offered a Copilot chat, and a title that happens to be hex (`add…`,
  `cafe…`) completes instead of nothing.
- **Fixes carried from chatq into the chatrm half:** a Hangul Codex thread name
  is read as UTF-8; a Claude title with a quote in it comes back unescaped; a
  zero-width cell no longer throws; typographic apostrophes are quoted safely;
  the whole file is StrictMode-safe at load and in every key handler.
- **The two halves know each other.**
  - `chatrm` keeps a chat that has a prompt queued for it, and names the job;
    `-DropJobs` drops the jobs first, waiting out a running one.
  - A queued run into a chat still open in a window asks that window to reload,
    through the extension.
  - A Copilot title given to `chatq` is refused with the reason, never quietly
    swapped for another chat.
- **The extension** is now `phal40lax78.chat-manager-reload` 2.0.0, with
  `chatManagerReload.*` settings. It watches the new folder and the old chatrm
  one, says what happened (deleted, archived, a queued run), and never reloads
  unasked after a queued run.
- **Delete takes every leftover:** besides the sidecar folder, `file-history`
  and `session-env`, now `tasks`, `debug`, security state, telemetry, todos, a
  background job's folder, and the plan file when no other chat in the project
  shares its slug — after
  [claude-chats-delete](https://github.com/ataleckij/claude-chats-delete)'s
  inventory. They go only once the transcript is gone, so a chat a live window
  holds open keeps them.
- **Archive and restore.** `chatrm … -Archive` moves a Claude chat and its
  leftovers into `data/archive/`, or archives a Codex thread through
  `codex archive`; `chatrestore` lists and brings them back. `chatuninstall
  -All` will not delete an archive that is the only copy.
- **Retries that know when to stop.**
  - A dropped connection is retried after 1, 2 and 5 minutes. The count lives in
    the job, and chatq's own 4-hour cap is never mistaken for one.
  - An expired login holds that account's jobs, with one alert.
  - A job that breaks before any reply `maxRetries` (5) times in a row gives up;
    one that makes progress each time never does.
  - An overload past 6 hours sends one reminder.
- **More ways to hear about it:** a desktop toast (on by default), ntfy as JSON
  so Hangul survives, and a command of your own with the alert in its
  environment. The phone stays quiet while you are at the PC.
- **`chatq -Model`** runs one job on another model, and its probe asks with that
  model. **`-First`** (and `chatqrun <n> -First`) puts a job at the front, in one
  queue order the watcher, the list and the board all share.
- **Usage in `chatqlist`**: how much of Claude's and Codex's windows are used,
  from their own caches, with how old the figure is.
- **The watcher picks up an update:** `chatinstall` asks a running one to hand
  over after its current job. The successor carries on with what it knew —
  limits, overloads, alerts already sent.
- **The repo:** README badges, demo frames made by `docs/make-demo.ps1` from the
  real commands, a comparison with similar tools, CI on Windows PowerShell 5.1
  and PowerShell 7, a v0.2.0 release, and a mock sponsor badge until one is set
  up.

## 0.1.0 — first release

- **Queue a prompt for an existing chat** while the usage limit is hit:
  `chatq <title> -Prompt …`, or with no `-Prompt` in an editor tab named after
  the chat. `-Continue` queues a "continue" for a chat the limit cut off.
- **The chat is picked when you queue, and the pick is printed.** The order is
  id, then exact title, contains and every word. It searches this project
  before any other. When nothing matches, the guess comes from this project's
  chats. The newest candidate wins unless others were active within 5 hours,
  and then relevance decides: a character-bigram cosine that works for Hangul
  and English alike, with no model call.
- **A background watcher sends at the reset.**
  - It reads the reset time from Claude's own limit record in the transcript,
    or from Codex's rate-limit snapshot.
  - It confirms with a throwaway probe that saves nothing.
  - It then resumes each chat in its own folder and in the permission mode it
    last used, one job at a time.
  - Anything that would ask a question is denied, and the job is parked as
    needs-input.
  - A limit hit again mid-run requeues the job, as "continue" if the prompt had
    already landed.
- **Status.**
  - `chatqlist` shows one line per job, with long prompts summarised.
  - `chatq <n>` opens a prompt, and edits count until it is sent.
  - `chatqlist -Board` is a live markdown board for VS Code's preview.
  - `chatqlog <n>` shows what a run did.
- **`API Error: 529 Overloaded`** (and any other 5xx) is no longer a failure.
  - The job is requeued, as "continue" if the prompt had landed.
  - chatq watches `status.claude.com`'s JSON every minute and resumes as soon as
    the Claude Code component is operational.
  - An overload the page never shows is retried after 1, 2, 5 and 10 minutes,
    then every 15.
  - Chats you left stopped on a 529 are listed next to the limit-cut ones, for
    `-Continue`.
- **Phone alerts through Join** for started, needs input, done, failed,
  limited and overloaded. The key is DPAPI-protected on Windows. Titles start
  `chatq ·`, for Tasker filters.
- **Chats still open in a VS Code window.** A busy chat waits. An idle one runs
  with a "reload the window" note, or with `liveIdle: stop` its idle process is
  ended first.
- **Built for unattended runs.**
  - The machine is kept awake while a job is due within 6 h.
  - The watcher is restarted from the profile after a reboot.
  - API keys and the parent chat's session variables are kept out of runs.
  - Prompts go to the CLI as raw UTF-8, so Hangul survives Windows PowerShell
    5.1.
- **Limits are tracked per account and per model.**
  - A job queued under `CLAUDE_CONFIG_DIR` / `CODEX_HOME` keeps that account.
    Otherwise it runs in the default account, never the watcher's inherited one.
  - An Opus-only weekly limit holds up no other model.
  - A limit record older than an "allowed" probe no longer blocks the queue
    again.
- **Guesses stay inside a project.** From a folder that is no project, a title
  that matches nothing is refused, unless `-AllProjects` is given.
- **Works under a caller's `Set-StrictMode -Version Latest`.** On pwsh 7,
  timestamps read back from job files keep their time zone.
- One file, PowerShell 5.1 and 7, everything under `data/` beside the script.
  One-line install.
