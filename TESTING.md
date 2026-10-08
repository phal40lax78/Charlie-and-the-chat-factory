# Testing Charlie-and-the-chat-factory

Every check here is in one of three tiers, by what it needs:

- **[Tier 0](#tier-0-anywhere-any-time)** runs anywhere, any time: the
  self-test under Windows PowerShell 5.1 and PowerShell 7, the node checks,
  CI and the demo frames - made-up chats in a sandbox, fake CLIs, no network
  and no model.
- **[Tier 1](#tier-1-this-pc-for-real)** runs on this PC for real: real VS
  Code windows, the live overlay, the real `claude` and `codex` spending real
  turns. Ask first.
- **[Tier 2](#tier-2-other-hardware)** needs other hardware: a real phone, a
  Mac, Linux. Ask first.

A by-hand item sits in the tier most of its steps need; a step that needs a
phone or a Mac says so. [Review](#review), at the end, is the record of each
review.

## Tier 0: anywhere, any time

### The self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File tests/run-tests.ps1                                  # PowerShell 7
node tests/extension-check.js                                              # the VS Code extension
node tests/overlay-mac-check.js                                            # the overlay's macOS panel (JXA)
```

The exit code is the number of failed checks, and `-Keep` leaves the sandbox
behind for poking at. It uses no Pester, no network and no model.

In VS Code the same runs are tasks in `.vscode/tasks.json`, each a status
bar button through the actboy168.tasks extension: **Quick checks** (the
ASCII rule and the four node checks), **Self-test** (5.1), **Package** (as
CI packs it) and **CI**, the three in a row as `test.yml`'s Windows
PowerShell leg runs them. **Self-test (7)** is its pwsh leg, which runs
the self-test alone: under `data/pwsh/pwsh.exe`, where a portable
PowerShell 7 is unpacked - the win-x64 zip of a PowerShell/PowerShell
release on GitHub, its SHA256 checked against the release's
`hashes.sha256` - else under `pwsh` from the PATH. Its first run here, on
2026-10-07 under 7.6.6, passed all 1650 checks, the handover's sections
among them, which only CI had run under 7 before. 5.1 runs one fewer: its
permit section takes the bridge's pwsh leg from a `pwsh` on the PATH alone.

- **Fake CLIs.** Every `claude`/`codex` call goes to `tests/fake-agent.ps1`
  through `tests/fake-claude.cmd`. `CHATQ_CLAUDE` and `CHATQ_CODEX` point there,
  and `FAKE_*` variables choose what it does: a stream to replay, a transcript to
  land the prompt in, a new chat's transcript written where Claude Code would
  write it for `--session-id` (`FAKE_NEW_CHAT`), live chats for `claude
  agents`, `codex archive` and `unarchive`, and `codex app-server` answering
  by method from `FAKE_APPSERVER` (`tests/fixtures/appserver/`: `<method>.json`
  is the reply less its id, `/` written `_`; `<method>.before.jsonl` goes out
  ahead of it; `FAKE_APPSERVER_NOMETHOD` refuses a method as an older codex
  does). The `.cmd` hands its arguments over as one string, because
  `powershell -File` refuses a bare `-` (Codex's read-stdin marker).
- **A generated sandbox.** Claude, Codex and Copilot chats are written into fake
  homes under `tests/.sandbox/` with timestamps relative to now, so nothing goes
  stale. `CHAT_CODE_USER` points the Copilot provider there too — otherwise an
  index sync would read this machine's real Copilot chats.
- **A private copy.** The script and its `src/` are dot-sourced from a copy
  in the sandbox, so the run gets its own `data/`. `CHATQ_ALLPARTS`, set for
  the run and every child it starts, loads all 25 parts - the overlay's
  three among them, which a shell's load leaves out.
- **Never in a git worktree of this repo.** VS Code's git extension opens
  every worktree of an open repository as one of its own
  (`git.detectWorktrees`, on by default), wherever it lies, and watches it.
  A run's churn there, and the bulk delete of `tests/.sandbox` as it ends,
  crashed VS Code's file watcher (0xC0000409) twice a run. On 2026-09-27,
  after the sixth crash, VS Code stopped restarting it, and the Git view and
  Explorer stayed frozen until a window reload. The same runs in the
  workspace itself crashed nothing. For a baseline against another commit,
  `git clone` the repo into a scratch folder, or run a plain copy with no
  `.git`.
- **One scope, many files.** `run-tests.ps1` holds `Check`, `Section` and
  the summary; the sandbox and every section are files in `tests/sections/`,
  dot-sourced in the order its list gives, as the one file had them. A
  section uses what the sandbox and the sections before it set, so none
  runs on its own. A new section goes in that list. Windows PowerShell 5.1
  holds a scope to 4,096 variables, a number the suite passed on
  2026-10-06; `run-tests.ps1` raises it to 32,768, the most 5.1 takes.
- **Seams, so nothing real leaves the sandbox:** no desktop toast
  (`ChatqToastSeam`), no push service (`ChatqNtfySeam`), no idle clock
  (`ChatqIdleSeam`, as if nobody were at the PC), no alert footer read
  from this PC's usage and chats (`ChatqFooterSeam`), no real background watcher
  (`ChatqSpawn`), no ghost-watch events (`ChatNoGhostWatch`). For the overlay:
  no real overlay process (`ChatOverlaySpawn`), no usage endpoint
  (`ChatOverlayUsageSeam`), no GitHub CLI - `CHATQ_GH` names one that does
  not exist, for the child processes too, since `gh`'s login is the
  machine's and no sandbox reaches it; `ChatOverlayCopilotSeam` stands in for
  its answer - no real Windows light/dark setting
  (`ChatOverlaySystemDarkSeam`), a screen of the test's own off every real one
  for the panel's buttons (`ChatOverlayWorkAreaSeam`), no mouse button held
  and the pointer far off for the pointer check, whatever the real mouse's
  (`ChatOverlayMouseDownSeam`, `ChatOverlayPointerSeam`), no real clipboard for
  the console's paste (`ChatConsoleClipboardSeam`), no index sync in a
  child process from it (`ChatConsoleNoSync`), nothing brought forward as
  the console opens (`ChatConsoleFrontSeam`, standing in for
  `Window.Activate`, so a test never takes the keyboard), a console in
  front without it being so (`ChatConsoleActiveSeam`, standing in for
  `Window.IsActive`, which a window never activated never is), and no real process
  list behind the session
  registry (`ChatqAliveSeam`) - except in the checks against a real `node`
  process, which run only where node is installed.
- **Nothing ended, nothing raised.** Showing a chat fresh ends a process and
  starts `code`, so the run sets the seams for both before any section:
  `ChatStopSeam` answers `gone` and no test can reach `taskkill`,
  `ChatParentSeam` makes every chat process a `Code.exe`'s child (pid 4242),
  and `ChatCodeSeam` answers ok. A section that needs other answers sets them
  and puts them back. `ChatWindowTitlesSeam` stands in for VS Code's window
  titles, and `ChatShowSpawnSeam` takes the command the overlay's chip would
  start. `FAKE_AGENTS_SEEN` tells whether `claude agents` ran.
  `ChatHandoverOff` keeps the handover out of every section but its own,
  where the waits for a window's answer and for its process to leave are
  cut to a second each.
- **Synthetic streams only** in `tests/fixtures/stream/`. The repo is public, so
  no real transcript goes in it.
- **Slow machines.** A check waits on what it checks, under a cap a slow
  machine only waits longer for, never a fixed time; timers that race get
  room between them; a clock the code reads is held through a seam; and a
  bound on how long something took sits between the right speed and the
  wrong one, the slowest machine still on the right side. A node check's
  slow machine is a preload, `node -r <file>`, whose 10 ms interval
  busy-waits a random 0 to N ms, so the event loop runs late as a starved
  CPU makes it. On 2026-10-07 at N = 30, 60 and 100, `extension-check.js`
  and `board-page-check.js` as they stood failed at 60 and 100 - the carry
  checks and the board's refresh - and after the fixes passed at all three.
  A 5.1 run pinned to two cores beside two busy loops took 4036 s, against
  about 963 s; its two failures came at 97-99% of commit, below.
- **Short of memory, children fail - not flakes.** With commit (RAM plus
  page file, Task Manager's *Committed*) near its limit, Windows refuses new
  processes and threads: a child exits 0xC0000142, or 0x800705AF (the
  paging file too small); a thread fails to start; an
  `OutOfMemoryException`; a node `spawn` refused; or the run stops with no
  summary. Look at commit before reading a FAIL as a timing flake. On
  2026-10-07, at 97-99%, the pinned run's overlay close stalled 24 s, its
  15 s guard timer as late, and a `claude agents` child came back with
  nothing; another run died with no summary. A full 5.1 run takes some
  4 points of that machine's 31.6 GB at its peak, about 1.3 GB: start one
  under 90%.

What it covers (at 0.10.5 and 0.10.6, 1658 checks in `run-tests.ps1` under 5.1 and
1659 under pwsh 7, 458 in `extension-check.js`, 258 in
`reply-page-check.js`, 138 in `board-page-check.js` and 36 in
`overlay-mac-check.js`; at 0.10.4 it was 1581 under 5.1 - under pwsh 7 in
CI alone, since the machine it was written on had none then - 451, 258,
138 and 36; at 0.10.3, 1329, 397, 258, 134 and 36; at 0.10.2,
1291, 387, 258, 133 and 36; at 0.10.1,
1287, 371, 258, 133 and 36; at 0.10.0, 1279, 371, 258, 133 and 36; at 0.9.0, 1032 under 5.1 and 1033 under
pwsh 7, 279, 250, 78 and 35):

| area | checks |
|---|---|
| relevance | bigram cosine: identical = 1, disjoint = 0, Hangul overlap > 0 |
| resolver | exact, contains, every-word; Hangul exact and NFD-typed Hangul; the prompt breaking a tie between look-alike titles; no match stays in this project and never reaches the nested `…-Mobile` slug; a title only found in another project; hex id; a title past the 60-char clip; the 5 h edge at 4h59 (relevance) and 5h03 (newest); Codex thread names; a Copilot title named and refused, never guessed; a sentence typed where a title goes points at `-Prompt`, and a real title never does; two Codex rollouts in sibling folders that share a leaf name (`sibA\app`, `sibB\app`, one with a lower-case drive) - each in scope only from its own folder however the folder is written, and from a share whose path carries `Microsoft.PowerShell.Core\FileSystem::` ([Get-ChatProjectScope](src/chatrm.ps1)), a row with no `Cwd` falling back to the leaf, an old row of a repo named `codex` read again while only one marked `NoCwd` is kept, an index CSV with no `Cwd` column reading under StrictMode, and a real-index codex row blanked to look old getting its folder back on the next sync ([Test-ChatInProject](src/chatrm.ps1), [Test-ChatIndexRowCurrent](src/core.ps1)) |
| metadata | cwd, last permission mode even 1.3 MB from the end, last real model, cut-off detection with its reset time, Codex cwd/sandbox; the last turn read back from the end, 64 KB where it is near and 256 KB where it is further back, a turn longer than the first read read whole, one naming no folder given the last record's that does from 150 KB back, and found with no newline after it, CRLFs, a half-written line after it or a BOM before it - the reads taken down as they go ([Get-ChatqLastTurn](src/queue.ps1)); a Codex chat's effort from `turn_context.effort` and, failing that, its collaboration mode's `reasoning_effort` ([Get-ChatqCodexMeta](src/queue.ps1)); a `managed` and a camelCase `workspaceWrite` sandbox made words codex takes by [Get-ChatqJobInfo](src/commands.ps1), the unknown word kept to say; [ConvertTo-ChatqCodexSandbox](src/queue.ps1) over every shape and [Get-ChatqCodexRunSandbox](src/queue.ps1) taking the job's own pick before the chat's; [Format-ChatqRunCarry](src/queue.ps1) saying a Codex job's model and effort, and nothing under `-Model` |
| limits | future reset found, past one ignored; Codex full window; Codex "try again at …" prose; a cut-off chat the index has no row for yet is still listed by its title, not its uuid |
| classifier | denied → needs-input; rejected event / legacy `…\|epoch` / weekly text → limited; 529 → overloaded; a connection error → network; an expired login (401) and a plan refused (403) → auth, each reason in the API's own message — read out of the error JSON, escapes and all, else the text on one line from the refusal on, cut at 160 characters, and never from the chat's own reply; a Codex refusal the same, its `unexpected status 401` code kept; Codex "stream disconnected" → network; chatq's own time limit never counts as network; a rejected event before a successful turn → done; plan and max-turns → needs-input; error and missing result → failed; a trailing question → done with `asks` |
| overload | a 529-stopped chat recognised and listed; the status page read from a fake `status.json`; the backoff; page polled every minute; operational → probe at once; page silent 15 min → probe anyway; one alert; a reminder past 6 h; a Codex lane's outage: its first try a minute out, due once that passed, the next two minutes out, and the status page never read (a stubbed `Get-ChatqClaudeStatus` counts reads); its alert and 6 h reminder say Codex and never Claude or status.claude.com; `Get-ChatqEta` says "when Codex is back" and the console's preview names Codex's tries, Claude's still its page; a good Codex probe (`codex-done.jsonl`) ends the outage |
| retries | a network drop requeued a minute out, its landed prompt as a continue that is always sent, gone after three retries; the no-reply cap counting only runs that got no reply, and starting over after one that did; a refused login holds the lane with one alert, which quotes the API, as do the watcher log (the error text whole, its type too, on a line of its own) and the status line — whether the probe met it or a run did; a block an older watcher saved, its source still `probe`, reads right; Codex overloads in codex-cli 0.159.2's words (`codex-overload.jsonl` "high demand", `codex-capacity.jsonl` "at capacity", `codex-5xx.jsonl` "last status: 503") → overloaded with the turn's own words, a 400 (`codex-badrequest.jsonl`) → failed, a context-window failure with an MCP probe's "unexpected status: 500" and `server_error` in stderr → failed, stderr alone with no `turn.failed` read, a refused login on stderr still auth over a 5xx, the usage limit still limited, chatq's own stop still failed; end to end, a Codex run through the fake on `codex-overload.jsonl` is queued again behind its lane's outage a minute out, no status page read, its history and alert saying "waiting for Codex to be back" / "resumes when Codex is back" and never Claude |
| model and order | `-Model` kept apart from the chat's own model, used by the probe and the run (`--model`, and Codex's `-m` before the thread id); `-First` ahead of older jobs, in the list's "sends" too; `chatqrun <n> -First`; the jobs one reset frees go one at a time in "sends" - the first at its time, the rest, a Codex job at that minute too, each `after #n`, a wait's reason kept - and a free job never after a waiting one; Continue saying it queued them to go one at a time; a Codex job's sandbox: `chatq -Sandbox read-only` sends `sandbox_mode=read-only` and no network flag and the pick says `read-only (given)` and the model `as the chat last ran`, a chat saved as `managed` runs `workspace-write` with its network and a history line, `chatqrun -Sandbox danger-full-access` requeues with the wider-sandbox warning, and `-Mode` on a Codex chat, `-Sandbox` on a Claude one and [Reset-ChatqJob](src/commands.ps1) with a Claude mode for a Codex job are refused with nothing queued ([Get-ChatqModeRefusal](src/commands.ps1), `New-ChatqJob`'s code `mode`); [Set-ChatqJobRunAs](src/commands.ps1) on a Codex job takes a sandbox word and a model and refuses a Claude mode; the Codex probe ([Invoke-ChatqProbe](src/queue.ps1)) at `-c model_reasoning_effort=low`, with `-m` the job's `-Model`, kept when that probe fails, else the chat's own model, dropped when that one fails (`codex-done.jsonl` for the answer that passes; the fake's default, Claude-shaped, for the one that fails) |
| which CLI | `tests/sections/model-order.ps1`, a sandbox PATH cut to Windows' own folders and an extension home of its own ([Find-ChatqBundledExe](src/queue.ps1) through `$script:ChatqExtHomeSeam`): a `codex.cmd` on PATH, the fake saying `codex-cli 0.150.0` through `FAKE_VERSION`, picked as `PATH` with that version read by [Get-ChatqCliVersion](src/queue.ps1), and warned about beside the extension's 0.159.2 (put in the version cache, the binary an empty file) - by [Get-ChatqCliReport](src/queue.ps1), `chatinstall`'s lines ([Write-ChatCliReport](src/discoverability.ps1)) and `chatproviders`; one as new or newer not warned about; none on PATH → the extension's copy, compared with nothing; `CHATQ_CODEX` said as the override, never compared however old; `$script:ChatqCodexAppServerMin` parses and orders 0.150.0 below and 0.159.2 above it; a `claude.exe` on PATH that is Claude Code's own install ([Get-ChatqExePick](src/queue.ps1)) said as that and never compared with a newer extension copy, since off PATH it would be picked all the same. The version cache is put back whole after, so no Claude run later meets a codex version cached for the same fake |
| watcher | one full loop runs the queue and exits, sweeping `data/queue/` of a day-old file no prompt links to as it starts - once, said in `watcher.log`; a second watcher will not start; `-Now` reaches a running watcher; a restart request hands over — lock released, successor started last, state carried — and never in `-Foreground`; a cold start does not carry state; the launch line — no profile, `-ExecutionPolicy Bypass`, and a child handed a `Restricted` process policy loads the script and runs the loop with the policy gone and `CHATQ_WATCHER` set; a load that fails logged in `watcher.log`, exit 1; started for real from a folder named `wd[1]`, it runs in your home folder, not that one ([Start-ChatqWatcherProcess](src/watcher.ps1)); a Remove during the watcher's checks - fired inside its look at the live sessions - stays a removal for a busy chat (deferred), an idle one and one not open (about to run), and a continue sent now: nothing written back (it had come back queued, or failed, and a continue was sent after it was removed); `Save-ChatqJob -Existing` makes no file for a job removed, and leaves no `.json.tmp` |
| alerts | the toast at the PC and the phone quiet; `-Test` gets through anyway; ntfy's JSON with Hangul, the title's middle dot and priority 5; the ntfy topic never printed whole; the command hook's environment, `&` and `%PATH%` left as text; a hanging hook stopped; a pasted Join push URL gives up its key and device; `-Off`; the idle clock reads without an error; away only when known — not at the PC, not with `quietMinutes` 0, not on a clock that cannot be read |
| usage | Claude's from its cache with its age, and a reset a moment either side of the minute read as that minute - `12:59:59.855638` and `17:00:00.462` as 13:00 and 17:00, `12:59:29.999` as 12:59 ([ConvertTo-ChatqResetDate](src/queue.ps1)); Codex's from the newest rollout that has any, and the `chatqlist` line; Codex's one snapshot reader ([Read-ChatqCodexLimitSnapshot](src/queue.ps1)) reads spaced JSON as it reads compact - window, plan and record time - and takes the newest snapshot with a window, past a half-written last line, a snapshot with no window and a mention quoted inside a reply; [Get-ChatqCodexBlock](src/queue.ps1), [Read-ChatqCodexUsage](src/overlay-data.ps1) and [Get-ChatqUsage](src/alerts.ps1) read the same spaced snapshot from an older rollout when the newest one has none; a newer rollout whose only snapshot has no window lifts that block while the usage readers still show the older figure; a five-hour limit reads `5h limited` rather than the percent cached before it, a weekly one leaves the 5 h figure alone, and a figure an hour old is marked `stale`; one Codex home - `Get-ChatqUsage -CodexHome` reads the home given, and with `CODEX_HOME` changed after load the default still reads the one chatq loaded with, as `New-ChatOverlayContext -CodexHome` reads its own; Codex's live answer from `overlay.json` over an older rollout - a full window with its reset, one reset since at 0% - only when the home it names is the reader's, however it is written: never for `-CodexHome` elsewhere, never one asked under another home and read by a caller that names none, nor one that names no home; and the rollout's over an older answer |
| attachments | a missing file queues nothing; `-Continue` with files refused; `-WhatIf` names them and copies none; copies in the order given, a space out of a name, the original changing later changes nothing; `chatqlist` counts them; Claude gets every path under the prompt and `--add-dir` for the job's folder; Codex gets `-i` per image and `--` before the thread id, the rest in the prompt and the image only said to be there; the same file twice goes once; a wildcard brings every match; a file locked after its check queues nothing and leaves no folder; `chatq <n> -Attach` adds to a queued job, not to one already sent, and `-Paste` of text there adds nothing; `-Paste` through a seam — a screenshot as `clip.png` without the caption that came with it, Explorer files but not folders, text as the prompt or under one, an empty clipboard refused; a pasted image beside the prompt moved in and its link rewritten; a file linked twice one copy, a look-alike name its own link; a link to a file elsewhere, `../` into chatq's data and a `\\share` all left as written and untaken; a name with parentheses and a folder named after the prompt taken, the emptied folder removed; `chatqrm` removes the job's folder; `chatq -New` - a named new chat's job in that folder with its file, mode, time and place, and the id to reach it by said; a folder relative to the shell's and the first line as its name; the editor through a stand-in, its first line naming the chat and its prompt file; `-Paste` text as its prompt; an ESC or BEL in the first line kept out of the name; `-WhatIf`, a missing folder, `-Continue`, Codex, an empty prompt and no folder each refused with why and nothing queued; once run, `chatq <its id's first 8>` picks the chat it made; Tab offers no chat's title as its name; the stray sweep (`Clear-ChatqStrayFiles`) - a file no prompt links to, a day old by the newer of its two times, at the root or in a folder VS Code made, removed, and that folder once empty if it was old before the sweep; a linked file, a young one, one only written long ago, a job's folder even with no `.json`, and the queue's own `.md`, `.cancel` and `.tmp` kept; a prompt held open by another program - nothing removed; a day on the young ones go, and a linked one once its prompt does |
| jobs.log | a job's queueing and its removal by `chatqrm` both land in `data/logs/jobs.log`, which outlives the job file |
| find and delete | the index holds all three providers; a Hangul Codex name read as UTF-8; an escaped Claude title unescaped; `chatfind` by title, by prompt, and `-Deep` for text past the previews; the index saved while a reader holds it for 150 ms, and a warning, not silence, when the hold outlasts the tries; `chatrm -Force` removes the transcript and every leftover (sidecars, file-history, session-env, tasks, debug, security, telemetry, todos, a job folder by the id inside it, plan files) and writes a tombstone; a plan another chat shares is kept; a locked transcript keeps its leftovers; a chat with a queued prompt is kept, and `-DropJobs` drops the job then deletes |
| archive | Claude archive → tombstone and index row gone → restore over the window's stub, leftovers and all, tombstone cleared; never over a chat with messages; not while open in a window; Codex through `codex archive` / `unarchive`; a Codex thread at work is kept ([Get-ChatCodexBusy](src/chatrm.ps1)): a record written just now, or a last `task_started` with no `task_complete` / `turn_aborted` after it in a rollout held open to write (the test holds it as codex does), is busy - a file only touched, every turn ended, a start quoted in a reply's text, an open turn in a rollout no process holds (a killed codex), a turn left open and then a later one finished, an open turn in a rollout untouched past `ChatCodexTurnStaleHours`, and a start further back than the tail read are not; end to end, `chatrm -Archive` on the sandbox thread with either kind of work leaves it in `sessions/`, unarchived, and says why; `chatuninstall -All` refuses while the archive holds one; one Codex home - [Get-ChatCodexHomeOf](src/chatrm.ps1) finds a rollout's home above `sessions/` or `archived_sessions/`, and with `CODEX_HOME` pointed elsewhere an archive and its restore still go to the thread's own home, which the manifest and the row keep, never making the other; a second home's archive listed with `-CodexHome`, and not by default |
| reload safety | in a project of its own: all finished → idle; `busy` or `waiting` from `claude agents` → active though the transcript reads finished; a workflow started and not reported → active, where the transcript alone reads finished; the chat's process gone, or the start older than the process → idle; its `<task-notification>` → idle; a background agent, reported, then woken by SendMessage → active again; a background shell → not counted; the reload request carries `busy` either way; a chat only touched this minute, by a `cost-state` record with no turn and no time in it as a reloading window writes → not active; a chat whose last turn was written this minute → active, unless it is the one a queued run just wrote (`-Except`) — but that chat busy in a window still counts; a neighbour written 3 minutes ago → active over `quietMinutes`, not over one minute; a folder whose only chat is the one the run wrote → idle, not unjudged; a queued run into that chat, open and idle, with nobody at the PC → a `ran` request with `away` true and `busy` false, the one the window may take by itself |
| a reload on the overlay | `tests/sections/reload-ask.ps1`, with `data/reload-pending/` files as the extension writes them, a BOM included, for this test's own pid: one entry a window, its newest ask, how many it has open; a window gone - a pid no process has - its file removed, and one whose pid is alive but started three days after the file says removed as reused; no ask left, or no folder, nothing; `Write-ChatReloadAnswer` - no BOM, the ask's id, the answer and a UTC time `Date.parse` reads; two windows asking at once - this process and another whose start time can be read - an entry each, and the pass takes both; a pass puts it in `header.reload` and a `reload` note (`<window> needs a reload - <why>`), the tray tooltip counts it; answered here → left out, and shown again 30 s on if the window never took it; the chips - **reload**, **reload anyway** where the notice's is, and **later**, no open or delete - and the banner no row count takes for a row; a release on the chip pressed alone answering; the answer from the chip written, the banner gone in the redraw at once, the panel's line saying it |
| background work | `tests/sections/background.ps1`, after reload safety, on a chat of its own: a workflow, an agent and a background shell each start something (`Step-ChatBackgroundLine`), and a shell counts only with `-Shells` - the reload checks leave it out; the ends - a `<task-notification>` and its `queued_command` copy, a `TaskStop` result (none for one that failed), a workflow's run record written since its start (one from before is the run a resumed run keeps the id of), an agent's own transcript ending its turn - never mid tool call, owed a result, mid-stream, refused (Claude Code tries a fallback model), out of tokens, or untouched since the start - its last word read whole past a 100 KB report or 90 KB of record after it, and past keys that differ only in case (Windows PowerShell's JSON refuses those; checked against all 2,626 agent transcripts on the dev machine, none read differently from the whole file); SendMessage waking a reported agent starts it again at the wake's time; `-SkipPrint` and `-Since`; `Get-ChatBackgroundTasks` held by neither a killed workflow nor a finished agent; `Update-ChatBackgroundScan` finding the same, a last line half written waiting with the rest counted read, then read from where it stopped, 300 bytes a call with longer lines taken whole, a shrunk file read afresh; lines longer than its 40 KB piece searched a piece at a time - a word the piece's end cuts in two, the line after one with no word, a word in a long line's first piece - the same in one call, 300 bytes a call, and 1 byte a call, where the piece is held to four times what is kept for a cut word; the overlay - an idle chat with a workflow out a working row, `workflow 7m`, a busy one `working` as ever, a start older than the process none, a fresh cache the same answer; a shell `shell 4m` while `Get-ChatShellChildCount` finds a shell under the chat, none when it finds none, and the transcript's word where it cannot tell; two starts and one shell running - the newest, and its time; a print-mode run's shells counted; the count over all the chat's processes, unknown if any is; on Windows a count from Toolhelp32 in milliseconds; a chat the limit cut off reads cut off, not `shell`; past its slice one transcript a pass, all with `-Whole`; the words for one kind, several, and a mix |
| completion | one completer per command: `chatq 3` completes nothing, `chatq` never offers Copilot, subagent chats only with `-All`, hex completes an id, a hex-looking title still completes, a typographic apostrophe quoted; the cycler skips subagents and, for `chatq`, Copilot; a tail left mid-line comes off a `chatq` line |
| install | one profile line replaces chatrm's and chatq's; uninstall leaves the rest of the profile; `chatinstall` moves a running watcher and overlay to the new copy, and `-NoRestart` leaves them; `Test-ChatProfileLine` counts only a line loading this copy, never an old tool's; the script copied without `src/` names the parts missing and defines no command; a shell's load leaves out the overlay's three parts - every call from the other 22 into them one already looked at, reached only from inside them or from the phone setup's window, never at a top level - and, loaded in a process of its own, has `chatoverlay`, `chatconsole` and the console's folders without them, the same under `CHATQ_OVERLAY` but for stand-ins of the overlay's two hosts, and all 25 under `CHATQ_ALLPARTS`; an older copy's launch - `CHATQ_OVERLAY` alone, the overlay's host or the phone setup's window called by name - started again through this copy's own, why the overlay's could not start thrown for the old launch to log, the phone setup's staying until the window it started holds the lock or a caller's wait is up; the phone setup's window, started for real, with every part and none of `CHATQ_OVERLAY`, `CHATQ_ALLPARTS` or Bypass once loaded; every C# compile in `src/` goes through [Invoke-ChatCompile](src/queue.ps1), its files in a folder of its own in `data/tmp`, gone after, and `TEMP` put back, a failed one's too; a day-old folder there - what a process killed mid-compile left - swept by the next compile, a young one kept; a `data/tmp` csc cannot work in - too long, or a character outside the PC's code page - left alone, and `TEMP` with it |
| extension: the terminal half | `tests/extension-check.js`, `setup.js` and `build.js` with no PowerShell started: the loader's version read, an unreadable one (`0.8.0-rc1`) no version, and compared by number; the decision - nothing there → install, older → update, the same → nothing, newer → left, a loader of no readable version → left and said once, a folder holding other files → nothing written, not even `data/`, a git work tree at the folder or above it → never written, the difference said once per version pair, no payload → nothing; when the profile is looked at at all and when asked (never after Never, after Not now at the next version, always from the palette); the lock - taken, refused, taken over once stale, and a place that cannot be written thrown rather than read as another window; `setUp` in a sandbox folder: installed parts first with no `.new` left, the same again copies nothing, settled it starts no PowerShell, updated, a newer copy left, nothing copied while another window holds the lock, a copy that fails said once a version with no `.new` and no half install; the profile step with PowerShell stood in for: Add runs `chatinstall` where the line was missing and checks again, after an update also where it was, one restart; Add with the line still missing after it → no "Added", the answer not kept, and said; a policy that would stop the line → the question says so and scripts are allowed before the line is written; a policy that will not change → no line, and said; a PowerShell that gives no answer → neither asked about nor installed into; a line already there that never runs → the policy offered once a version; Never kept until the palette asks; setup runs one at a time, a palette run after a start's rather than dropped, and an `onReady` joining a run already going called once that run's loader is ready, or at once where it was; `onReady` called the moment the copy put the loader there, or at once where it was there already, before the profile step - which may never end - and never for a folder it did not install into; the build: the loader's own part list, every part present, the extension's version the script's, an SVG image caught and a link to one not, the listing README free of them; the old extension on the same file → none of it watched here and one window offers it away, another within 10 minutes not, on another file than `chatManager.folder`'s → this one handles its own; without it both files watched in the tool folder, and the overlay's answer to a reload; `chatManager.folder`, `~` in it, a relative one refused for the default, the old `signalFile` taken only as a `data/reload-request`, and `chatManagerReload.*` read where the new ones are unset |
| StrictMode | dot-sourced and used from a `Set-StrictMode -Version Latest` shell — once as the tests run it, once as a real shell loads it (not the watcher, without the overlay's parts, no queue yet, stop on the first error; `autoStart` off in its copy, or the shell-start path would put a real overlay on the screen) |
| runner | stdin byte-exact on 5.1 (Hangul, quotes, `\`, `%`, newlines, no BOM); API key and `CLAUDECODE` kept out; 400 KB of stderr without deadlock; timeout kills the whole tree; argument quoting round-trips through a compiled echo exe, and through the same exe behind a `.cmd` with `& | < > ^ ( )` and a lone `%` in its arguments; for a `.cmd` or `.bat` only, a `"`, a `%name%` or a line break refused and named (`Get-ChatqCmdArgRefusal`), and only there are `& | < > ^ ( )` quoted |
| codex app-server client | `tests/sections/codex-appserver.ps1`, [Invoke-ChatqCodexRpc](src/codex-appserver.ps1) against the fake's app-server mode (`FAKE_APPSERVER`), no real codex: a rate-limit read whole, with exactly `initialize`, `initialized` and the read sent; `initialize` naming chatq and asking for the experimental API only with `-Experimental`; notifications passed by, and a request of the server's own - with the very id the read went out with - refused (-32601) and never taken for the reply; started on the given `CODEX_HOME` with `OPENAI_API_KEY` emptied, and gone once the replies are in; `thread/list` sent with `useStateDbOnly` true whether false or nothing was passed ([Get-ChatqCodexRpcParams](src/codex-appserver.ps1), a hashtable or an object, every other method's params left alone); several requests in one start, each reply to its own, one answered with an error `$null` and the rest standing; a method the server does not know said in its words; a refused `initialize` ending it there; a request that hangs timed out with the server and its parent gone, in well under 20 s; stdin held open until every reply is in - the fake reads stdin beside its work and exits the moment it ends, dropping a request still held by `FAKE_SLEEP`, as 0.159.2 does (S-A4), so a 2 s reply is taken by [Invoke-ChatqCodexRpc](src/codex-appserver.ps1) and lost to a session whose stdin is closed once the request is out; a home that is not there said, nothing started and no folder made; a codex that will not start, and one that ends before it answers, no data and never a throw |
| codex usage, asked live | `tests/sections/codex-appserver.ps1`, against the fake's app-server mode and `tests/fixtures/usage/codex-ratelimits.json` (the real 0.159.2 answer of S-A4, account id scrubbed): [ConvertFrom-ChatqCodexRateLimitsReply](src/queue.ps1) reading a free plan's one 43200-minute window as `month` / `monthly`, its plan, `ordinaryUsageAllowed` and no credits; windows with no length named by place (primary 5h, secondary week), the per-limit `codex` bucket standing in for an empty `rateLimits`, credits read, no window no answer; a rollout's 43200-minute window `month` too; the overlay's fetch ([Start-ChatqCodexUsageFetch](src/overlay-data.ps1) / [Complete-ChatqCodexUsageFetch](src/overlay-data.ps1)) returning nothing on a pass that waits for nothing, then the month and plan, exactly `initialize`, `initialized` and the read sent, the server gone, and the same answer after; an error said and not quiet, a home that is not there quiet; a codex older than the floor never started - said by [Invoke-ChatqCodexRpc](src/codex-appserver.ps1), quiet to the overlay - and one upgraded in place since, its old version still cached, read again by `--version` and started; `-CodexUsage off` with an ask out ([Update-ChatOverlayUsage](src/overlay-data.ps1)) dropping the ask and ending its server; the probe ([Get-ChatqCodexLiveLimit](src/queue.ps1) inside [Invoke-ChatqProbe](src/queue.ps1)): a full 5 h window ahead limited until its reset with `NoTurn` and no `exec` run, a limit the server says is reached limited with no reset, room left and credits past a full window both left to the `exec` turn |
| jobs | queueing records cwd and mode; the prompt file is named after the chat; done / limited / needs-input / skipped `-Continue` / busy chat deferred / idle live chat run, with a reload request for that window; 529 mid-run; an interrupted run failed and not resent; `chatqrm -Force` with no watcher |
| job core | a job `chatq` makes has the fields it always had, in their order, plus `sendNow` and `effortAtQueue`; a row by its id, exact and in any case, never fuzzy; `New-ChatqJob` says why and leaves nothing behind for an empty prompt, a Copilot chat, a continue with files, a chat whose transcript is gone, a file gone before it was copied; first, send now, a model, a not-before time, a staged file moved in and a pasted image; two jobs for one chat inside a second get ids of their own, and a job is found by its whole id even when the other's id starts with it (a prefix match found both and returned neither, and the watcher spun on the first); the first one put first sorts ahead; files go only to a job still waiting; `Remove-ChatqJob` takes the prompt and files; a job's number held from the moment its slot is taken - a job made while a slot has no `.json` yet, as a `chatq` editor tab still open, gets the next number, a prompt file and an id of its own (it had taken the same number, and written over the tab's file), the folder that held the id gone once the `.json` is saved with no file in it, and a slot given up gives its number back; `data/job-numbers.lock` held by another process for longer than its 3 s, and the job is made all the same; two processes making 12 jobs each for one chat at once - no number, id or prompt file taken twice, none lost; a run's log read as entries, a tail read reading fewer, and read while a run holds it open to write (`File.ReadLines` threw there); `Stop-ChatqJobRun` leaves a job that already ended as it ended; `Request-ChatqWatcher` never waits - the wake to a running watcher, a start when none runs, 'waiting' then 'failed' after 10 s, one that was running when poked and has gone since started again once; the console's Remove on a console with no window, timed by the clicks' own times: a click asks, 150 ms on is a double-click and no answer, `Update-ChatConsoleAsks` at 5.1 s puts it back, a click at 7 s asks again and one at 8.5 s removes; `Get-ChatConsoleRemoveStep` over -1, 150, 399, 400, 5000, 7000, 7001 and `Get-ChatConsoleSince` across the tick count's wrap; `Remove-ChatqJob` refuses a job running on disk though the caller's copy says queued, and logs no removal; `Set-ChatqJobRunAs` changes a waiting Claude job's mode and model, `''` giving the chat's own back, and refuses one already sent and a model holding a space |
| new chats | the job's session id chosen when it is queued and its transcript's path known, named by the prompt's first line; its first run is `--session-id` and `--name`, no `--resume`, and lands where it said; a window on that folder is offered the reload, in words of its own; the chat it made is found by id and the next prompt resumes it; limited after its prompt landed, it goes on as "continue" in that same chat, and its reload is offered when that finishes, not lost with the run the limit cut; filed by Claude under a folder that is not the slug (`CLAUDE_CODE_PROJECT_DIR_NAME` in the fake; a path over 200 characters does the same), it is found by its id, kept, and a requeue resumes it - the fake refuses a second `--session-id`, as `claude.exe` does; a title with `"` and `&` reaches `claude.cmd` whole but for those, and nothing after it is lost to cmd.exe; deleted since, its continue fails as a chat gone and nothing starts; a folder that is not there, or no prompt, makes no job; a new chat at a drive's root keeps `C:\` and Claude's slug `C--`; a job with no session never breaks the cut-off list; `chatq -New` (the rest of it is the attachments row's) in the mode and on the model given, `-WhatIf` saying `as a new chat starts`, and a `-Model` holding a quote refused with nothing queued; with no `-Prompt` the (stood-in) editor on a slot of its own - what was written there queued, the slot's folder gone and its number the job's alone (one prompt file holds it), no file said missed (a `$null` had printed `could not take in  - it goes without it`), a tab left empty queuing nothing and giving the number back - an `-Attach` file keeping its name, and `-Paste`'s text going under `-Prompt` with no editor; a job whose `-Model` `claude.cmd` cannot carry (written before the refusal, or by hand): its run failed with the reason and no process started, its own `--settings` file and the permit's folder gone, a Codex run the same, the probe `Refused` with nothing started, a chat's own model it cannot carry probed without `--model` - a Codex chat's without `-m`, still at low effort - and the watcher failing that job while its lane stays open - not blocked, no probe miss counted |
| Claude Code's lists | the rule as the extension has it (`Get-ChatEntrypointIn`, `Get-ChatUnlistedWhy`), case for case; `Repair-ChatListed` on sandbox transcripts - hidden by its tail, one line as the extension writes it, its write time kept, a second look adds none; a last line lacking its end; hidden by its head untouched; a process busy in it, or a print-mode run - by its kind, or an `sdk-cli` entrypoint under `interactive` - held; one idle, mended; no file, none made; a job run into a chat hidden by its tail lists it again as it ends, and `watcher.log` says so, while a new chat's first record, an SDK's, is left; the open and run requests carry the transcript's path where given, and no such field where not; the append lands after a record another writer added since the open - it never writes over one - and makes no file; `Repair-ChatListedAll` over the index lists again a chat hidden by its tail and never run into or opened since - one in use held and untouched, a side transcript and a Codex row passed over, a second pass none - and `chatclean` does it, naming the chat, with its ghost picker declined |
| status | the board folds prompts; Hangul cell widths; a zero-width cell; Join URL length and device routing |
| extension | `tests/extension-check.js`: which window a request is for (not the `-Mobile` sibling), the wording per kind and while a chat works, `autoReload` never while one works and never alone after a queued run; a queued run reloads by itself only with `away` true and `busy` false — not at the PC, not while another chat works, not on either unjudged or missing, not with `autoReloadAfterRun` off, not in a window that is not exactly the job's one folder (a subfolder, a multi-root window), and with it unset it does; a new chat a run started is never reloaded for by itself, with `autoReload` or on an away verdict; end to end from a request file — a window just opened marks a recent run, or a recent new chat, seen and neither asks nor reloads, an open one reloads, a multi-root one asks; the file watched |
| show fresh: the old process | the registry's `entrypoint` read, its `.key` never opened; `-RegistryOnly` never starts `claude agents`; VS Code's own process told apart - `claude-vscode` under `Code` or `Code - Insiders`, an unnamed entrypoint counting, a terminal's, a shell's child, or a parent younger than the child not; `Stop-ChatIdleProcess`: idle with its registry file → ended, the window's host pid named; busy or waiting → held; a workflow the window's process started (`entrypoint` `claude-vscode`) → held, one a print-mode run started (`sdk-cli`) with that run gone → ended; a print-mode claude of the chat alive → held, a window's process beside it not ended, and the same for a `claude -p` as 2.1.283 registers it, `interactive` with `sdk-cli` - `Test-ChatPrintLive` counting `sdk-cli` and `sdk-ts`, never `claude-vscode`, `cli`, none, or another case; the window a process was ended in noted with the chat in `data/idle-ended.json`, and nothing more for one held; one ended and the next busy on its second read - held, and the first one's window noted all the same, once, its host's start kept and matched back to it; a terminal's claude → other, and nothing ended, not even a window's beside it; `-JudgeOnly` → live, nothing ended, and whose a busy one is still found - a terminal's → other, a window's → held with its host pid; busy when its file is read again → held; no file to read → kept; `liveIdle: stop` ends the process once and the window is told, and with a workflow in flight the job waits and nothing is ended; `liveIdle: stop` cancelled meanwhile - failed as cancelled, the cancel file gone, the prompt never sent; Show it's first check (`-JudgeOnly`) - its idle process live, its window named, nothing ended, the verdict saying `judged only` in the four fields an older extension reads; its second, with a grace - a process that leaves by itself as its tab closes counts as ended, nothing taken down, `watcher.log` saying it left; one that stays the 8 s ended after them, not before, and with no grace at once; one gone with its file before the first look left by itself, one running with no file kept; `-HostPid` ends only that window's process of the chat; `-StartedBefore` never the process a tab opened since, nor its loading turn taken for the chat's |
| show fresh: the request | after a run, nobody at the PC or not → nothing ended any more - live, `busy` false with nobody there, the window named in the request; after a handover, the windows it asked named when none holds the chat now, and the job - one that holds it still named instead; the chat itself working → held and busy; background work told apart by who started it, never by when - `Test-ChatIdle` passes over a print-mode run's leftover workflow once no such run is alive and counts it while one is, a run that left one behind reads not held - live, `busy` false, nothing ended - and Show it afterwards ends the process, while the chip leaves it live - neither reads it as held for good, as both had, while a workflow the window's own process started during the run → held, busy, nothing ended; Show it while a queued prompt runs into the chat, or a print-mode claude does → `running`, held, busy, nothing ended; a check that judged nothing (missing) says `kept`, not `none`; after a `ran` or `open` request for a chat, the next run into it waits 30 s - not counted as busy, no attempt used - and another chat's request, or one past 30 s, holds nothing; a run a window opened the chat during (the fake writes its registry file mid-run) → its process left to the window, a `ran` request, the alert; one in the registry from before that nothing listed live → no request; a `claude -p` registered `interactive`, `sdk-cli`, into it during the run → no window, no request, nothing stale; the chip's `data/open-request` BOM-less with the chat, its folder, title, verdict and window, `code` asked once for the folder, and a run's `reload-request` left byte for byte; the chip ends nothing - its idle process left `live`, `busy` not judged; one ASCII `watcher.log` line per show - how, which chat, the process, busy, the windows, the outcome - and none for a call with no session id; the chip on a terminal's chat → 20, nothing written, no `code`, and the same while that terminal's claude is mid-turn (it had read as held); on a window's working chat → 10, the request naming that window; with a queued prompt running in it → `watch` (16), its live view asked for by job and the window brought forward - the run's handover window named, none exactly on the folder, → that window and 25 - while someone's own `claude -p`, no job of chatq's, → 15 as before; held in a window with none exactly its folder → 25 and no `code -n`, one exactly it → `code`; not started → 30; no `code` → 40; no session id → 50; a chat Claude Code never lists, its head an SDK's → `unlisted` (21), the request written all the same and the window brought forward, and one hidden by its tail alone 0; with its window not brought forward as well, both said - no `code` 42, `code` failing 43, a window of several folders 26; Show it's verdict one ASCII line of four fields; end to end, the alert per old process - `Show it in VS Code to see the run`, `before typing` (a run into a chat a window holds, away or not: its process left for the window, which closes its tab first), `open in a terminal too`; two requests inside one of the extension's polls (`Save-ChatRequest`) → a request alone is the file as before, no `earlier`, and the next one goes on top of it with the first carried whole under `earlier`, its `hostPids` still an array - a run's request carried under a delete still holds the next run into its chat - at most three carried, the oldest dropped first, read oldest first with the file's own last; one a minute old, or with no id, not carried; an older script's file read as its one request, and an array, BOM or not, as none; `data/signal.lock` held by another writer past its 3 s → the request written alone, no `earlier`, and the next write carrying it and letting the lock go; a second writer while the first holds it a moment → it waits and keeps the first one's request; `data/open-request` the same - an open carried whole under a watch |
| show fresh: code and the chip | `VSCODE_*` and `ELECTRON_*` dropped for `code`, in any case, the rest kept; `code.cmd` through cmd with `&` literal, a `%` refused, an `.exe` started itself with `-n`; `CHATQ_CODE` first, else the installers' place; with two installs, the `code.cmd` beside the running `Code.exe` before PATH, one with no `bin\` beside it passed over; the chip's child command - `'` and `’` doubled, the title only as base64, `CHATQ_OVERLAY` set, exiting with the outcome, no spawn for a non-GUID row; the chip after a 400 ms rest unless set - the config's default too - and not before, one of 250 ms set in `config.json` at 250, held to 100-3000, never on a sweep, kept while on it, gone at once on another row, kept 300 ms off everything and then gone, never with a button held, collapsed, mid-drag or twice in one visit; the rest starting only when the pointer moves onto a row; a chip that came up under the pointer taking no click in its first 300 ms by the mouse's own clock - `Test-ChatOverlayChipPressCounts` over 1000/1299 and 1000/1300, no show time, the tick count's wrap either side of 300, and a press stamped before the chip came up - and taking one after (the STA panel test: just up → **click again**, up a second → it opens), and at once once the pointer has been off it; a row's last pixel in and the next out; placed flush right, centred, kept on the screen; only a Claude row with an id and a folder; the tray's words per exit; a window exactly on the folder told from its title, also with a profile's name after the folder's - only a name VS Code's `storage.json` lists is taken off - and the chip on such a window brings it forward rather than giving 25; in the STA panel test, rows carrying their row, the chip's style (tool window, no activate, layered, not click-through, no taskbar), flush with its row, and hidden by a redraw without its row and by hiding the panel; an open under way, and how it went, on a line under the rows - nothing drawn above them, their states left as they are - and any other line said meanwhile not overwritten by the open's seconds; the chip reads the session registry alone, as `-Via button` does - busy is said there, and a `claude -p` there as interactive, stamped `sdk-cli`, is still 15; the tray's words for every end but 0 - held (10), a bad id or folder (50), and a code it does not know, a crash - and for a chat Claude Code never lists (21), its window's terminal offer, said in the quiet tone for 8 s - and with its window not brought forward (26, 42, 43) the offer and why, in warn's tone, 43 pointing at `watcher.log`; `Get-ChatOverlayOpenSay` - busy with its seconds, opened for 5 s, a failure, a timeout and a child that did not start in warn's tone for 20 s |
| extension: show fresh | `tests/extension-check.js`: the plan over every verdict - a terminal's → nothing, held, live or kept → reload, ended or none → a tab whatever else is working or unjudged, an old writer, `showFresh` off or no Claude extension → reload; the tab label Claude shows - no title `Claude Code`, 25 characters whole, 26 cut to 24 and `…`, and a real title as the Claude extension showed it; the target window by live host pid, not a window when another live one held it, by folder once every holder is gone; never by itself on a held chat or a judgement over 20 s old; the words for Show it, held, terminal, old writer, after Show it, and for an open - no Claude extension, not opened, now in two places; Reload Webviews and the side bar's focus gone; a tab: none open → one opened, a stale one with the chat's title, or with the label Claude shortened it to → closed and opened again, an untitled Claude tab never taken for a chat of no title, a title that does not match or an editor that is no Claude tab → nothing closed, a slow new tab caught by the second look → nothing closed, a new tab that came just before the close → taken as the chat's, nothing closed, two Claude tabs of one shortened label → never closed and said, the front tab unchanged → one more look before anything closes, a lone tab whose label another chat of its folder has - the same title or the same first 24 characters, open or not, never itself, a chat of no title or another folder's - → never closed, stale and said, while a label of its own is closed and opened again; a Claude tab the Claude extension's panel by its `viewType` alone - never Cline's, whose name holds "claude" too, nor a markdown preview; one tab of the chat only when exactly one reads as it - twins, or a chat of no title, are none; the group holding the chat's tab unlocked only while it is the active group and holds Claude tabs alone - a mixed or empty group left, no active group left and logged as that, `claudeCode.lockEditorGroups` set true left locked while false or unset is unlocked, a stale tab's new one's group unlocked too - and an unlock that fails logged and never thrown; a command that never settles timed out, logged, taken as failed and not asked again, with the queue going on; two shows queued together never interleave; Show it's command quoted (curly ones too), marked as the overlay, and never built for a non-GUID; the verdict read past noise, bad JSON or wrong types none; end to end a quiet exact window opens a tab by itself and logs the verdict it acted on, a multi-root one asks and Show it opens a tab and logs its check, a new tab where this window held the chat - by the request's host pids or Show it's - says once that the side bar's copy is stale, and not when the tab here was closed and opened again, a verdict a minute old asks, a run into a chat open here on an idle process → Show it by itself, at the PC and with another chat busy - judged only, its tab closed, then its process ended only if it outlived the close (an 8 s grace, this window's host alone, only processes started before the tab was looked at), then the tab opened again, nothing asked - and the first check finding it working by then → nothing closed, ended or opened, the held wording, no second check; Show it: a new tab - the chat had no panel here - left, the side bar's copy said stale; an extension-host restart told from a reload as Claude Code tells it - each activation keeps `vscode.env.sessionId` in `workspaceState`, the same one next time a restart, another a reload, none unknown, VS Code's placeholder untracked and kept nowhere - and within 30 s of a restart, or an unknown start, a new tab's second check only judges, nothing ended, the restart's word said instead of the side bar's; after a reload, past the 30 s, or with the chat's own tab closed, the second check as before; a front tab not surely the chat's - a twin, another's label - or the chat working by the registry right before the close, never closed and never ended under the tab left open; the second check finding it held or failing - not opened again beside it, and said; on scripts too old to judge only - the tab closed and opened again as before, no second check; idle in another window only - left there and said; a chatq run gone into the chat by the time it would open it again, or found running by the first check - that run's live view where the tab was; while `autoReloadAfterRun` off or a word a minute old asks and another window's chat is left to that window; away, its process ended by the run's check → a tab by itself though another chat works, a multi-root window asking; a failed check on a process left running offers the reload, and so does a check that judged nothing (`missing`, `bad`) - never a tab beside that process; Show it finding the chat held working → the held wording and **Reload anyway**, and another chat busy with this one live or kept → that other chat's work named and **Reload anyway**, never the held wording - in both, never "could not end" and **Reload**; a check that fails, or judges nothing, on a request that found another chat busy keeps that busy - the other chat's work named and **Reload anyway**, never "could not end" and **Reload**; Show it while a print-mode run that is not chatq's goes into the chat shows nothing, reloads nothing and says why - in the picker's words too, naming either kind of print-mode run, a queued prompt or `claude -p`, and promising no offer only a queued one brings; an open: `editor.open` with the chat id, no prompt, a column, no group, `fullEditor` false and `programmatic: 'pin-to-panel'` - never `primaryEditor.open`, whose full editor has no header - its column the one `primaryEditor.open` picks (a group of Claude tabs alone, the active one first; else the active group when it holds one; else the active group), worked out again for the second open of a stale tab - an inactive group holding a Claude tab among others, or an empty one, never picked; `editor.open` refused, not timed out → `primaryEditor.open` with the chat id alone, the tab opened and the log saying it has no header, for the chip and Show it alike; both refused once → tried again, the column worked out again; a Claude extension before 2.1.281, or of no version, still `primaryEditor.open` with the chat id alone, and its tab opens; versions compared as numbers, a suffix left aside; a new tab logged `new`, a tab there already only brought forward with nothing closed or said; a new tab for a chat a process of this window held says once that it now runs in two places, with the side bar's idle copy to close when it was live - not when a tab here showed it, when no process held it, or when another window's did; one working in a process of this window with no tab of its title → not opened, and says to click open again once it finishes, while a tab of its shortened title is opened; with two tabs of its label, one tab of a label another chat of its folder has, or of no title → counted as in no tab, and not opened, while one tab of a label of its own is revealed; where no window can be told (a Mac, `hostPids` empty) → refused as held here, unless exactly one tab reads as it; refused twice both ways → said, nothing else tried; no Claude extension → said, no command and no reload offer; `showFresh` off → still a tab; one for a window not exactly its folder does nothing, at startup a tab and nothing else, five minutes old is dropped as seen, and the same one twice acts once; `open-request` beside the signal file and following `signalFile`; a file of two requests (`requestsOf`) → each asked once, the earlier first, one with no id passed by, the newest in the one key an older extension reads and both in the list of the last 16, which a window's own memory backs when another window's write drops them; the script's next write carrying the last → only the new one asked; an older script's file one request, an array or no JSON none; an open file of two → both opened once, the earlier first, what the newest came to returned; a run's Show it offered and not taken, then the chip → Show it's way - judged, its tab closed, its process ended if it outlived the close, opened again - and logged, the next open only bringing the tab forward, and a newer run's request shown by itself taking the place of one not taken; Show it's way only while the chip finds the old process idle here - none left or one working → a plain open and the offer forgotten, unjudged or no window to tell → a plain open and the offer kept - and where Show it's check then finds the chat working, or fails, the chip's own open, never a reload asked; a handover closing the tab forgets the offer; that run's notice answered **Show it** once the chip went its way → passed by, nothing checked, closed or opened again; the first look after an update from an extension that kept one id → every request the file carries up to that id taken as seen and only the newer asked, while an id the file no longer holds → all asked |
| extension: the overlay | `tests/extension-check.js`, PowerShell stood in for: the lock missing, or there and opened by nobody, not held, and held for real by a `powershell.exe` holding it open (skipped with no `powershell.exe`); on Windows, Windows PowerShell by its own path, never setup's `hosts()` and its `where.exe`; on Windows with no `config.json` → `Start-ChatOverlayAuto` once, through the tool folder's loader, and its word taken; once per activation; `autoStart` false, with a BOM or without → not started; on a Mac off by default and started only when on; Linux never; the lock held → running, no PowerShell; no loader → not started; no word from the script, or PowerShell throwing → failed, never thrown; a `config.json` that does not parse or cannot be read → off, a missing key the default; a look before the loader is there does not use up the one start; activation with the loader in place starts it at once, once, even while the setup waits on its question for good, and on a first install once the setup has put the loader there, from it, once - with the profile question still unanswered; during an update never from the old loader, only once the copy is whole, from the new one, once; while another window holds the install lock (`elsewhere`) not at all, that window starting it; **Chat Manager: Overlay: start by itself...** in `package.json` and registered - On runs `chatoverlay -AutoStart on` through the tool folder's loader and stops nothing, Off runs `-AutoStart off` then `chatoverlay -Stop`, and says whether the overlay was closed, not yet or not running; the script not saying it took → failed, said, no `-Stop`; nothing picked → nothing run; no loader → said before any question; no panel on the platform → said |
| extension: the chat picker | `tests/extension-check.js`, the Claude home a sandbox folder - `CLAUDE_CONFIG_DIR` an empty one for the whole run, so no check reads the real `~/.claude`: a folder's project named as `Get-ChatSlug` names it; noise and titles as `Test-ChatNoise` and `Format-ChatTitle` have them; every folder's `<GUID>.jsonl`, newest first - a project folder of another case found, nothing else and nothing deeper listed; a rename first, the newest, then the newest `ai-title`, then the first prompt typed past the noise; the sidecar's rename over an `ai-title`, a big file's `ai-title` from its tail and its prompt from its head; a side transcript, and a small one holding no message, left out; titles kept by path, size and write time, read again only once the file changes; what runs each chat - a panel idle is open, busy or waiting working, a terminal wins, nothing is closed, and a run nobody types in (a `kind` set and not `interactive`, as chatq's `claude -p`) running, never a terminal, while an interactive one still is; an entry naming no `entrypoint` no terminal - working or open, as the script's empty where has it; an entry whose pid is gone, whose `startedAt` is ahead, or from before the machine started, runs nothing; the age as `Get-ChatAge` gives it; listed newest first by title, a codicon for what runs it, the age and state beside it, the folder in a multi-root window; a `$(` in a title or a folder's name kept as typed, never drawn as a codicon - only a whole codicon pattern (`$(terminal)`, `$(sync~spin)`) escaped, as VS Code's `escapeIcons` does, one escaped already left alone, and `x $(a b)` or `echo $(git rev-parse HEAD)` as typed; accepted - open idle elsewhere asks with **Open here too** and **Cancel**, Cancel opening nothing and Open here too opening through the chip's core; open with its one tab here brought forward, nothing asked; a terminal's refused and said; a queued prompt going into it (a print-mode run) refused as running, in words of its own, not as a terminal - a `claude -p` registered as `interactive` with an SDK's `entrypoint`, as 2.1.283 does, too - while a chatq run going into it opens its live view, looked at before anything else; working refused and told to open it once it finishes, twin tabs too, its one tab here only brought forward; a label another chat of its folder has - the same title or the same first 24 characters, never itself, nor for no title, nor in a folder neither the window nor the chat is on - its one tab counted as none: working refused, open asked; every folder of a multi-root window looked in beside the chat's own, twins in two of them found; each folder's newest 200 read (200 of 205); a look not done within `labelBudget` taken as shared and logged, and 0 no limit; read again after the question, and again right before the open, which waits behind another show - working, or a terminal's, by then refused as it would have been at once; closed opened from disk and logged; titles slow to read listed at once by id and filled in as they come, the item under the cursor kept; the newest 200 only, listed before every title is read - the rest by id, each read made 5 ms slower and no wall-clock limit asserted - and then every title read; a big file's rename, or Claude's title, written only near its start read from its head where its tail has none of that kind, the tail's still first and a sidecar's rename over the head's `ai-title`; each registry entry's process, as CIM would say it (`procFacts`, PowerShell stood in for, never started) - its lines parsed by pid, FILETIMEs kept as strings, a name with a space whole, a parent of no name; still the entry's - a claude or node started within 3 s of a FILETIME `procStart` and never over 10 s after `startedAt`, a start not read saying nothing; a panel's window by its parent - this extension host here, another Code (or Code - Insiders) that is there another window, a terminal's, a parent gone, of another name or younger than its child told nothing; every pid asked in one run and kept `procFresh`, a look that found nothing kept not and logged, none off Windows, a second look while one is out waiting for it, a failed look handing no older answer back; the registry with it - a pid a later process has, or one of no claude's, running nothing; the picker saying `in this window` or `in another window` - and the picker itself, its look held back until the titles are listed, putting the list again once the look comes back: `open in another window` for a chat there, and no state for one whose pid a later process has; accepted - working in another window with no tab here handed to it through `data/open-request` as the chip hands one (`oldProcess` held, `hostPids` that window, `busy` null, a request no window but that one takes) and said, open idle there asked with **Show it there** first, which hands it over (live), and **Open here too** as before; held in this window outside its tabs refused or asked in words of the side bar, nothing handed; Show it there on a chat since in this window's side bar doing nothing and saying so, and on one closed since opening it here from disk, nothing handed; an `open-request` that cannot be written not handed, said and logged |
| extension: the queue in the status bar | `tests/extension-check.js`, a tool folder of the sandbox's own: the lanes' limits and overloads from `data/state.json` - one ended left out, none where the watcher is down or only listening; the next send as `Get-ChatqEta` has it - one free now `next`, or `after #seq` of the run going, else the soonest wait, each job's latest of its lane's limit and a minute, `notBefore`, a `deferUntil` or `retryAt` still ahead, its own lane only, an overload skipped or `when Claude is back`; a job whose latest wait is a `deferUntil` for a tab in use or a background command no time but the board's words (`waits for you to leave its tab`, `waits for a background command`), a later retry or a `vscode` hold still a time, and another job's real time first; the words - a time today, a weekday before one later, what it waits for, `watcher stopped` with `chatqrun` named; the item from `data/` - none before anything is queued, shown with the board's command and beside the run's item, no job file read again while none changed, only the one changed read again, the watcher's lock (`data/watcher.lock`) down said, hidden once nothing is queued; off Windows the pid `state.json` saved; a click opening `data/queue.md` in the Markdown preview, and none yet said; **Chat Manager: Show the queue** registered and in `package.json` |
| extension: hidden chats | `tests/extension-check.js`, in a sandbox Claude home: the first `entrypoint` found as Claude Code finds it - the key without a space first, the last by place, escapes read, one cut off none; an SDK's first in the head hides a chat for good, with none in the head the tail's last decides, a window's listed; hidden by its tail - one `chatq-listed` line naming `claude-vscode`, no timestamp, added at the end, byte for byte the script's, listed again, its write time kept, and a second look adds none; a last line lacking its end gets the new one on a line of its own; a process idle in it - mended beside it; one busy in it, or a print-mode run - left, and a head that hides it, a listed chat, or no transcript found - nothing written, no file made; a request's transcript path taken where the slug finds nothing, but only a file named for the chat; the open chip on a chat hidden by its tail - the line written before the open is asked for, then a tab as any other; on one a run writes to - not opened, and said; on one hidden by its head no tab, a terminal offered - `claude --resume <id>` as the terminal's own process, in the chat's folder and Claude home - and "Not now" makes none; the offer taken once the chat runs somewhere - no terminal, and said - and a second offer while one is up - none; a chat whose line cannot be written - not opened, and said; Show it on one hidden by its head, and the picker on one hidden by either, the same; a new chat a run started - said, and no reload offered |
| extension: the handover and the live view | `tests/extension-check.js`, the window's side of `data/run-state`, VS Code stood in for: `chatManager.watchRuns` off - answered `off` in `run-ack/<this pid>.json` by the handover's id, nothing closed or opened; no tab here reading as the chat, or two - `unsure`, the live view beside, the old view said stale, never `editor.open`; its tab in front of you in a focused window - `in-use`, nothing closed, said once with **Hand over now**, which clears only that job's wait, while it still waits for its tab, through the tool folder's loader and a poke of the watcher, and lets that job's next handover go ahead - clicked on a notice gone stale, nothing run and the rule kept; the tab shown but nobody at it - the live view in its group first, then the tab closed, the record kept, and away in front of you the same with the view taking the focus; a tab behind others - closed, no view over what is shown there, said with **Watch**; the chat working by the registry - `in-use`, nothing said; another window's handover or one whose job is not running - not answered; an answer come late - nothing written, no tab closed, no word that the job waits; a run beside its tab (a background command, unsure, timed out) - the tab left, the view beside, the old view said stale once a run - a write of the same run (its `handoverId`) saying nothing more, the job's next run after the limit said again; the end - the view in front: the chat opened in its place, loaded from disk, then the view closed, the record marked, the run's own request after it taken as seen, put back once; the view not in front, you here - it stays with **Open chat**, away - the chat in its place; the view closed already - asked; a watcher that died mid-run an end too; the end at the limit put back as any end; a process holding the chat again - Show it, nothing opened beside it; one unanswered question holding up no later job's put-back; after a window reload, nothing put back before its watch panel is back, and a run whose panel was closed before put back once that moment is over, and one whose watch tab VS Code keeps but never brings back waiting for it `tabHold` from the first look past `restoreHold` that finds the run over - no clock before - then put back as for a closed view - asked - the tab left, and that tab shown after it saying how the run ended, with **Open chat**, nothing opened or put back again; the wait ended early by the tab brought back - the chat in its panel's place - or closed - asked - put back once, nothing left waiting; and a job run again while its record waits starting the wait over, its next end waiting `tabHold` of its own; the run-state stand-in giving `handoverId` as `Write-ChatRunState` does - a handover's own id, else null unless passed; the status bar - `chatq #15 running` in windows on the job's folders, a click watching it, the warning colour while the phone is asked, none for another folder, a dead watcher or an ended run; a job set running before run-state says so is the run going in, not with its watcher gone; the panel - its own `viewType`, scripts on, kept while hidden, no local files, titled by its mark, `#15` and the title, one per job, the log tailed a whole line at a time, a long log read from its last 2 MB and said, Cancel in a modal and then `Stop-ChatqJobRun`, Log opening the log, Open chat once it ended and the view closed, none for Codex, a continue headed as one, a prompt of megabytes read only from its first few KB and cut at 300 characters, brought back after a reload, one whose state names no job closed; `openCall` given the column; **Watch the running queued prompt** - none running said, one running its view; the chip's watch - its view, no Claude tab, one naming no job nothing, a window not exactly its folder leaving it; the chip's open and the picker - a chatq run going into the chat opens its view first; a watch panel keeps a group Claude's and is never a Claude tab; `watchItems` - init with the model, the mode and the version, text, tools with their argument, results cut to 3 lines and 300 characters with `+N lines`, errors marked, a subagent's rows indented, the heartbeat on its tool's row, `Edit +2 -1`, a denial, the limit's reset, the end's turns and time, thinking and an allowed rate event left out, the latest TodoWrite pinned - kept apart from the rows, so one dropped past the kept rows stays pinned until the next -, a running tool's own clock, a line over 256 KB never parsed, Codex as `Get-ChatqLogEntries` reads it, every text escaped, a line taken only once its newline has come, a retry's init closing what the cut-off attempt left open, the last 5000 rows kept; the header and its end states; the page - a nonce'd script and style and nothing else loaded, VS Code's theme colours, a full batch built apart and put in at once; `package.json` declaring the command, `chatManager.watchRuns` (on) and the panel's activation event, and `watch.js` carried |
| extension: Ultracode and effort | `tests/extension-check.js`: every `/effort` answer in `tests/fixtures/session-vector.json` read as it says - Ultracode on, off or unsaid, by the version too, a level kept only where it is for the session, a refusal nothing - and every transcript there read as it says, at the reader's chunk and at 777 bytes alike, within a case's budget where it has one (`node tests/fixtures/make-session-vector.js` writes the file again); a line's kind - `/effort`'s answer, a turn's level, an Ultracode notice, a prompt typed, another user record, a compaction - a `claude -p` run's only its notices and compactions, and none of a subagent's, another command's, a tool's result or a meta record, nor the words in a message; Ultracode by the chat's own notice or `/effort` answer since the last prompt typed, else as that prompt found it - a queued run's notice before it counts, a compaction between is off; the level of the latest turn a prompt started where max, or set by the last `/effort` before it for the session only; read backwards in chunks, a line cut across two put together, past the budget unknown and nothing said; with `chatManager.keepSessionSettings` off, the pre-fill - `/effort ultracode` where Ultracode was on, with or without a level, else `/effort <level>`, none where nothing was lost or it is unknown; the word - the chat, what was lost, what its input box holds and that the send key applies it, the level to type after where both were lost, never the effort menu; that key Ctrl+Enter where the Claude extension sends with it, Cmd+Enter on a Mac, else Enter; the pre-fill given and said on Show it's close and reopen (a run's own exit since passed over), a stale tab reopened after the script ended its process, the chat put back after a handover, and the live view's Open chat with no process of the chat; the commands named and nothing in the box for a new tab for a chat a process of this window held outside the tabs, one another window's process the check ended, and a Claude tab here reading as the chat; a process holding it by a late Open chat - Show it, nothing opened beside it; the chip's and the picker's opens nothing, closing no tab of chatq's; the panel's header `Ultracode` and `effort max` where the job or run-state carries them, a level Claude Code does not know not shown, neither while queued; carried into the new process, with the setting on (the default) - the pre-fill planned as none, and as before with the setting off or no hook to be had; the hook on a stand-in `child_process`: in once, out with the original back, one another hook put over it later left in place, a module that refuses it not in; a launch naming the armed chat by `--resume=<id>` or `--resume <id>` given `--settings {"ultracode":true}` and `--effort max` before a `--`, its command and options as they were, once; another chat's launch, one of no chat, one with no list of arguments as it came; a newer arm settling the older as nothing; a launch naming `--settings` or `--effort` of its own keeping it, the other alone carried and what was not logged; an arm gone after `carryWait`; a hook that fails passing the launch through, never thrown; Show it's reopen, its new tab beside the side bar's copy, a run's tab, the chat put back and Open chat - no prompt, no word, `carried` logged; no launch - the commands to type once the arm goes, Ctrl+Enter where that sends, and in part only what did not go in; the chat put back not holding the show queue on its arm; `deactivate` putting `spawn` back; `chatManager.keepSessionSettings` declared (on) |
| overlay: transcripts | the newest prompt and title of a 3 MB chat from its last 256 KB, counted in bytes read; read back past a 3 MB line when no record follows it; a budget stops the search and keeps the title found; a `last-prompt` that is machinery falls back to the real prompt; a Hangul prompt cut by a block edge put back together; a rename wins over the generated title; a transcript that grew read only from the end of the last whole line read, and a line still being written as one read comes taken whole by the next; `/compact` the way it goes - while it runs, the dequeue with no record after it marked pending, still so as records that end nothing are added; once written, the command newer than the prompt before, not the compaction's summary; kept while only the old `last-prompt` is written again, 100 KB on, that read taking only the bytes added; a command read with no `last-prompt` beside it kept as the old one is written after it; replaced by the same words as the prompt before, typed again (by its timestamp), and by the next prompt; a prompt after `/model opus[1m]` wins, the arguments read; a skill the model loads is no command; a working row on a pending command says so, an idle one does not; an open chat nothing has titled shows its first real prompt, past a noisy one (two user lines or more had been read as one, and none found) |
| overlay: sessions | `sessions/<pid>.json` read and the `.key` beside it never opened (held locked, so a read would fail); a dead entry, a new chat tab with no transcript, and chatq's own `claude -p` runs get no row; one chat in two windows is one row at the more urgent state, and one window closing leaves the other; the watcher's fallback reads the same registry with `waitingFor`; against a real process: matching start → alive, `procStart` an hour off, a reused pid and another machine's entry → not, a macOS date `procStart` not held against it |
| overlay: rows | waiting oldest first, then working, running, idle newest first, queued in queue order; a prompt queued for an open chat rides on its row; a job row carries its first line; the snapshot's counts match its rows |
| overlay: open tabs | a VS Code tab with no process a row as an idle open chat's - no pids, where `vscode`, its time the transcript's, its title and prompt from it, and `tab` - taking a cut-off and a queued prompt as one does; a tab whose chat a process holds keeping that one's row, and one with no transcript found, or none looked for, getting none; in a pass, the tab's row titled from its transcript and out of Recent at once, and the tab closed, the row gone and the chat back in Recent; `data/open-tabs/` read ([Read-ChatOpenTabs](src/overlay-data.ps1)) one tab a session id, the first kept, each with its window and host pid, a BOM let past, a gone window's file removed and one naming no pid passed by, a file caught mid-write skipped and kept, one whose pid a process started days apart now has removed, and no folder at all nothing and no error; a file parsed again only once its text changed - the same text, the same parse - and its window looked for once in 10 s ([Read-ChatHostFiles](src/chatrm.ps1), reload-pending's reader too): one that died listed 10 s more at most, then its file removed, and with the clock set back looked for again at once; the phone board's own scan giving the tab the same row, not in Recent; in `tests/extension-check.js`, the window's side: an untitled tab, a label on two tabs and one two chats give skipped, a unique one resolved; the file's format, through a `.tmp` and a rename; written only on change, a tab moved writing nothing; a file gone written again, and removed when no tab is left; a look past the label budget leaving the file and said once, the first such look asking for another soon and the next not; the watch on `onDidChangeTabs`, and dispose removing the file; activation sweeping the files of hosts gone, and this host's own, a live window's kept |
| overlay: answered jobs | what was last typed into an open chat kept - a prompt typed after a command, not the command; a job parked on input answered only by something typed into its chat after it stopped, never by its own prompt nor for a job in another state; a pass skips, `answered in the chat`, the one whose open chat was typed into since and the one whose closed chat's transcript was, its tail read only once it changed after the job stopped, and leaves the one nobody answered; with no overlay, the phone's Status and `chatqlist` skip it as they list and no longer say it needs you, a list with no job waiting closing none |
| overlay: usage | the live answer's 5 h, week, and a model's week once used, in the server's colours; not asked again on the next pass; a window whose reset passed reads empty and is asked about at once; a 401 falls back to the cached figure and waits 10 minutes, a 429 with no Retry-After 5 and says when it asks again; the refresh button asks at once after that, but not twice in 20 s; what a click did is said at the end of Claude's usage - asking, then when Claude answered, gone 10 s on, or why it did not ask - and reaches overlay.json on the next pass; an old Codex figure says it is from Codex's last run; each provider's line ends in when its figure is from or what is happening to it (asking, checked, cached, last run, retry at the named wait) - under its name as bars - and in neither view does any of that take a row of its own, and a time over a week old shows its date (`Mar 13`, not the weekday that read six months as last Friday); Copilot's quota read from GitHub's answer on the free plan (chat, code) and a paid one (premium alone), a fraction of a percent kept as one (`[Math]::Max(0, 0.1)` had rounded it away), a Copilot line from gh's answer, and none - quietly - when gh is not logged in or not there; Codex asked live through `ChatOverlayCodexUsageSeam` (the sandbox's default answers as a codex that is not there, so no pass starts the fake): the answer over an older rollout with its month, plan and the time it was asked rather than `last run`, a newer rollout over it, asked every `usageSeconds` while a Codex job works and not while idle, again once a window's reset passes; a quiet failure keeping the rollout's figure, logging and saying nothing and waiting 30 minutes; any other logged, said after the last answer with its retry, and waiting 2 then 4 minutes; the refresh button lifting that wait; `codexUsage` off never asking and showing the rollout alone; a restart keeping the last answer and its plan, counted as asked; Retry-After read from a real `HttpResponseMessage` as seconds (2867, the figure the live endpoint sent) or as a date; a 429 with Retry-After waits that long, says `rate-limited until`, and the refresh button keeps to it; the panel's note says so over the last live figure too; a live figure 16 minutes old is not stale while idle asks are 15 apart, a cached one is; with live usage off, only the cache shows; a restart restores the last live figure and that wait from `overlay.json` and does not ask; an expired login is not used; a failed ask is logged and the token appears in no file; a machine with no Codex still gets Claude's |
| overlay: control | a running overlay is shown, never started twice; `-Stop`, `chatinstall` and `chatuninstall` reach it; commands taken once, a stale one dropped, a pass with none queues none; the collector loop ends on `restart`; `overlay.json` BOM-less with Hangul, schema 1, epoch ms; `-Unlock` / `-Reset` / `-Collapse` wait in `overlay-state.json` while it is not running, and `-Expand` undoes it; `-AutoStart on` read at shell start, `-AutoStart off` kept and honoured; on by default on Windows, with no `overlay` block or no `config.json` at all, and started then; `Start-ChatOverlayAuto` prints one word - off, running while the lock is held, started once through the launch, failed when it fails - and none of the launch's own words, which go to `overlay.log` with the reason, or what it threw; a `config.json` that does not read → off, nothing started; `-Stop` keeping the close against the (stood-in) sign-in and saying so, the auto start then off and starting nothing until the next sign-in, `chatoverlay` - even a launch that fails - and `-AutoStart on` lifting it, and no sign-in known keeping nothing and promising nothing; `chatuninstall` lifting a close; the real `Get-ChatqSignInAt` (Windows) reading a time, the same twice, no later than the test process's start; the code stamp of the script and `src`, a change - a newer write, or a copy with the old times but not the length - restarting it only once looked at a minute on and held 5 s, a new part holding it off again, none noted or no script never; `-Width` and `-Rows` kept and said, out of range refused with nothing on that line saved, out of range in the file held to 260-800 and 1-30, and a running panel sent `reload`; an edge's drag, summed - the left side widening leftward with the right edge where it was (at 150% too) and the right side rightward with the left edge where it was, narrowing back to 260, the bottom a row per row's height of travel down and the top one per row's height up, none within the first, a side never the rows and the top or bottom never the width, a corner both, collapsed width only, an unknown row height taken as 36 units, and from fewer rows drawn than kept, outward never below those kept while back takes one off those drawn; stretched out, the open rows not drawn first, a row a row's height, then Recent lines, a line a line's height, and past the pool nothing more; stretched in, the Recent lines first, then rows, never under one, Recent down to none - by the top edge too; no travel keeping rows and Recent as saved, outward never fewer, inward from those drawn; with no chat open, travel in past the Recent lines taking no rows, `maxRows` kept as saved; Grow, for the top edge's cap, in WPF units the rows and lines the travel came to, the Recent header with the first line and without the last, none folded; each edge's cursor - up and down, sideways, a diagonal for a corner, sideways for every corner while folded; the edges' window the panel's rect and the band's depth more on every side; the height cap as the top edge is dragged, from the bottom held up to the working area's top, never under its floor; `-Compact on` the prompt line off and `-ChipDelay` kept, both said, out of range refused with the rest of its line, and a running panel told; `-Recent` 5 unless set, kept and said, 0 off, out of range refused, held to 0-20 in `config.json`, a running panel told; where a chat runs from its registry entry's `entrypoint` - `claude-vscode` a VS Code panel, an SDK's (`claude -p`) a run, any other a terminal, none nothing, a run beside a window winning, a job nowhere - in the snapshot the view key is made of; delete greyed on a chat a queued prompt runs in, as on a terminal's; `-Print` marks a terminal's chat `>_`, one a queued prompt runs in `|>`, and lists Recent under the rows; a held job's reason - `waits for a background command (since ...)`, `waits for you to leave its tab` - in the console and the panel's rows where its send time would be, its ETA again once the hold is over, and the same words from `Format-ChatqDeferWhy` as the lists' - a week-old start as its date, a busy wait none; the chip reading **watch** while the row's job runs, `opening` while its child runs, the tray's words for a live view asked for (16) and for a print-mode run no job is (15), and the unread dot kept on 16; `overlay.log` writes a line once in 5 minutes, and every time with `-Always`, and past 500 lines held back lets go of those 5 minutes old as the next is written, a newer one still held back ([Write-ChatOverlayLog](src/overlay-data.ps1)); hotkeys parsed and nonsense refused; `-UsageView`, `-CopilotUsage` and `-CodexUsage` kept (Codex's on by default), lines by default and for a view it does not know; `-Theme` and `-Opacity` kept, a percent read as one, an opacity out of range refused, an unknown theme drawn dark; `system` following the (stood-in) Windows setting; both palettes name every colour; the bar of buttons in the panel's top strip, 4 units under its top edge and 8 in from its right, at the screen's top too, and following the panel off the screen's side, a box wider than a narrow panel sticking out to its left; the settings box above the panel where it fits, else under the bar over the rows, keeping its side while it fits there, and one that fits neither side going to the side with more room, so the least of it runs off the screen; the panel's default spot the main screen's top right, 16 in from the top as from the right; the edges come only after the pointer rests 350 ms on the panel or on the buttons, never with a mouse button held, stay while it is on either or a button is held, and go 700 ms after it leaves; the buttons' zone their window's rect, an open box's gap to the panel in it; placement back onto a screen; the launch line (`powershell.exe -STA`, `CHATQ_OVERLAY`, and `CHATQ_ALLPARTS` dropped once loaded); started for real from a folder named `ov[1]`, it runs in your home folder, not that one, with every part loaded and only `CHATQ_OVERLAY` left for what its panel starts ([Start-ChatOverlayProcess](src/overlay.ps1)); the tray tooltip under 64 characters; reset countdowns |
| overlay: cut off | an open idle chat the limit stopped says when it resets and sits just under those waiting; a working one has moved on; one not open gets a row of its own with its project; a 529 says what it waits on; a continue queued replaces the row; a limit that is over says so; the scan the overlay runs every minute reads a transcript again only once it moved (none the second time, one after it grows), never reads a chat it is told is working, and names where each chat ran; a limit record with no `cwd` of its own takes the tail's; one folder it cannot list costs only that folder |
| reset ask | `tests/sections/reset-ask.ps1`, beside the overlay section's sandbox: `autoContinue` read as ask, on or off - `false` and `"false"` off, `"on"` on, missing and `true` ask - and written at the top level by `chatq -AutoContinue`, which refuses a target (the switch is for every chat) or another switch and saves nothing on `-WhatIf`; the answer's own pass run first in the panel child, since a process's first pass over the whole sandbox can outlast the 10 s a watcher is given; a cut-off's key from its limit record's `uuid`, else its time, and none for a name that would not make a file; which chats are asked about - a limit, not a 529; a reset 5 minutes behind and under 12 hours, none with no reset time; no job queued or running; not answered; a terminal's chat named in `Left`; nothing while a 5 h or week window is still limited - newest first, with the latest reset; the answer markers made once, `.shown` once, both gone after 8 days; an answer acting only on the chats it was shown, a changed ask acting on nothing; continue queuing a job each and marking only the chats that got one or had one; the continues ahead of an older prompt waiting for another chat, in the order named, behind a job put first; a failed one asked again; leave marking all; `ask-go` and `ask-leave` from `overlay-cmd`, and one naming the keys the Mac menu showed answering those only; announced once, across a restart, and never by `-Print` or a `-Peek` pass; the phone's one `limited` alert only when away; the rows kept 12 hours after their reset; the reset time on the usage line, the collapsed line and the tray tooltip; in the Windows panel child, the banner and its two chips, the tray's items - there while an ask is out, gone (`Available`) once it is answered - the balloon and its click opening the console, the settings box's **Cut off** row (Continue, Ask, Leave); the console's header and **Leave them**; an answer to an ask gone, given in the console, doing nothing, the console kept and its status line saying `the chats changed - here they are now`; the console's Cut off list with `overlay.cutOff` off, from the ask itself, each chat once |
| auto-continue | `tests/sections/auto-continue.ps1`, before `host-work.ps1`: [Auto-continue](#auto-continue) has it in full |
| phone extras | `tests/sections/phone-extras.ps1`, after `phone.ps1`: [Usage heads-ups, quiet hours, voice and text from Tasker](#usage-heads-ups-quiet-hours-voice-and-text-from-tasker) has it in full |
| permissions | `tests/sections/permit.ps1`, after `phone-extras.ps1`: [Permissions from the phone](#permissions-from-the-phone) has it in full |
| phone board | `tests/sections/phone-board.ps1`, after `permit.ps1`: [The phone board and the whole answer](#the-phone-board-and-the-whole-answer) has it in full |
| questions | `tests/sections/ask.ps1`, after `phone-board.ps1`: [Claude's questions from the phone](#claudes-questions-from-the-phone) has it in full |
| host work | `tests/sections/host-work.ps1`, after `auto-continue.ps1`: [A new version, and the chats a reload stops](#a-new-version-and-the-chats-a-reload-stops) has it in full |
| handover | `tests/sections/handover.ps1`, after `host-work.ps1`, with the handover on - the sandbox turns it off everywhere else (`ChatHandoverOff`): a window's tab holds the chat - the job running first, then the window asked, then the run, then ended; `data/run-state` - every field, the same run in each write, the handover's id carried on, the last write on disk UTF-8 with no BOM; its process left - nothing stale, `watcher.log` saying the tab closed, and the window noted once in `data/idle-ended.json` (`Add-ChatIdleEnded`); the run's request naming the window that handed over, though no process holds the chat now, and the job, its `started` alert warning of nothing; a tab in use - not run, back in the queue for a minute, its try not counted, ended saying queued with no handover id, and every list saying `waits for you to leave its tab`; the same tab still in use - running while asked, then queued again with nothing in its history, `jobs.log` or `watcher.log` saying it ran, and asked less often, 2 minutes then 5; a busy chat in between - kept as `busy`, a history line for each change, a minute again; a background wait then a busy one - one history line for the change, none for the same wait again, the lists saying `chat busy`; cancelled during the handover - its try not counted, no start kept, ended carrying the handover's id only where the tab closed; the next run into a chat a handover just ended in held back 30 s from the end, not counted as busy, an older wait's reason, since and note cleared - only an end that had a handover, for that chat, within 30 s, holds; a job that starts clears its old wait's reason; a window unsure of its tab, or with `watchRuns` off - beside it, said, stale; no answer - beside it after the wait; a tab closing whose process outlives the wait - timed out, beside it, and no note of that window; beside a view of the chat each of those ways, the `started` alert ending `open in VS Code: do not type in it until done`, and ended carrying the handover's id only after the timed-out close; not closed and the chat busy by now - back in the queue, never beside a turn; `handover` false - beside it, stale, the `started` alert saying not to type in the chat; a terminal's claude holding it - no handover, the `started` alert ending `open in a terminal too: do not type there until done`; nothing holding the chat - running, then ended, its `started` alert warning of nothing, a failure as failed, a limit back in the queue as queued; a run that throws - ended all the same; a watcher stopped mid-run - its next start fails the job and writes ended, keeping what the run-state said; a continue says so; a queued run's environment - background tasks off, the Bash tool's timeouts an hour and 30 minutes, print mode's wait an hour, one the watcher's own environment sets left as it is; the 4 h deadline after a turn that ended well - done, with a note, after a failed turn or a cancel failed; the chat's own background work - an agent its window's process started waits as a busy chat does, with since when and what it is, a background shell under the process waits on shells alone, past 20 minutes from its start runs beside it, a shell no longer under it or one that cannot be counted holds nothing, a print-mode run's work or work from before the process nothing; the watcher waiting on a shell - `waits for a background command (since ...)` where its time shows and in `watcher.log`, never giving up, and past 20 minutes beside the chat with no handover, the run-state and the history saying why; an agent still out after a day - given up in its own words |
| Ultracode and effort | `tests/sections/ultracode.ps1`, the last section: every `/effort` answer in `tests/fixtures/session-vector.json` through `Read-ChatEffortSay` - Ultracode, whether a level, and which, `$null` never `$false` - and every transcript there through `Get-ChatSessionSettings` at its own chunk and at 777 bytes, within a case's budget, `Get-ChatUltracode` answering as it; on records shaped as 2.1.284 writes them: a notice, two `/effort` answers, a prompt and a turn quoted in a tool's output nothing, another command's `local_command` in `/effort`'s words nothing, a print-mode run's `/effort`, turn and exits leaving the chat's own; Ultracode and max 5 MB back, past a 2.5 MB line, still found and quickly, past `-Budget` `$null`; a record cut by a block's edge read whole; the chat had it on, the run in auto mode - `"ultracode": true` in a `--settings` file of the run's own, no `--effort`, resumed on its own model, the file gone after, and the job, its history, `watcher.log` and the run-state say so, the console `running since ..., with Ultracode`, the level, both; a queued run's own prompt, exit and turn since change nothing; switched off - neither flag, nothing said; max for the session - `--effort max`, `at effort max`; both - `as the chat had them`; default mode - no Ultracode, the level still, `Ultracode left off (default mode asks before each Workflow)` in the history and a line of its own in `watcher.log`, run-state false; `Get-ChatqRunCarry` by the job's mode, else the chat's as queued, else default - auto and bypassPermissions carry it, acceptEdits, plan and default hold it back by name; a job with `-Model` - neither; `Invoke-ChatqRun` judging it itself, by the mode too, and none when told none; the permit's run - one `--settings`, the permit's, its 4 deny rules and `"ultracode": true`, and so still with that file deleted or spoilt before the run; a run's own settings file gone when its process throws at the start, and with its job when removed; `CLAUDE_CODE_EFFORT_LEVEL` set - no `--effort`, the variable left as it is; a level the menu set since - no `--effort`; a job removed while its carry was read - not run; the settings' rules - a `Workflow` allow in the user, project or local settings carrying it in default mode and saying where, a deny or ask holding it back in auto, plan holding it back whatever allows it, a spoilt local file read as none, `CLAUDE_CODE_EFFORT_LEVEL` in the project's or the user's settings `env` dropping `--effort`, the first file read (user, project, local) named, plan's own words in the history - and a watcher run carried by the project's allow, one held by its deny, each said in the history and `watcher.log`; what the run took, from records it appends - an `ultra_effort_exit` `Ultracode not taken`, none after an exit not taken, an enter or none after one taken, a turn at high under max `ran at effort high, not max` with the job's level put right - and `Get-ChatqRunTook` past a sidechain turn, a turn with no level, a 1.1 MB line and a turn that names `ultra_effort_exit` in its words, nothing found nothing said, and with no notice of the run's the scan back - a `compact_boundary` met first off, a notice line over 1 MB across the first stretch back read whole, one past `-Budget` not known with the level still read; a start cancelled before its run went in - neither the job nor the run-state says Ultracode or a level; a new chat's first run `--session-id` and neither, Codex and a fresh chat never judged |
| overlay: recent and unread | in a Claude home of their own: Recent newest first, the open chat, a side transcript, an empty one and ones with no folder, or a folder gone, left out; titled as an open row is - a rename, the sidecar's, Claude's own title, else the first real prompt - with its folder from the head; as many as `overlay.recent` says, and 0 off with nothing read; not built again within the minute, and after it only a transcript that moved read again; the listing kept between builds, and taken again a minute on or when the open chats change; a chat that closes in it at once, not a minute on; a build past its slice stopped with one transcript read, each pass going on from the same listing until the list is whole; a build's time logged only a quarter second past its slice - not one that spent its slice, past 250 ms, but one a folder held there - and a whole build's past 250 ms; a folder asked about once in 3 minutes, timed by `-Now`: a chat whose folder is deleted after it was read gone once that is up, and back with the folder, its transcript not read again; a folder on a share (`\\` or `//`) or a mapped network drive never asked about and listed, and a folder asked about counted against the slice as a read is; `-Print` listing the whole Recent count, the slice lifted; with the Windows panel's pool, 20 built whatever `overlay.recent` says, 0 included - that many of them Recent and the rest `recentMore`, each aged as Recent's are, split again as the count changes with nothing read - and without it none past `overlay.recent`; the macOS collector listing and reading nothing, its snapshot with no Recent; the snapshot's `recent` beside `rows`, not in them, its head the chat just closed, none that is open, and in the view key; unread marked when a chat goes from working or waiting to idle and carried on its row, never for one idle all along; cleared by the open chip only once its child says the open request was written - 0, 25, 40 or 41 - and kept on 10, 15, 20, 21 (a chat Claude Code never lists, which its window offers in a terminal), 26, 42, 43 (the same, its window not brought forward), 30, 50 or no answer in 60 s; cleared by working again, and by its session going; never marked for a chat whose window is in front as it finishes - a VS Code chat by its window's `Code.exe`, a terminal's by what draws it, five hops up - its chain walked in one process snapshot a pass, taken for four chains at once, only at that change and never twice, stopped at `Explorer.EXE` in its own case and at a parent younger than its child (a pid used again), and let go once the process is gone, while one with nothing known in front is marked; a snapshot that failed marks the chat, keeps no chain and is taken again the next time, and one over 250 ms is logged; the snapshot itself from Windows' own list ([Get-ChatProcessTable](src/overlay-data.ps1), no seam), asked for itself too, so a table from the `Win32_Process` query it falls back on fails - this process in it by the name, parent and start `Get-Process` and `Win32_Process` give; none marked or counted off Windows, the pass skipping it; a pass counting them, and the tray tooltip saying `N new`; each of those opens said on the panel from the click - busy - to its end - only 0, a run's live view (16) and a chat never listed (21) in the quiet tone - 26, 42 and 43 warn - a timeout as late - a child that did not start said at once, and the line gone once its time is up |
| console: pure | When - Next first and looked at every 30 s, a draft's old `now` read as Next, in turn neither, at/in a time or why not; search by every word in the title or project, any case, with a cap; the line saying what Send will do - soon, a limit and when it sends, a busy chat, behind others, a new chat, a 529, the watcher starting, Next behind a job running, and a refused login in the CLI's own words or a failed probe, never as "limited until"; each job's words and colour in the queue; the limit the preview names, from a usage window marked limited, else the latest reset of the chats it cut off, and never Claude's for a Codex chat - with nothing read from disk; where it opens - grown from the panel's top-right corner, its right edge and top held, at the size it was left, pushed onto the panel's screen - right, and up - and no bigger than it, a size saved under the window's least raised to it in the screen's pixels before the right edge is held; a size kept in units turned into the screen's pixels at 1.5 and at 1, one an older file kept in pixels taken as it is; `chatconsole` tells a running overlay, or starts one with `-Open console`; the console hotkey's default, `none`, and nonsense refused |
| console: in the panel's window | in its own child `powershell.exe -STA`, run from a file in the sandbox - encoded, the script had passed the 32,767 characters a command line holds - the panel shown off every screen and never activated, then made the console: its window takes clicks and focus and is on the taskbar - `WS_EX_APPWINDOW`, no tool window, no `NOACTIVATE`, not click-through - and is not topmost, grown from the panel's top-right corner, its right edge and top held (pushed up on a stood-in screen 1020 pixels tall), at 980 x 680 by the screen's scale, the buttons' window and the chip hidden; a collector pass meanwhile keeps its snapshot and draws nothing into the window; Esc (raised on the prompt), the header's back button, and a close with the dispatcher run after it, each give the panel back exactly - its place, width, rows, fold, styles, topmost, content, shown - the close leaving the window there; hide, collapse, lock, unlock and stop go back to the panel first, and a panel that was hidden goes back to the tray; there and back from the panel each of those left - collapsed, collapsed and locked, hidden, hidden and unlocked, unlocked - each comes back exactly; a slider not yet at rest kept as the console opens, with the panel's place, and none kept from the console's rect; a width a reload set meanwhile holds the panel's right edge, never past a stood-in screen's left, and the place it leaves is kept in `overlay-state.json`; a size saved under the window's least opens at that least, its right edge at the panel's; its size kept in `console-state.json` - not its place - and used the next time; the chat index read in a runspace of its own and its rows taken once ready (on the window's thread it had cost 250 ms here each time the index changed); its lists hold the cut-off and open chats, and the search narrows them; each chat drawn by the panel's row builder - the same first line as the panel's row for it, where it runs and the unread dot included, compact - and a recent one as the panel's Recent; a click raised on a cut-off chat picks it - the accent's bar on the selection's colour, the others plain, Continue kept - and a chat picked is the one written to; a file dropped and a screenshot pasted (through the clipboard seam) become chips, a folder dropped is turned away; Send makes the job chatq would - first, sent now, both files moved in, the box and the staging folder emptied, the status saying so; a queued prompt being edited outlives a redraw of the queue; Remove clicked through its Border with mouse events of their own times: the first asks - **Remove - sure?** in error's colour, the status saying so - the second half of a double-click (150 ms) is no answer and says so, an ask 5 s old goes back to **Remove** (`Update-ChatConsoleAsks`) and says the job was kept, and a click, then another 1.5 s on, removes - timed by the clicks themselves, so a slow redraw or a pass on the window's thread neither answers for a double-click nor ages a click that came in time; Continue clicked twice queues one; a Codex chat is offered its Sandbox row but no mode or model, and is sent none even when picked before; a theme switch keeps what is typed, and the console's mode; going back keeps the draft in `console-state.json`. In a second child, the whole way round as the user goes it, brought forward through `ChatConsoleFrontSeam`: the console hotkey's verb opens the console and brings it forward, and again only forward; with `ChatConsoleActiveSeam` standing for a console in front, the command's verb (`chatconsole`, the tray) only brings it forward and the hotkey's goes back to the panel as it was; a theme switch keeps the draft typed; Esc, and the panel as it was with the draft saved; the console again, the draft back; a close, and the panel as it was, rows and all; with the folder picker's loop stood in for (`Modal`), a collapse held until it ends and then done, the console key dropped; a panel mid-drag does not become the console; a running Claude job's **Watch in VS Code** beside **Cancel**, through the chip's own `Show-ChatFresh` child, one at a time; a waiting job's **Mode** and **Model** chips in its details, written to its file, the chip filled, said, the first chip giving the chat's own back; **Open in VS Code** on a waiting job, through the same child; the size kept in units with `max` false; **Maximize** filling the stood-in working area with no grip, kept with the size it had, **Restore** giving that back, and a console left maximized opening maximized; a double-click on the header (`ClickCount` 2, set by reflection) maximizing and restoring the same, a press on it while maximized running neither `DragMove` nor the held verbs after it, and one once restored going on to them; and, in a child of its own, a process holding an older `ChatOverlayNative` - compiled first without `ApplyInteractiveStyle` and `DropTopmost` - opening the console through `ChatOverlayNativeNext` and going back to the panel, the types it did not hold yet compiled in one go beside it |
| overlay: Windows panel | in a child `powershell.exe -STA`, built but never shown: 10 rows draw as 8 and `+2 more · 2 idle`, none as one line; both windows shown the way the host shows them, still off every screen, and their styles read after that - WPF sets `WS_EX_APPWINDOW` again as a window shows: the panel a tool window that never activates and lets clicks through, the buttons' window one that takes clicks but never focus, neither with a taskbar button; six buttons in a window of their own, not shown before the panel is - left to right collapse, refresh, settings, minimize, maximize and close, the last three named as on any window, no grip, the arrow cursor on each; minimize a short line, maximize a square, close a cross, each 8 units across; minimize hiding the panel to the tray, maximize opening the console in its place; a press on the bar off its buttons dragging the panel, one on a button never; placed by the code the pointer check runs every 120 ms, on a stood-in screen: the bar in the panel's top strip, 4 units under its top edge and 8 in from its right, as wide as the panel less 16, still there after more passes (fed their own rect where their size belonged, the buttons had jumped between two spots each pass - the blink this caught), and following the panel's width of itself; the bar shown with the panel and gone with it - to the tray and back, out of a full screen's way and back; the panel's rows starting under the bar, 2 units clear of it; the settings box opening above the panel, its foot 4 units over the panel's top edge, the bar where it was; the refresh icon turns while an ask is out and stops after; switching to light redraws the frame and keeps the settings box open; the slider itself moved sets the window's opacity - on the buttons alone, never the bar, its window or the settings box, whose alpha of 1 would drop to nothing and let clicks through, and again once the buttons are made anew - and the next pointer pass saves it to `config.json`; collapsed, one line of counts and usage and a chevron that offers to expand; usage drawn as a line - name, the windows, when it is from - and as bars, the time under the name, once the settings box says so; the pointer check counting the buttons' window, an open box and its gap to the panel in it; the box's side held only while it is open - under the bar at the stood-in screen's top, still there once the panel is dragged down, kept open by the pointer check while a button is held, the bar placed for no box once it shuts it, above the panel once opened again (held for good, it had stayed under until a restart); as it starts, one compile for every C# type the overlay uses ([Initialize-ChatOverlayNative](src/overlay-windows.ps1); [Join-ChatTypeCode](src/overlay-windows.ps1) puts each `using` once and first), the front's left out in a test run, and a compile of them all that fails logged, each type then coming in on its own - the panel's at once, the process list where it is used, Windows' own list and not the query; the rows' rects kept until the panel moves or the rows are drawn anew ([Get-ChatOverlayRowRects](src/overlay-windows.ps1)), and worked out again as the reset time, set in place, takes a line off the usage line of a panel at its cap, whose size stays ([Update-ChatOverlayClock](src/overlay-windows.ps1)); a pointer check far off the panel only marking it off, and the whole check while a slider is not at rest, the bar's place worked out once for both its zone and its placing - again where the bar's width is behind the panel's ([Update-ChatOverlayHover](src/overlay-windows.ps1)); every fifth tick placing the bar over the panel, but not mid-drag or mid-resize |
| overlay: size | in a child `powershell.exe -STA`, shown off every screen, the pointer never read: no resize handle and no grip - collapse first, six in all, the bar's tooltip naming the edges - and the settings and close tooltips; the edges' window shown with the pointer over the panel's rect and 4 units round it, a window that takes clicks but never focus and has no taskbar button, eight parts painted at an alpha of 1, each with its cursor, the line lit along the sides a corner sizes and gone again; folded, no top or bottom, the corners sideways and lighting the side alone; hidden with the bar; the settings box's width and rows sliders, whole numbers, their values beside them; the width slider widening the panel with its right edge held, the rows slider redrawing with `+7 more`; `config.json` given both once they rest; the bottom-left corner dragged left and down - wider, the right edge held, a row a row's height, kept on release with the panel's place; collapsed, the width only; on a screen 500 pixels tall, a panel whose top is 197 pixels down it held to the 303 below that edge - never past the screen's bottom from where it sits - its rows cut to what fits and the rest counted on `+N more`; `reload` taking both from `config.json`, the right edge held; the width slider at rest keeping where the panel's left edge went, for the next start; a `reload` with a slider still moving writing it first, so `config.json` and the panel agree and the shell's other setting is kept; widened by the screen's left edge, held there and growing to the right; fewer chats than rows - dragged down the rows kept never drop, up one off those drawn; the settings box opened after a drag showing what was dragged to, a nudge moving on from there (a width within one unit: at 125% WPF reports 641.6 for 641); width and rows on one row of the box, **Style** full or compact, compact drawing one line a chat and full bringing the prompts back; where a chat runs after its dot - a window for VS Code, `>_` for a terminal, a play triangle for a queued prompt's run, nothing for a job; the right side dragged - wider to the right, the left edge, top and rows where they were; the top dragged up two and a half rows' height - two rows more, the bottom held to the pixel, the rows and the new place kept; by the foot of a screen 500 pixels tall with rows cut, the top edge up a row's height bringing one back, the rows setting kept, the bottom held but for the one unit kept clear of the foot, and `+N more` counting the rest; the room kept under the rows for that line its height as drawn, measured, not 18 units; seven rows fit with the panel at the screen's top, the settings box opening under the bar, over the rows, on the screen |
| overlay: recent panel | in a child `powershell.exe -STA` of its own (with the size checks the `-EncodedCommand` line had passed Windows' 32 K limit): Recent under the open rows - a faint header, a compact line each that the open chip takes, none counted as a row; a row that finished a turn unseen with the accent dot just before its state, the others none; collapsed, no Recent, and the one line saying `1 new`; the chip on a recent line kept through a redraw, and gone when its line goes; the settings box's Recent off, 5 or 10, the one in force filled, kept in `config.json`, and a pass run at once to build it; the height cap from WPF's own scale - the room from the panel's top edge down a stood-in screen 1020 pixels tall, over `TransformToDevice.M11` - and not the window rect's ratio to its width, which a drag can put out of step: a rect that disagrees is passed over; the cap going by the panel's top edge, worked out again as a grip drag is let go higher up a screen 500 pixels tall, more rows drawn at once; dropped at the screen's foot, still one row; `Get-ChatOverlayHeightCap` alone, the working area's own top counted; Recent drawn as `overlay.recent` of the snapshot's `recent` then its `recentMore`, a count set live redrawing unsaved, 0 no header; the bottom edge dragged past every open row bringing Recent lines from the pool, live, and let go saving Recent's count and not `maxRows`, the list split anew and the box's chip lit; back up, the Recent lines going first, then a row, only what changed saved, and Recent taken to none lighting Off; a press let go where it was saving nothing, and down again the open row coming back before the Recent lines; the top edge by the screen's foot bringing back a Recent line the foot cut for a line's travel up, the count kept, the bottom held |
| overlay: life | in a child `powershell.exe -STA`, shown off every screen: a (stood-in) full screen hides the panel with nothing saved and shows it again once it ends; shown by hand during one, kept until it ends and out of the way at the next; hidden to the tray meanwhile, the tray's word holding; a stop marks the close against the sign-in, a restart does not, and with no sign-in known × stops at once and keeps nothing; a changed code stamp restarting it on the timer's pass, but not mid-drag, with the console up, a slider not at rest or out of a full screen's way; the native full-screen call compiled and answering 0 to 7, and its answers read (2, 3 and 4 hold the screen, 0, 1, 5, 6 and 7 do not); × with the sign-in known kept, said in a balloon, the panel gone at once; in its 4 s unlock, collapse, hide, another × and any other balloon dropped, the hotkey taking the close back (shown, unkept, the stop called off, the panel not unlocked), a restart turned into the stop with the close kept, and a `show` command left after the last pass read as the 4 s end and taking it back; the process stopped 4 s on by the close's own timer; the heap compacted by the first pass past its time, not before and never again, and - in a process of its own - 64 MB of big buffers freed between ones still held given back and said in the log; and in another, a tick that threw past its catch every time, in the pointer check's place, its timer set going again after each throw ([Register-ChatOverlayUiCatch](src/overlay-windows.ps1)), and the 1 s timer's place - slower, stopping itself on its second tick - neither held back by those throws nor started again by the five after its stop, the throw said in the log once |
| overlay: macOS panel | `tests/overlay-mac-check.js`: the JXA pulled out of `src/overlay-mac.ps1`, pure ASCII, free of `?.` and `??`, compiled; its countdowns, bars, lines, row cap, prompt toggle, unlocked hint, commands taken once and only when newer than the panel, the menu bar count; the theme chosen from the config and the OS, both looks with every colour, usage as a line a provider ending in its time, or as bars when set; opacity held to 0.3-1; a terminal's chat marked `>_`, one a queued prompt runs in a play triangle, and one in VS Code neither; no unread mark - a row that says unread drawn as any other, the dot being Windows only |

### CI

`.github/workflows/test.yml` runs on `windows-latest`, once under Windows
PowerShell 5.1 and once under PowerShell 7, and fails on any failed check. The
5.1 leg also fails on a non-ASCII byte in any `.ps1` — the runner is en-US, so
the CP949 problem that rule exists for would never show there — and runs the
extension check and the overlay's macOS check with node. It also packs the
extension with `vsce package`, whose `vscode:prepublish` is `extension/build.js`:
a version that is not the script's, a script that is not ASCII, or an SVG in
the listing's README or CHANGELOG fails the run before vsce reads the manifest.

`.github/workflows/publish.yml` calls `test.yml` before it publishes a `v*`
tag, and refuses a tag that is not `package.json`'s version or a version
with no section in `CHANGELOG.md`. That step was run locally against
0.7.0. Run by hand on 2026-09-25, the workflow signed in and the publisher
accepted it (S32 item 7); publishing itself waits for the first tag.

`docs/make-icon.py` makes `extension/icon.png`, the Marketplace icon, from
`docs/icon-cutout.png`, which `docs/cut-icon.py` cuts out of
`docs/icon-source.jpg`: a 256 px square, transparent inside, a 6 px dark
rounded frame, and Charlie outlined in the same 6 px stroke, her head
with its hair two thirds of the icon wide. Checked by eye and by pixel on
2026-09-30, composited on white, #f3f3f3 and #1e1e1e, at 4x and at the
Extensions view's 40 px: the outline as wide as the frame all round - it
covers the drawing's own black edge line - and smooth, with no step of
the cutout's edge showing past it, and no wobble along it (the edge is
redrawn as a curve averaged over `SMOOTH`, 6 icon pixels: 3 left bumps
on the head's right, 8 blunted the hair's tuft), while its sharp turns
stay sharp - both spikes of the bangs at her forehead and the notch at
her shoulder over the gun, as in the cutout (a turn under
`CORNER_ANGLE`, 150 degrees, is averaged over 1.5 px; at 120 and 135
the bangs' lower spike still went round); no dark fringe at its outer edge;
nothing of the drawing outside the frame. It writes the same icon at 48 px
into `src/icon.ps1` too, for the Windows tray and the overlay's windows;
the overlay section draws the tray icon into a NotifyIcon never shown and
reads its pixels back: Charlie at the small-icon size, the state's colour
in the dot at her bottom right, and the dot alone when the icon cannot be
read.

On pwsh 7 `Add-Type` builds libraries only, so the argument-quoting check builds
its echo exe with .NET Framework's `csc.exe` instead. Where neither can, it says
`skip` and is not counted as passed.

### Phone alerts and replies

```powershell
node tests/reply-page-check.js    # docs/reply.html, the page the phone pairs and replies from
```

The PowerShell half is `tests/sections/phone.ps1`, the last section of
`run-tests.ps1`, so it runs in both CI legs; the page check is its own step,
**Reply page check**, on the 5.1 leg. Neither reaches Join, ntfy or GitHub:
Join's push goes to `ChatqJoinSeam`, the reply topic's poll comes from
`ChatqReplyPollSeam`, Join's device list from `ChatqJoinDevicesSeam`, a live
chat's alert to `ChatqLiveSendSeam` instead of the hidden sender, and
`chatnotify -Pair`'s question is answered through `ChatqAskSeam`. The phone
is played by the tests themselves: they pair as the page pairs - a key
sealed to the public key in the pairing push - and seal replies as the page
seals them ([Protect-ChatqReplyMessage](src/phone.ps1)).

**What `phone.ps1` holds:**
- **The wire format** against the fixtures below, byte for byte, and a
  changed byte, the wrong key or junk failing at the MAC or the format.
- **Pairing:** the pairing link carries a 2048-bit public key and nothing
  that answers an alert; an answer is a candidate, never a pairing, until
  its code is confirmed; the same answer twice is one candidate, six
  answers keep the newest five; a code no answer has, an answer for another
  pairing or 30 minutes old, and one after the pairing ended pair nothing;
  confirming kills every alert and candidate from before; `-Pair` again
  kills the old phone at once; pairing with only ntfy over http is refused
  with nothing changed, and goes through your command once it is given the
  link (`-CommandLinks on`), the pairing link in `CHATQ_LINK`; an
  unreadable `replies.json` is put aside as `replies.json.bad`; a pairing
  push that did not go out says so and leaves no pairing waiting.
- **`config.json`'s lock:** another process holding `data/config.lock` and
  saving meanwhile - as a pairing confirmed elsewhere does - and chatnotify
  waits, then keeps what that process wrote; held for good, chatnotify
  saves nothing after 3 s of tries and says `config.json is busy`; the lock
  taken by hand around the overlay's settings save (no code path nests it
  today; the guard is for one that would) only counted, let go with the
  outer one; a pairing confirmed after `config.json`'s pairing changed
  under it is refused, `that pairing was replaced meanwhile`, with no key
  saved and its candidates left as they were.
- **The link:** the Join push carries it with the icon, a `notificationId`
  for the chat and `dismissOnTouch`; the link names the alert, the job and
  the chat, and no key, topic or server; Join and ntfy carry one link; an
  ntfy server that is not https gets none; `-CommandLinks on` saved, said
  and refused for a word other than on or off, the command then a phone
  channel - away it gets the reply link as `CHATQ_LINK`, at the PC it runs
  all the same with none - and the setup window's box for it ticked from
  `config.json`, unticked a change to save; the Join URL stays within 1900
  characters with Hangul in it, dropping the icon, then the title in the
  link, when 20 characters of text do not fit, and never cutting an emoji.
- **Acting on a reply:** a prompt queues a job and skips the `needs input`
  job it answered; the push that answers carries a fresh link; the same
  message again - by the same id, a new id or a new watcher - does nothing;
  a message id with a line break is skipped; no cap by default (keep: a
  `bypassPermissions` chat keeps its mode, a Codex chat its sandbox, no
  limit said; an empty cap and a hand-typed `Keep` are keep, a hand-typed
  `Plan ` is `plan`, a value not on the ladder `acceptEdits`), the mode cap for prompt, retry and allow
  once set, `reply.maxMode` set elsewhere, and Codex's sandbox - the one
  the job would run in brought down to `workspace-write` as the job's own
  `mode`, the chat's `sandbox` left as read, a job given
  `danger-full-access` itself capped on a retry too; the chat's
  config dir kept; links in phone text defused, and an image linked later
  at the PC still taken; skip, stop, status (700 characters, no half emoji),
  ping and an unknown act.
- **Refusals and replays:** junk refused and logged once per stage every 5
  minutes; twelve junk lines before a real reply do not hold it back; a save
  that fails acts on nothing after it and moves polling past nothing; an
  expired alert, a reply 13 hours old and the 21st use each told once, with
  no link and no longer window; the reply state locked by another process,
  then let go - acted on once; spent nonces kept as long as their message
  could be taken, with `reply.hours` above 12 too.
- **Only on what the phone was shown:** an alert keeps its job's runs,
  state and end (`mark`); nothing typed since, a prompt goes; a prompt
  typed at the PC since - nothing queued, the push saying so with a link
  about the chat now, and a prompt from that link going in the mode the PC
  left the chat in, below the old job's own; allow and skip on a job queued
  again at the PC refused, the requeue kept; allow or a prompt on the
  alert about a first stop, once it stopped again, refused; retry on a job
  answered in its chat - refused, the job closed "answered in the chat"; a
  prompt from a started alert while its run goes on and once it ended,
  queued; a stop and a prompt from it once the job ran again, refused and
  nothing cancelled; put back by a limit, a prompt from it still queued;
  stopped on a question since, refused and left waiting; a prompt typed
  at the PC before the job's own run began, seen while it runs; one
  followed by 80 tool results and 400 KB, seen; a job closed as answered
  in its chat, the prompt after it in the chat's own mode; an alert keeps
  its chat's transcript length and a job's end its own; a prompt queued at
  the PC while Claude worked, one with a 400 KB pasted image, and one
  followed by a compaction writing old records again, each seen; a
  background task's notice not; the phone's own first prompt, once run,
  no bar to a second; a person typing during the job's own run, seen; an alert whose words are older than its push
  (`-SeenAt`) judged from then; a prompt sealed 31 minutes before it came
  and a status 11, too old; a prompt 29 minutes old, queued; a Codex
  rollout read the same - its AGENTS.md preamble, environment block, event
  and compaction records not the chat going on, a prompt typed in the panel
  since is, from the length kept or back from the end, and a Codex job
  waiting on input answered by it; a Codex line too long to keep judged by
  how its text starts - a pasted log typed, the environment block, the
  preamble and the IDE's wrapper with no request not.
- **The watcher:** a listening watcher's saved limits are not trusted; it
  listens while a window is open, holds nothing awake, writes the board
  coming in and going out, and leaves when the window shuts; one started as
  the last left, but never over a stop; `chatqrun -Stop` shuts the window.
- **Chats you run yourself,** driven through
  [Update-ChatqLiveAlerts](src/phone.ps1) with registry entries made in the
  test and the clock moved by hand: nothing on the first pass; `needs input`
  at 20 s and not at 19; `done` 5 s after busy to idle, `asks:` and all; once
  per chat and event every 3 minutes; a phone-made chat Claude has not
  titled named by the title its job holds, never its prompt, and by
  Claude's own once there; nothing at the PC, sent once away
  while still news and never later; sent away with the chat's window in
  front; nothing for the watcher's own run or a non-interactive entry, nor for a
  `claude -p` registered `interactive` with an `sdk-*` entrypoint;
  `-LiveAlerts off`, no phone channel and `-Events` each silence it; the
  status line naming no "older copy" of a running overlay, which restarts
  on new code itself, and saying one not running; the outbox sent through
  Join as about the chat and deleted, one 31 minutes old dropped; the link
  saying `j=live`; a prompt to it capped, and while the chat still waits on
  a prompt at the PC, a push saying it goes once that is answered; retry on
  it refused.

**What `reply-page-check.js` holds:** it lifts the page's two marked blocks
out - the crypto between `/* chatq-crypto-begin */` and
`/* chatq-crypto-end */`, the logic between the `chatq-logic` markers - runs
them under Node's WebCrypto, and holds them to the fixtures: the reply
vector byte for byte, random replies that Node opens as the watcher does, a
pairing sealed by the page that Node's `privateDecrypt` opens with the
fixture's key, a payload over RSA-OAEP's 190 bytes refused, and the code for
the fixture's key and 300 random ones. Then the links (a v1 link, which held
a key, refused; `k`, `s` and `t` in an alert link never read), the buttons
per event and for `j=live`, every act one the watcher knows, and the 2,900
byte limit. Then what the page must never do: a byte that is not ASCII, a
URL of its own, a `<script src>`, anything CSS could load, a CSP that allows
more than inline code and https posts, a referrer, a request but one
`fetch`, a header but `Content-Type: text/plain`. Last, the whole page under
a small fake DOM and an in-memory IndexedDB: the unpaired card, pairing -
nothing kept on the phone until the POST went through, the key kept as a
CryptoKey that will not export, the code shown - the replace card's second
tap, the `localStorage` fallback and its move into IndexedDB, drafts per
alert, **Try again** posting the very same sealed message, and a new link
while a POST is out. `docs/.nojekyll` is checked too.

**The fixtures**, made by Node's own crypto and neither implementation, so
a mistake the two share cannot hide:
- `tests/fixtures/reply-vector.json`, from
  `node tests/fixtures/make-reply-vector.js`: one reply sealed with fixed
  inputs - the key bytes `0x00..0x1f`, alert id `abcdefghij`, IV bytes
  `0x10..0x1f`, and a payload with two Hangul syllables fed verbatim. The
  file is kept ASCII, the Hangul as JSON escapes, so 5.1 reads it the same
  on any code page.
- `tests/fixtures/pair-vector.json`, from
  `node tests/fixtures/make-pair-vector.js`: an RSA-2048 key, its private
  half in the shape .NET's `RSAParameters` wants, one pairing message and
  the code of its key. The key is made once and checked in: a run keeps it,
  and keeps the message while it still opens to the payload, since OAEP is
  random and each side proves itself by decrypting, not by comparing bytes.
  `--new-key` makes a new key, which the PowerShell side then reads too.

Run either only when the wire format changes, and commit what it writes.

**Not covered by the run:** the setup window past its boxes' load and the
changes Save would write - the VS Code command that opens it is checked
with PowerShell stood in for - and everything
past the seams: Join, ntfy.sh, GitHub Pages, a phone's browser, a PC that
sleeps, and a real overlay sending a live alert.

The phone features went through three reviews before release - 28, 17 and
6 findings, some found by two lenses - covering the crypto and what each
server sees, the reply state and the watcher, the pairing, the setup window
and the page, and the live alerts. Their fixes are held by `phone.ps1` and
`reply-page-check.js` where a test can hold them; what was left on purpose
is in FUTURE_WORK.md.

### Auto-continue

`tests/sections/auto-continue.ps1`, the section before `host-work.ps1`, for the automatic
mode (`autoContinue: "on"`; the ask is `reset-ask.ps1`'s), with chats of its
own in a project folder of its own - cut off minutes ago, their limit
records written as Claude Code writes them - and registry entries made in
the test and handed in. It puts back the config, `auto-continue.json`, the
markers, and the jobs and chats it made.

| area | checks |
|---|---|
| the setting | only `"on"` is on, `true` still ask; `Set-ChatqAutoContinue -Value on` writes `since` as it turns on, not again while it stays on; `auto-continue.json` changed under its lock - held by another writer, a change waits about 3 s and fails unsaved |
| states | `Get-ChatqAutoState` for every state, the row's short words and the long ones exact: ready, armed, due (with the queue's time, a VS Code hold's reason, `after #3`), armed behind a continue that waits for the same reset (`after #11`) and behind a run in progress (the reset), running, off - its words the plain `cut off - resets 13:00`, and with the switch off or ask every row's state `off` alone ([Get-ChatqAutoRowStates](src/auto-continue.ps1)), so a cut-off row keeps its old words with a **continue** chip, and a 529 row neither, nor one a terminal's claude holds (no state, so no chip, in ask mode or with another chat always) - and ask, which says it asks - always with the switch off, never, a terminal's entry and any entry not a panel's, a panel's no bar, stopped on its own cut-off only, declined - and a later cut-off with the same reset as one whose continue was removed or that the ask left, never one with another reset or after a failure - failed by its job or by its marker's error, the reset ask's markers read as this mode's (leave declined, a continue whose job failed failed), far (before `since`, over 12 h, a reset 30 h out, no `since` yet), late, a 529 with the switch off or on Ask as it was, and a 529 with it on - ready, due (`#12 auto · 529`, when Claude is back), late 30 min after the 529 itself, far, declined for this 529, a terminal's, always with the switch off |
| the scan | a cut-off from before the switch turned on is far; a scan that finds no `since` writes it; a closed chat queued - kind continue, rule auto, `auto`, its cut-off's uuid, the chat's own mode and model - its marker in the ask's shape (`answer continue`, `seq`) naming the job and `jobs.log` saying `continue, auto - limit ..., resets ...`; nothing more on a second scan; a removed continue never back for that cut-off, a new uuid queued again; one the ask left not queued; a panel's chat held to the reset plus 5 minutes, its time reading `(open in VS Code)`; a terminal's, or a print run's, not queued, then queued once it is gone, said once in the log; a 529 queued - its marker's `why` `overloaded`, no `resetsAt`, `jobs.log` saying `auto - 529 HH:mm` - its job's lane put in an outage before the probe with no alert, once, held while the status page says down, let go when it says operational and 16 minutes after the 529, none after a probe said allowed since the 529 nor for a limit's job or one not auto, none for a chat with a newer turn (retried in the panel) - the probe going at once - and one started before that retry ended at the next check and said in `watcher.log`, one whose continue was removed ended while one a probe met a 529 in since stays with no second alert, a panel's chat held to the 529 plus 5 minutes, one first seen 36 minutes after the 529 not queued, a removed one declined; another config dir not scanned; the switch off or ask, always with it off, on again writing `since` anew, never removing the continue; a job you queued already leaves no marker; late and a weekly reset not queued; a marker made once - the second exclusive create refused, a name no key has refused - one with an error never tried again, one over 8 days deleted; a cut-off's id past its chat and its marker's path; two scans at once in two runspaces queue one |
| the watcher | the hold till 5 minutes past the reset, logged; a terminal holding the chat as it is about to run - skipped, no alert; a chat gone - skipped, no alert, while a job you queued still fails and alerts; the streak - a first auto continue that gives up, a streak of 1 on the cut-off it left, the next queued, the second in a row alerting `auto-continue stopped`, the chat stopped and not queued again; a later cut-off ready, always again or one that finished starting it over; the started alert saying `auto-continue`; the watcher's own scan queuing with no overlay, in the loop every 5 minutes, and nothing with the switch on ask |
| `chatq -AutoContinue` | off and on and what each prints - the continues kept and how to drop one, the chats set to always; on with a title, never with none, and with `-Prompt`, refused; `-WhatIf` saving nothing; never dropping the chat's auto continue and keeping your job; a job number; always and default; a Codex chat refused; the cheat sheet and `Get-Help` |
| `chatqlist`, the board, `chatrm` | nothing watching said in yellow, the switch and its counts with a watcher, off and how to turn it on, ask with no overlay said; `continue (auto)`; a cut-off tagged `never auto`; the board's column and `picked by auto`; `chatrm` dropping an auto continue and saying so, a job you queued still keeping the chat |
| the overlay | a `-Peek` pass and a context no host made queue nothing; the host's pass queues, a closed chat keeping one orange row with its job and the job no row of its own, an open chat's own row orange with the job on it, held for VS Code, the counts saying cut off and auto, the header's switch, no reset ask while it is on; the log line; `auto-on`, `auto-ask` and `auto-off` from `overlay-cmd` setting the switch, reading the config again and not handed on; switched to ask with an auto continue kept, the job a row of its own; `overlay.cutOff` false drawing no rows while the scan still runs; the chips each state gets, don't continue's tooltip; placed clear of the row's words, open alone flush right; a chip acting only when pressed and released on it, the banner's answers the same way; the chip's don't continue and continue, the unread dot left, a second continue before the redraw queuing nothing; `-Print` in full |
| the console, the phone | an auto job's words and detail; the live alert's words; a live chat cut off with a continue queued sends `limited`, priority 0, about that job, one with none `done` and why not; the outbox sending it about the job; skip on the phone answering in its own words, the marker kept; no act turns auto-continue on or off |
| the window (STA) | the settings box's seventh row - Continue, Ask, Leave - its chips and tooltips; Leave clicked keeping it off in `config.json`, the box showing it; Continue chosen saying what it does once; the tray item's check following the file, its toggle between on and ask through `Invoke-ChatOverlayVerb`, held while the console runs a loop of its own; with the panel at the screen's top the buttons and seven-row box below it, on the screen; the chip window over an auto row - don't continue and open, left of the row's words, the state in the tooltip; a press on one released on the other doing nothing, the same acting, an unarmed chip taking nothing; a plain row's open still flush right; a row with no mark keeping an empty slot; collapsed, `3 cut off (1 auto)` |

The node checks carry the rest: `reply-page-check.js` - `limited` with a
continue queued (`j=queued`) offers Send, **Don't continue** (`skip`, two
taps) and Status, and `ACTS` is unchanged; `extension-check.js` - the
palette command in `package.json` and registered, Continue, Ask and Leave
through the loader and the script's line checked, a failure said, and
`message()`'s words for a run auto-continue made; `overlay-mac-check.js` -
the menu item, checked only while the snapshot says on, and the verb a click
writes; the reset ask's items writing `ask-go <keys>` for the keys drawn,
`none` when none were. `job-core.ps1`'s field list has `auto`, `cutUuid`
and `deferWhy`.

### A new version, and the chats a reload stops

What 0.9.0 adds so that an update of chatq, or a reload chatq asks for,
does not end the window's chats by surprise
([safe-restart.js](extension/safe-restart.js),
[Get-ChatHostWork](src/host-work.ps1)). With it, 708 checks pass in
`run-tests.ps1` under both Windows PowerShell 5.1 and PowerShell 7, 270
in `extension-check.js`, 195 in `reply-page-check.js` and 23 in
`overlay-mac-check.js`.

**In the self-test.** `run-tests.ps1`'s section *the chats one window
runs* (`tests/sections/host-work.ps1`) builds a Claude home of its own,
named in Hangul, with registry files and transcripts, and stands in for
the process list (`ChatProcessTableSeam`): two windows' extension hosts
under one `Code.exe`, and a terminal's shell. `Get-ChatHostWork` for one
host lists only its chats - never the other window's, nor the terminal's -
and judges them as `Test-ChatIdle` does: a turn, a prompt, a workflow out
while Claude calls the chat idle, and idle; the workflow's
`<task-notification>` makes it idle again; a print-mode claude going into
an idle chat, or a chatq job running into it, holds it as `run` - and a
chatq job running into a chat no process of the window holds any more is
listed as a `run` of its own, with no pids, and so is a chat whose idle
process in that window was ended, or left as a handover closed its tab
(`Add-ChatIdleEnded`, in `data/idle-ended.json`) while a `claude -p` registered as `interactive`,
`sdk-cli` goes into it - never for another window, with no such run, or
once the host's pid is a process of another start time; the notes kept
one per chat and window, a host gone or a note 8 days old dropped as the
next is written, a start not known kept by its pid; a
transcript whose last turn was written this minute is said apart
(`Written`) - by the turn's own time, not the file's date, which a
record with no turn in it moves (`Get-ChatLastWritten`: the last
`"timestamp"` in the file's last 64 KB, read mid-line, one inside a
message's text never taken, no time → the date, and never later than it); with no process
list (off Windows) nothing is known and every VS Code chat is listed; a
host with no chats, or a home with no registry, lists none. The line the
extension reads is ASCII JSON, the Hangul path escaped and read back
whole, and an empty list is `[]`. Last, the extension's own command runs
in a PowerShell of its own against the sandbox's copy of the scripts and
gives back one line of JSON for that host. Its check names how long that
took: on 2026-09-27, with two suites running at once, 3.2 s under Windows
PowerShell 5.1 and 7.0 s under PowerShell 7 - most of it starting
PowerShell and loading the scripts. That is the price of one look, paid
once for the notice and every 25 seconds while a reload waits. The child
gets the section's stand-ins for the process table and the registry's
life, set after the scripts load - a host 4343 whose one `claude` has a
turn in flight - so the note it leaves in `data/host-work/4343.json`,
naming that chat, can only be the command's own doing.

The next section, *the chats a reload stopped*, keeps that home and
proves what a reload leaves behind: a note
([Save-ChatHostWorkNote](src/host-work.ps1)) with the host, its start and
the chats at work - never an idle one or a run - removed when the
window's chats cannot be told apart; and the overlay's look
([Get-ChatRestartCutOffs](src/host-work.ps1)) with the host's life
standing in (`ChatHostAliveSeam`). The host alive → nothing. The host
gone → the chat cut off mid-`tool_use` and the one whose workflow never
reported are offered, not the one that finished; the note pruned to
those two with `goneAt`. The overlay's own pass
([Invoke-ChatOverlayCycle](src/overlay-data.ps1)) over that note, a usage
stand-in under the limit: under `autoContinue` `ask` both chats join its
ask and its orange rows (`cut off - VS Code restarted`), `header.ask`
counts them as `restart`, its note says `VS Code restarted`, and the tray
balloon is titled so; under `on` it still asks, about those two alone.
[Complete-ChatqResetAsk](src/overlay-data.ps1)'s continue on that ask
makes a `restart` prompt job each, marked `why: restart`, said with no
limit to wait for. The console's Continue on a restart's row
([Invoke-ChatConsoleContinue](src/console.ps1), its window's parts
standing in) queues the prompt that names the workflow. Leave's tooltip
says a limit's rows stay orange and a restart's go, and Continue's says a
restart's prompt ([Format-ChatqAskLeaveTip](src/queue.ps1),
[Format-ChatqContinueTip](src/queue.ps1)). The reset ask takes them at once, alone or with
a limit's chats, worded `VS Code restarted`; `-RestartOnly` for the
automatic mode; nothing while limited. Auto-continue's state for one is
`restart`, even switched on and set to always. **Continue** makes one
`prompt` job, rule `restart`, in the chat's own mode, with the cut-off's
uuid, ahead of an older prompt and never twice; the watcher skips it once
the chat went on. An answered chat is not offered again; a busy one is
kept for later; a tab the reload brought back, idle, is still offered,
but not a chat another window held all along, nor one with a job; a chat
written after the host went is no cut-off, and an empty note goes. A
note over 12 hours old, and a look that finds all idle, remove the note.
A process from before the note, seen once, only marks its chat
(`heldAt`): the chat is offered once that process is gone, and dropped
when a look a minute on still finds one. A chat whose last message
cannot be read is never offered and stays in the note. Any look's save
removes another host's note past its 12 hours, never a fresh one.
`Test-ChatHostAlive` is checked against this process and its start, and
`Test-ChatRestartMid` on a tool_use, a prompt, a tool's result, a
finished answer, a turn you stopped and a slash command's records.

`tests/extension-check.js` stands in for the script's verdict
(`_hostWork`, nothing working unless a check says so - no check ever
starts that PowerShell), the clock, the status bar, VS Code's
`extensions.json` in a sandbox folder, `onDidChange`, the registry's last
word before the reload (`_movedSince`) and the reload command: another
version, newer or older, said by its version and the same one again only
by another install time; the entry found by id in
any case; the verdict parsed past noise, a field of the wrong kind none;
the command naming this host's pid and the Claude home quoted, and
ending with the note, this host's start in it (`_hostStart`, 0 where
none is known), only where the scripts have `Save-ChatHostWorkNote`, and
testing for `Get-ChatHostWork` first - scripts too old for it said as
that, else the error with stderr's first line; a
background-only chat working, one only written this minute working unless
it is the run's own, and named `(written in the last minute)`; a transcript
written since the look by its last turn's time (`_lastWritten`), one only
touched since not, one with no time in it by its date; the reload asked
about listed for the overlay in `data/reload-pending/<pid>.json` - in a
sandbox folder (`_reloadIo`), never the tool folder's - with the host's
pid and start, its window and the ask's id, state and line; the overlay's
**reload** is the notice's own button and reloads, both files gone; its
**later** takes the ask it answered, and those before it, off - one asked
since, not yet on the overlay then, stays - the notice still answering;
the notice's own **Reload anyway**, clicked after the overlay answered
it, still reloads;
an answer to no open ask, over ten minutes old or of no known word does
nothing and is removed; at activation the files of hosts gone swept, a
live one's kept; at activation the running version and its folder's
install time, and both the event and the file listened to; a newer
version with nothing working → the short notice, **Later** reloads
nothing and that version is not said again; the same version installed
again with two chats working → the long notice naming both, the
background one marked, and **Reload now** runs
`workbench.action.reloadWindow` - never `restartExtensionHost`, which
loads nothing new; a look that fails → the long notice, never the short
one; **Reload the window** clicked once a chat began to work → no reload,
the long notice instead; still idle → the reload; a reload refused → said,
with **Try again**, which reloads; **Reload when they're idle** → a
status-bar item that cancels, counting the chats; it waits through
background-only work, a queued run going in, a chat only written, a look
that failed, and reloads only after 60 s of idle looks straight - not at
50 s, nor when the registry read once more says a chat moved since the
look - and takes its item away; the registry's last word itself: a chat
of the look busy now, a VS Code claude started since, a transcript
written since, but not a terminal's claude; cancelled → said, nothing
reloads after; a newer install while waiting → no second notice. The
reload guard: by itself with a background-only chat working → said with
its title and not reloaded; a look that fails → not reloaded by itself,
reloaded on a click; the chat a run just wrote left out; **Reload
anyway** reloads - within a minute of its warning at once, an hour on
only once a look finds nothing working past the chat the warning named;
pwsh off Windows found once for the host's life; and end to end from
the request file, `autoReload` after a delete and a queued run's reload
by itself are both held while a chat of the window works, a quiet one
still reloads, and a plain **Reload** clicked is asked again.

### Usage heads-ups, quiet hours, voice and text from Tasker

`tests/sections/phone-extras.ps1`, after `phone.ps1`, holds
[src/phone-extras.ps1](src/phone-extras.ps1) with the same seams - Join's
push to a seam of its own, the outbox to `ChatqLiveSendSeam` - and one more:
`$script:ChatqClockSeam`, the time quiet hours are judged at in place of
`Get-Date`. A phone is paired by writing a key into `config.json`.
- **Usage heads-ups:** thresholds read and refused; 89% nothing, 90% one
  alert with the reset and the queue, 91% nothing; two crossed at once, one
  alert and both recorded; a new window alerts again; stale, 31 minutes old,
  limited, 100%, Copilot and a month never; `usage.alerts` off takes no
  lock, and a figure that stays over its threshold takes it only once. The
  dedup file: a held lock throws, pruning by reset and by age, 200 kept.
- **Soon and reset,** through
  [Send-ChatqUsageSoon](src/phone-extras.ps1) and
  [Send-ChatqUsageReset](src/phone-extras.ps1) with the queue stood in for:
  one soon alert, jobless with `w=1` and `usage = soon` in the registry, and
  none for a short wait, the 15-minute guess, nothing queued, a failed probe
  or a job held past the reset; the loop woken 10 minutes before a reset;
  the block's start saved and restored over a handoff; the reset alert once,
  from [Confirm-ChatqAllowed](src/watcher.ps1) too, not with one queued.
- **Send now:** the wake file on a soon alert, the second within 2 minutes
  and nothing queued each said, a threshold or done alert refused - and the
  whole way, a sealed `wake` answering the soon alert's own link.
- **Quiet hours:** the window across midnight and by day, bad stored values
  read as off; held, urgent, `-Loud`, at the PC and not a phone event;
  `CHATQ_QUIET` for your command; the summary before the next alert, 200
  kept, 700 characters, `(yesterday)`, a failed push put back and not
  retried for 5 minutes, a dead sender's claim taken back, a second sender
  finding nothing, a hold that cannot be written sent instead, `-QuietHours
  off` sending at once, and the watcher, the outbox and the overlay each
  looking only when something is held.
- **Voice:** `say` and `language` in the Join URL, English and Korean,
  forced languages, 40 characters of title; never in quiet hours, `-Quick`,
  a reply, the pairing push or the summary; `say` dropped before the icon
  when the URL is over budget; `-Say` refused without Join.
- **The setup window,** in an STA Windows PowerShell of its own and never
  shown: the new controls filled from `config.json`, each moving the unsaved
  check, Save's changes, the two errors that block it, the times kept while
  quiet hours are off, read aloud only for an event the phone gets.

`tests/reply-page-check.js` holds the page's half: `w=1` and **Send now**
(act `wake`); `text=` read, `+` as a space, Hangul and emoji, CRLF, control
characters, a broken escape that leaves the link good, 16,000 characters;
the tab's kept fragment never carrying the text; `prefill`'s three cases;
the page filling the box, saving the draft and sending nothing until
**Send**; and a static check that `press(`, `deliver(` and `seal(` are
called only from a click or keydown handler, or from `press` itself.

### Permissions from the phone

`tests/sections/permit.ps1` runs after `phone.ps1` and `phone-extras.ps1`, on both CI legs, for
[src/permit.ps1](src/permit.ps1) and
[phone-permit-spec.md](docs/phone-permit-spec.md). The seams are the
phone's: Join to `ChatqJoinSeam`, the reply topic from
`ChatqReplyPollSeam`, a phone key made in the test that seals answers as
the page does. `$script:ChatqPermitWaitSeconds` shortens the bridge's
deadline to seconds, and `$script:ChatqPermitExeSeam` points the launch
at another PowerShell, or at nothing. No model, no network.

**What it holds:**
- **The MCP framing, in process:** `initialize` echoing a known protocol
  version and answering `2025-06-18` to an unknown one, `tools/list` with
  `decide` alone, `ping`, an unknown method, a notification, another tool,
  and [Get-ChatqJsonRaw](src/permit.ps1) on braces and quotes inside
  strings, `\"`, Hangul and nesting.
- **The rules** ([Get-ChatqPermitRule](src/permit.ps1)), table-driven:
  a question, the plan, tools listed and not (an `mcp__x__*` pattern too),
  chatq's `data/`, a Claude settings file in either slash and any case, a
  command naming `data/`, the 11th ask, the 4th pending, after a miss - and
  `data/` and the settings files by every other name: Git Bash's `/c/...`,
  `\\?\`, `\\localhost\c$`, `::$DATA`, a trailing dot, a relative
  `data\` run from chatq's own folder, any command run inside `data/`, and
  the 8.3 short name where the sandbox's volume keeps one; a `HEAD~1` and
  a URL with `/data/` in it still asked.
- **What the phone is shown:** redaction, the 8-line and 400-character
  cut that never halves a Hangul pair, an edit's line counts, a write's
  size, a fetch's URL, and the push text naming no command; a value with
  `$( )`, a backtick, `|` or `;` shown whole; `x=1` on a card whose call
  was redacted or cut, none on one shown whole; a write to a UNC path said
  as a network path and never looked at.
- **The pushes a run waits on:** a `-Quick` push with held alerts waiting
  goes without sending their summary first, the next ordinary alert sends
  it; a permission request whose entry cannot be made (`replies.lock`
  held) sends no push at all, and says why.
- **The card** against `tests/fixtures/card-vector.json`, made by
  `node tests/fixtures/make-card-vector.js` with Node's own crypto: sealed
  byte for byte, a changed byte or another key failing, the digest, and
  the page's sealed permit carrying `h`. A 600-byte Hangul card keeps a
  Join URL within 1900 characters with `r=` whole.
- **The bridge as a real child** of the test, which plays claude over
  redirected stdio: Windows PowerShell first, then pwsh 7 when there is one
  (the PowerShell running the tests when it is 7). The first byte on stdout
  is `{`; a call writes `<rid>.req.json` with the input as sent; a sealed
  permit is `{"behavior":"allow"}` within 4 s; a refuse carries its note;
  a declined request says why; two pending are answered in reverse order
  to their own ids, with a ping answered meanwhile; a cancelled call is
  marked withdrawn; an answer copied from another request, one naming
  another request and an unsealed one are never believed, and deny at the
  deadline; the next call is then denied at once; stdin closed, exit 0.
  The run prints how long `initialize` took. Alone that is about a
  second; with both PowerShells' suites running at once it was near 7 s,
  still well inside claude's 30 s `MCP_TIMEOUT`. `initialize` goes behind
  a UTF-8 byte-order mark on purpose: a .NET Framework parent whose
  console input is UTF-8 writes one into a child's stdin - a GitHub
  runner's Windows PowerShell does, which left `initialize` unanswered on
  CI until [Read-ChatqMcpLine](src/permit.ps1) skipped it. The test drains
  the bridge's stderr as claude does.
- **End to end** through `fake-agent.ps1`'s `FAKE_PERMIT`, which reads
  `--mcp-config` and starts the bridge as claude would, and
  `FAKE_PERMIT_SELF`: the argv and `MCP_TOOL_TIMEOUT`, the push and its
  card, allowed (done), refused with a note (done, `you denied ...`), no
  answer (`needs input ... - no answer from the phone`), `already answered`
  and `too late`, the model calling `decide` itself (declined, no push), a
  stop while waiting (the bridge gone, the entry `gone`, the folder
  deleted), today's argv byte for byte for every case that never asks, and
  a bridge that does not start - requeued once with `permitOff`, the retry
  today's run, `chatnotify` saying so until a bridge comes up. A request
  claude withdrew is never pushed, and an open one's alert turns `gone`. A
  request whose input was changed on disk after it was asked, its digest
  left, is declined and never pushed.
- **The registry, the outcome, the settings and the window:** the `permit`
  block through `replies.json` on either PowerShell, the hourly cap, a
  refuse note's 500 characters, [Get-ChatqClaudeOutcome](src/queue.ps1)'s
  `-Refused` and `-NoAnswer`, `-PermitWait` and `-PermitTools` refused
  whole, and the setup window's box built off screen, never shown.

`reply-page-check.js` holds the page's half: the card vector opened with
the kept CryptoKey, `buildPayload` with and without `h`, the buttons for a
`permission` alert, no Allow without a card or past its deadline, and under
the fake DOM the second-tap guard on Allow, a note kept per alert and the
too-late card, and a card with `x` saying not all of the call is shown.

### Claude's questions from the phone

`tests/sections/ask.ps1` runs after `phone-board.ps1`, on both CI legs, for
[src/ask.ps1](src/ask.ps1), [src/ask-hook.ps1](src/ask-hook.ps1) and
[phone-ask-spec.md](docs/phone-ask-spec.md). The seams are the phone's, as
for permits: a phone key written in the test, Join and the down topic to
`ChatqJoinSeam` and `ChatqDownSeam`, the reply topic from
`ChatqReplyPollSeam`. `CHATQ_ASK_WAIT_SECONDS` and `CHATQ_ASK_STEP_MS`
shorten the hook's deadline and its look, for tests only;
`$script:ChatqAskCliSeam` stands in for the `claude plugin` commands and
`$script:ChatqAskAliveSeam` for the hook's process test. No model, no
network; the config and `data/ask/` are put back at the end.

**What it holds:**
- **The pending call** ([Get-ChatqPendingAsk](src/ask.ps1)) on synthetic
  transcripts: pending, answered, a side chain's skipped, a prompt typed
  after it, two questions, Hangul in every field, five options shown as four
  with a count of the rest, a 2500-character description cut at 2000 with no
  split pair, more than 16 KB cut longest first with `cut` set, a tail
  beginning mid-line, the chat's mode from the newest record, the cache hit.
  [Test-ChatqAskSame](src/ask.ps1): a changed label or description, or a
  swapped pair of options, is not the same.
- **Where it shows:** [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1) with
  `-Asks` gives the `open` row's `ask` and `a question: <header>`, and
  without it is byte for byte as before; [Send-ChatqReplyText](src/phone-down.ps1)
  for a live `needs input` carries `ask` with `parts` on, and with whole
  answers off carries `ask` alone, counted `other`; with no question, the
  old refusal; `-Again` carries it too.
- **The answer as the hook believes it** ([Test-ChatqAskAnswer](src/ask.ps1)),
  sealed as the page seals it on both wires: valid; the wrong `rid` or `qh`,
  a `ts` outside the window, a reused nonce, an unsealed `{"act":"answer"}`
  and another key each refused; an index out of range, two indexes on a
  single choice and a multiple choice with nothing chosen refused; Other
  text cleaned of control characters and cut at 500.
  [New-ChatqAskDecision](src/ask.ps1): a label, `Red, Blue`, Other alone,
  labels then Other; `questionsRaw` spliced byte for byte with Hangul,
  `<>&'` and `\"` in it; `<>&'` in `answers` written as themselves under
  Windows PowerShell; the line parses as JSON.
- **The hook as a real child** of the test ([Start-ChatqAskHook](src/ask.ps1)
  through `ask-hook.ps1`), which plays claude: a sandbox `CLAUDE_CONFIG_DIR`
  holds a registry entry for a started `node` child and a transcript, and
  the `PermissionRequest` stdin goes in behind a byte-order mark. Stdout is
  empty until an answer; the request file appears, Hangul intact; a valid
  sealed `.ans.json` gives the decision within 2 s and exit 0; a forged one
  gives nothing and the hook keeps waiting; a rewritten `.req.json` changes
  neither the check nor the decision. It leaves without output when the
  transcript gains the `tool_result` (`pc`), when the node child is killed
  (`gone`) and at the deadline (`timeout`). The gates: `bypassPermissions`
  over a cap of `acceptEdits` and a mode raised just before the answer are
  `declined` `mode`; a terminal's `entrypoint` is `declined` `term`; no
  registry entry, or `ask.on` off, writes nothing; a load failure still
  exits 0 with a line in `ask.log`. The same run goes once under pwsh 7
  when there is one.
- **The view and the matching** ([Get-ChatqAskView](src/ask.ps1)): `can`
  with an open request whose hook is alive; `late` when the pid is dead, or
  alive but another process's; each declined `why`; `hook` with no request;
  a request naming another transcript or other questions never shown; of
  two matches, the newest.
- **The acts** through `Invoke-ChatqReplyPoll -Force`: `answer` from an
  alert and from the board writes `.ans.json` with the message as posted and
  answers with the push or the ack; every refusal in the spec's table; a
  board `answer` whose `id` does not match its handle refused; `answer`
  counted as a `change`.
- **Landed or not** ([Test-ChatqAskLanded](src/ask.ps1) `-Now`): `did not
  take` when no `tool_result` comes, silence when the answers match, a log
  line only when the PC's answer won, `went on without your answer` when the
  result has no `answers`.
- **Tidying and installing:** a dead open request becomes `gone` and is not
  deleted, nothing goes before an hour past `until`, the hourly count
  includes settled requests; [Install-ChatqAskHook](src/ask.ps1) through the
  CLI seam - the three plugin files, the version's hash, each `claude plugin`
  argv in order (remove then add when the marketplace's source differs,
  update when the version changed); a failed install leaves `ask.on`; `-Manual`
  prints the hook and runs nothing; [Get-ChatqAskHookState](src/ask.ps1) finds
  a hand-added hook; `chatuninstall -All` stops when `-Ask off` fails.

`reply-page-check.js` and `board-page-check.js` hold the page's half: `askView`
for a read-only card (`Answer it at the PC.`), single, multiple, Other,
`more`, `cut`, each `why` and `late` after `until`, Send off until every
question has an answer; the answer wire against `tests/fixtures/ask-vector.json`
(made by `node tests/fixtures/make-ask-vector.js`, opened in PowerShell by
`Test-ChatqAskAnswer`), with `reply-vector.json` and `compose-vector.json`
unchanged; `answer` in both `ACTS` lists; a draft kept per `rid`; a `reply`
body with empty `parts` and an `ask` showing the card alone.

### The phone board and the whole answer

```powershell
node tests/board-page-check.js    # docs/reply.html's board, whole answer and down channel
```

The PowerShell half is `tests/sections/phone-board.ps1`, after `phone.ps1`,
`phone-extras.ps1` and `permit.ps1` (75 checks, one of them the 0.9.0
merge's: a link made again after the whole answer keeps a soon alert's
`w=1` and a permission card's `r=`); the page check (86) is its own CI step, **Board
page check**, on the 5.1 leg. Nothing reaches ntfy.sh: the down topic's
POST and PUT go to `ChatqDownSeam` - which the sandbox sets from the first
section on, so an alert any section sends with a phone paired lands there
too - and the phone's messages come through `ChatqReplyPollSeam`, sealed
as the page seals them
([Protect-ChatqComposeMessage](src/phone-down.ps1)).

**What `phone-board.ps1` holds:**
- **The wire format** against the two fixtures below, both ways: the down
  topic of D, a down message sealed here from Node's deflate bytes equal to
  Node's byte for byte, Node's opened here, the compose message sealed here
  equal to Node's; a changed byte is the MAC; a `chatq3c` under an alert's
  key and a `chatq1` under a phone key fail; our own raw deflate
  round-trips Hangul, nothing and 1 MB, and a deflate bomb stops at 4 MB.
- **The whole answer:** the last turn of a transcript back to the last
  real prompt - not a tool result, not Claude Code's own - in order, a
  tool as one line, a side chat left out, a limit as a note; cut from the
  front at `-Max`, never between an emoji's halves; a job's last run from
  its own log, Claude and Codex.
- **The down topic:** a short one a POST with its did as `X-Title`,
  `X-Firebase: no`, priority 1; a long one one PUT with `X-Filename`; a
  refused PUT cut from the front until it fits inline, `cut` saying how
  much; a board too long halved from its Recent rows, `more` counting them.
- **With an alert:** the answer goes before the push and the link says
  `f=1` and `o=`; the down topic failing - no `f=1`, the push still goes;
  `started` and `-FullText off` send none; `reply.downPerDay` reached sends
  none, and a new day counts afresh.
- **The board**, from a fixture `overlay.json`: the overlay's rows,
  usage, where each chat runs, the new-turn dot; handles in `picks` with
  the chat's config dir, and no session id or path on the wire; the act
  counted for the hour, the next 2 minutes polled faster; asked again
  within 10 s the same board, not built again, unless a send changed the
  queue; built again, the same handles. Each row's mode: an open chat's
  own (`default`, not capped), one above `reply.maxMode` as the cap with
  `mc`, a cut-off one's, a Recent one's from the transcript its folder's
  slug names, and a Recent one with none not `known`; the 10th cut-off
  read and an 11th not, a row with a mode already kept as it is; a
  cut-off row's `al` the overlay's auto words (`cut off - resets 13:00 ·
  auto-continue queues it`) beside its plain `d`. The overlay's tail read
  keeps a chat's last `permissionMode` across a read that names none and
  takes the next one a new record names; on its first read it goes on
  past 256 KB of tool output after the prompt for the mode, where a read
  not asking for one stops at the prompt and title. From a scan, with
  the snapshot old: the registry's open chats and the chats the limit
  cut off, `from` scan, a cut-off row with auto-continue on carrying its
  auto words; the whole board sent again within 10 s; 25 s on the scan
  kept but the queue read again, a job queued meanwhile on the board and
  its row; 45 s on scanned again, no transcript read twice. The list
  offers a folder on another machine without looking at it. A job the
  watcher holds back says why, as the panel does - `waits for you to
  leave its tab`, or `waits for a background command (since ...)` -
  others their ETA, and a chat a queued prompt runs in passes on its
  where, `run`.
- **The acts:** send - a job for that chat, rule phone, capped, its links
  defused, in its config dir, an ack and a push; new - in the folder the
  board offered, a bidi override out of its name, in `default`, its push
  naming neither title nor folder; with no name, `phone chat` and the time
  for a title, never the text, held - and taken by a later job into that
  chat - until Claude titles the chat, then the chat's own; now (to the front, the watcher woken),
  skip, stop, retry, allow - a handle's whole id finding only its own job,
  never the same-second sibling `-2`, and only with the handle's number -
  continue at reset and a second one refused, its cut-off marked as the
  ask's answers are, so once skipped auto-continue reads it declined, read
  (no push, counted as a whole answer, and refused with `-FullText off`),
  status, list. The one job maker both a send and an alert's reply use
  ([New-ChatqPhoneJob](src/phone-board.ps1)): an empty reply and one over
  8,000 characters refused in the reply's words, a job's own mode kept,
  a chat's lower mode taken with `-OwnIfLower` and said, a higher one
  brought down to the phone's limit and said. Refused, each said: another
  chat's id, an expired handle, a handle of another kind, a job number not
  the handle's, 31 minutes old, the 21st change in an hour, an unknown act,
  `-Compose off`; a replay from the file dropped in silence; refusals told
  once a minute; `replies.json` locked - nothing done, and done on the next
  poll.
- **Only on what the board showed:** a job's handle keeps the job as shown
  (`mark`); a send and a continue into a chat that took a prompt at the PC
  since the board - refused as out of date, nothing queued, and the send
  goes once the board is asked again, or once its last answer was read;
  the refusal drops the board kept in memory; skip on a failed job queued again at
  the PC - refused, the requeue kept; allow on a job answered in its chat -
  refused, no mode raised, the job closed "answered in the chat"; retry on
  a failed job whose chat took a prompt since - refused.
- **Listening:** `-Listen always` listens with no alert and starts a
  watcher; 20, 15 and 6 s between polls, 30 and 10 inside a run;
  `chatqrun -Stop` ends it and a shell's start begins it again; no phone,
  nothing; `-Listen alerts`. A save prunes `picks` and `compose`, and a file
  that cannot be read still throws. The five settings, each checked and
  saved; the setup window's three boxes, drawn off-screen in an STA child.
- **No cap set (keep, the default):** every check above runs under
  `acceptEdits`; this one takes `reply.maxMode` out. A board send into a
  `bypassPermissions` chat queues it with no mode of its own and says no
  limit; `New-ChatqPhoneJob` with no `-Cap` keeps `bypassPermissions`; the
  list's `cap` is `keep` and the chat's `m` its own, not brought down; the
  header ([Complete-ChatqDownHeader](src/phone-board.ps1)) says `keep` for
  an empty cap too; a new chat starts in the `auto` `reply.newMode` names;
  `chatnotify -Compose on` says `in the chat's own mode`, not `keep at most`.
- **What a queued job runs in:** each queue row of
  [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1) carries `m` - a Codex
  job's own sandbox, else its chat's, a Claude job's mode, else
  `default` - so `51=read-only,52=workspace-write,53=default`.

**What `board-page-check.js` holds** (and, since 0.9.0: an "out of date"
ack sends the chat view back to a board asked for afresh, the refusal in its
notes until a chat is opened, the draft back when it is; for an older chat
the list asked for again with the board, its fresh handle used; an answer
to a chat view left since lands in no other; and, with the handover work,
a chat a queued prompt runs in reads `a queued prompt` where a terminal's
reads `terminal`, and a message to it goes after the run, while a job held
back shows its reason on its chip and in the chat view as it is): the fixtures against Node's crypto and
zlib; the page's third block, between the `chatq-board` markers, touching
no page and run under Node's WebCrypto and `DecompressionStream`: the down
topic from the raw key and the kept one, a down message opened, the compose
payload's key order and the compose vector byte for byte, every act's
fields in the watcher's order and the acts the watcher's own
(`$script:ChatqComposeActs`), `openDown` refusing another prefix, did or
ref, a changed byte, another key, not v 3, not JSON, not raw deflate, and a
bomb past 4 MB; the poll URL, the attachment check (the server's own
`/file/`, 2 MB, its expiry), `f`/`o` in the link; the answer as blocks,
tools folded, Copy; the search (Hangul NFC or NFD, any order); each row's
acts; a chat's mode as its own, `(phone's limit)` when capped, `at most
<cap>` only when not known under a cap, `the chat's own mode` under keep
or none sent, and a queued job whose chat has no row reads the job's own
`m` (`modeText`); a cut-off row's line the auto words `al` over the
plain `d`; the sections in the overlay's order, usage lines, the footer; the
list's older chats - none the board shows, a Codex one's mode and no last
answer to read. Then the whole page under the fake DOM with a fake
ntfy.sh: the bare page is the board and posts one `board`; drawn,
searched, tapped; each act sealed with the row's handle; acks, **Try
again** with the same message, an out of date list asking again; the 30 s
refresh, none while hidden, paused after 10 minutes; the scan and budget
notices; **Older chats** - one `list`, its chats drawn, a Codex one tapped
and sent to by its handle; **+ New chat**; the no-answer card; an alert's
whole answer - inline, as an attachment, expired, asked for,
not answered, not looked for without `f=1`; and no raw key or anything the
PC sent kept anywhere. `reply-page-check.js` still holds the rest of the
page, the board's GET among the requests it allows.

**The fixtures**, `tests/fixtures/down-vector.json` and
`compose-vector.json`, from `node tests/fixtures/make-down-vector.js`: the
key bytes `0x00..0x1f`, did `abcdefghij`, cid `klmnopqrst`, IV
`0x10..0x1f`, payloads with Hangul, and the deflate from Node's
`zlib.deflateRawSync` - deflaters differ, so the PowerShell side seals
Node's bytes rather than its own. The other way, .NET's `DeflateStream`
as `Compress-ChatqBytes` writes it, opened by Node's zlib and by
`DecompressionStream('deflate-raw')` to the same bytes, was checked once by
hand on 2026-09-27 under 5.1 and 7.4.6 (11,600 bytes of Hangul and ASCII);
no run holds it, since the two sides' deflate output differs.

**Screenshots:** the board, a chat's view, a new chat, and an alert with
its whole answer, at 390 px in dark and light, from headless Edge through
its DevTools protocol - a phone viewport, `prefers-color-scheme`
emulated, the page's own `fetch` stood in for by a script injected ahead
of it that answers as the PC would. Virtual time
(`--virtual-time-budget`) never let the page's WebCrypto and IndexedDB
finish; real time did.

**Not covered by the run:** ntfy.sh itself - its CORS, its attachments,
its 250 a day - a phone's browser, a sleeping PC, and a real overlay
writing the snapshot the board reads.

### The demo frames

`docs/make-demo.ps1` draws every frame in the README: `docs/demo-queue.svg`,
`docs/demo-list.svg`, `docs/demo-overlay.png`, and the `chatrm` walk-through,
`docs/demo-1-type.svg` to `docs/demo-4-reloaded.svg`.
- **The overlay frame is the real panel,** rendered off screen by WPF from the
  real collector reading a made-up session list, so it needs Windows
  PowerShell. Only the usage endpoint is a stand-in, answering what the
  sandbox's cache says.
- **The terminal is real output:** the real commands against a sandbox of
  made-up chats, captured by a `Write-Host` of its own, which also reads the
  colour escapes the walk row carries.
- **Two steps are rebuilt:** the line Tab leaves, and the line Enter runs, are
  made with the cycler's own functions, because the PSReadLine buffer they
  write into exists only at a real prompt.
- **Two things are made to look like a real shell:** a VS Code window, since
  the reload advice prints only while one is up, and the ghost watch.
- **The panel beside the terminal is a sketch:** the sandbox's Claude chats as
  the index lists them, before and after the delete. VS Code itself is never
  captured.
- **The Marketplace listing gets PNGs of three:** `demo-2-tab.png`,
  `demo-queue.png` and `demo-list.png`, since vsce refuses SVG images in
  `extension/README.md`. Headless Edge draws them from the SVGs, at twice
  the size, with a profile of its own in the sandbox. Without Edge the SVGs
  are still written, and the script says the PNGs were not.

Run it again after a change to what `chatq`, `chatqlist` or `chatrm` print.
Each run moves the clock times in the queue frames; nothing else changes.
The listing shows its images from `main` on GitHub, but its README text only
changes with a new release.

## Tier 1: this PC, for real

### Spikes against the real CLIs

These ran once while building, against Claude Code 2.1.278 and the Codex bundled
with openai.chatgpt 26.908 (codex-cli 0.154), on throwaway chats only. Rows
that name a later version ran on that one; S-A4 and S-A5 read codex-cli
0.159.2 (openai.chatgpt 26.928) without starting a model turn, and S-A5 says
which of the 0.154 Codex rows still hold there.

| | question | answer |
|---|---|---|
| S1 | stream-json shapes | `system/init`, `rate_limit_event` (sent even when allowed), `assistant`, and `result`, whose `type` key comes **last**. Captured to shape the fixtures |
| S2 | are auto-denied tools reported? | yes, twice: a `system/permission_denied` event, and `result.permission_denials[]` |
| S3 | `--permission-mode default` | accepted; `manual` is recorded as `default` |
| S6 | Hangul through stdin on 5.1 | intact, read from a UTF-8 file. A Hangul **literal** in a BOM-less `.ps1` is mangled by 5.1 itself — hence pure ASCII |
| S7 | the probe | 3 s and $0.0045 on haiku, reports the limit status, writes no transcript |
| S8 | model on `-p --resume` | the chat's own model is kept, so a run names one only when `-Model` asks |
| S9 | the watcher outlives its parent | yes: queued with `-In 1m` from a shell that then exited, the job ran on time |
| S11 | Codex `exec resume --json -c sandbox_mode=… <id> -` | same thread id, appended to the same rollout; `exec resume` also takes `-m` |
| S14 | `codex queue`, `archive`, `unarchive` | present in codex-cli 0.154 (`--help`). `queue` sends `thread/queue/add` to Codex's shared app-server daemon when one runs, else to an app server it starts for itself - which is **not** the VS Code panel's: the panel runs a private app server of its own per window and never the daemon (S-A5) |
| S15 | the usage cache | `~/.claude.json` → `cachedUsageUtilization.utilization.limits[]`: `kind` (`session`, `weekly_all`, `weekly_scoped` with a model scope), `percent`, `resets_at`, plus `fetchedAtMs`. `resets_at` comes a moment off the minute on some fetches: `12:59:59.855638+00:00` where another said `13:00:00+00:00` (2026-10-06), so it is read to the nearest minute ([ConvertTo-ChatqResetDate](src/queue.ps1)) |
| S16 | `codex archive` on a real thread | the rollout moves out of `sessions/YYYY/MM/DD/` into a flat `~/.codex/archived_sessions/`, which `chatrestore` lists; `codex unarchive` puts it back under `sessions/`. `codex delete` refuses without a terminal unless given `--force` and a UUID |
| — | archive → restore of a real Claude chat | the transcript moved into `data/archive/` and back, and the archive folder was gone after |
| — | the toast, from a shell on 5.1 | shown in-process; the idle clock read 145 s since the last input, so the phone would have stayed quiet |
| S18 | files into a resumed chat (Claude Code 2.1.280, codex-cli 0.154) | Claude, `--permission-mode default --permission-prompts none`, two PNGs, a `.txt` and a `.pdf` named in the prompt from **outside** the project: all read, the images seen as pictures, nothing denied — with `--add-dir` and without it. Codex, `-i a.png -i b.png -- <id> -`: both images seen, the text and PDF read from the prompt; it logged one `CreateProcessWithLogonW failed: 267` from its sandbox on a shell command and answered anyway |
| S21 | work sent to the background, and whether the chat reads idle (Claude Code 2.1.280) | a background agent, then a one-agent workflow, were started and the turn ended each time, with a poller reading both checks every 4 s. `claude agents --json` kept the chat `busy` until the work finished, both times. The old transcript-only check called the project idle 60 s after the turn ended, for the last 50 s of each run: the bug 0.3.1 fixes. The new check said active throughout, and the transcript search held the workflow's task id until its `<task-notification>` landed. `Write-ChatGhostAdvice`, run mid-workflow from a scratch copy, printed `a chat is still active` and left `"busy":true`. Fed to the extension's own functions, that request matched the window, drew the warning, and would not auto-reload. On this machine's 111 real transcripts, 139 workflow and 74 agent starts each paired with a `<task-notification>` naming their task id, except one workflow whose process was restarted under it — later `TaskStop` found no such task. That is the case the process-start cut-off drops. The scan took 2.2 s over all 111 transcripts, and 127 ms for the largest, 26.6 MB |
| S28 | a queued prompt delivered into a chat open and idle in a VS Code panel, through a `claude -p` relay's `SendMessage` (Claude Code 2.1.280, 2026-09-24) | the relay (Haiku, `--tools SendMessage`) listed 11 live sessions, panel ones included, under the `name` each `~/.claude/sessions/<pid>.json` entry carries beside its `sessionId`, and sent verbatim with no hold. The idle panel chat began a turn within 3 s, shown live, no reload. It receives `Another Claude session sent a message: <cross-session-message …>` and a note that this is not typed by the user: act on it as a teammate's request, never edit settings, `CLAUDE.md` or config for a peer. `Reply with the single word PONG` it tried to send back to the relay, which had exited. `[chatq] … Do it here, in this chat … no reply is needed` with a file to create: done and answered in the chat, 20 s end to end. The same asking for a line in `data/spike/CLAUDE.md`: declined in the chat, with an offer to do it if asked there. One relay without `--safe-mode` cost $0.077, most of it writing its prompt cache. Sending from inside a Claude Code session in auto mode was stopped by the classifier as instruction poisoning; the user sent the last two by hand |
| S29 | the side bar, the Claude extension's open commands, and Reload Webviews (Claude Code VS Code 2.1.280, 2026-09-24) | **The commands.** The Claude Code extension registers `claude-vscode.editor.open(sessionId, prompt, …)`, which opens the session where you keep Claude - the side bar here, through `activateInSidebar(sessionId)` - and `claude-vscode.primaryEditor.open(sessionId, prompt)`, always an editor tab, through `createPanel`. `createPanel` only `reveal()`s a panel the session already has, stale; with none it makes a new webview panel, loaded from disk. Run from another extension, neither raises a dialog. Its URI handler, `vscode://anthropic.claude-code/open?session=<id>&prompt=<text>`, calls `primaryEditor.open`, but opened from outside VS Code first asks "Allow 'Claude Code for VS Code' extension to open this URI?"; `prompt=` only fills the input box (`setInputText`), it never sends. **The side bar** shows one chat at a time and keeps each chat's messages cached in its webview: picking a chat again from the history shows that copy. **Through the URI**, a headless chatq run into a chat idle in the side bar showed in a new editor tab, which got a new process - a second live `~/.claude/sessions/<pid>.json` entry, same `sessionId`, new pid - while the side bar's idle process stayed alive with the old memory. While a chat has an editor tab, picking it in the side bar history only focuses that tab: one surface per chat per window. **Ending the old process by hand** (checked as `claude.exe` by name and start time, status idle) and closing the tab: picking the chat in the side bar then showed the stale cached view, but a new process started from disk, so replies continued correctly. **Developer: Reload Webviews** (`workbench.action.webview.reloadWebviewAction`) redrew the side bar with the run. It also restarted the window's Claude processes - the active chat got a new one, the other chats' idle ones ended, to start again when opened - so it cuts a working chat off as a window reload does; terminals, other extensions and editors were untouched. By hand after it: the stale chat showed both replies of the run, and the chat being typed in at the time came back intact and could be continued. **Read-only checks:** each of the 9 live VS Code panel `claude.exe` processes was a direct child of `Code.exe` - 5 parent pids for 5 windows - running from `~/.vscode/extensions/anthropic.claude-code-<ver>-win32-x64/resources/native-binary/claude.exe`; their registry files carry `"entrypoint":"claude-vscode"` and `"kind":"interactive"` (only key names and those two values were read, no `.key` file opened, `messagingSocketPath` not read out); one window already ran 2.1.281. Every transcript record carries the `entrypoint` of the process that wrote it: over this machine's 112 top-level transcripts (only that key counted), 107 held only `claude-vscode`, 2 only `sdk-cli` and 3 both - chats a `claude -p` had written into as well (S25 saw `sdk-cli` on a print-mode run's records) - and all 230 `async_launched` records said `claude-vscode`; none a print-mode run started was there to see (S30 item 18). `code.cmd` clears `VSCODE_DEV`, sets `ELECTRON_RUN_AS_NODE=1` and runs `Code.exe` on `resources\app\out\cli.js`. Run from a Claude Code session's shell, `code` failed with "Invalid file descriptor to ICU data", exit 3. That was put down to the `VSCODE_*` and `ELECTRON_*` variables it inherited, which chatq clears for it - wrongly: the first clicks of the open chip failed the same way (0x80000003), and so did `code --version` with a bare environment. The `code` on PATH was a system install left half-updated since February - its `Code.exe` at the top, `icudtl.dat` and `resources\` in a `_\` beside it - while every window ran a per-user install whose own `code.cmd` works, from that shell too. chatq now takes the `code.cmd` beside the running `Code.exe` first (`Find-ChatCodeCommand`) |
| S37 | a chat Claude Code hides, and an entrypoint of chatq's own (Claude Code 2.1.283, 2026-09-27) | **The rule**, read in its code: the VS Code extension (`_j`) and the CLI's `/resume` picker (`v5o`) leave a session out of every list when the first `"entrypoint"` in its transcript's first 64 KB - else the last one in its last 64 KB - is `sdk-cli`, `sdk-ts` or `sdk-py`. The webview restores a tab only for a session in that list: otherwise it sends `restore_declined` and starts a blank chat. **Here**, one VS Code chat was hidden: its first prompt a pasted screenshot, its first `entrypoint` at byte 340,359, and a phone reply chatq ran as `claude -p` had written `sdk-cli` last. Four open-chip clicks logged `restore_declined` and made four blank chats. Two other chats chatq had continued stayed listed: their heads said `claude-vscode`. The two chats `claude -p` started were hidden, S25's open question. **`CLAUDE_CODE_ENTRYPOINT=chatq`** on a real `claude -p --session-id <id> --name <n>` in a scratch folder: the stream-json unchanged (init, assistant, `result` ok), and all 18 records `"entrypoint":"chatq"`, which the rule lists. Under `-p` the CLI keeps any value it is given but `cli`, which it rewrites to `sdk-cli`. **But not taken:** read further in the CLI, an entrypoint outside `sdk-ts`, `sdk-py` and `sdk-cli` also turns on what Claude Code keeps off for them - the Artifact tool (`sdk_default_off` otherwise), autoDream, the `claude-code-guide` agent type - goes raw into every model request's `x-anthropic-billing-header` as `cc_entrypoint`, and is handed to every process the run starts. So chatq's runs stay `sdk-cli`, and the chat is mended after instead. Nor can a new chat be born listed by writing its first lines first: `claude -p --resume` on a transcript with no message says `No conversation found with session ID`, and `--session-id` refuses an id already on disk. **An unknown record type:** `{"type":"chatq-listed",...}` appended to that transcript, `claude -p --resume` loaded it and quoted the chat's first prompt and reply. The extension's reader keeps only `user`, `assistant`, `progress`, `system` and `attachment` records (`y40`), its readability probe looks for user and assistant lines only, and its own rename appends a `custom-title` line to a transcript the same way (`UI`: append, no create, never to an empty file). Three haiku runs, $0.15 |
| S39 | the tab the overlay opens, and its header (Claude Code 2.1.281 to 2.1.283, read in its code, 2026-09-27) | **What was wrong.** Tabs the overlay opened had no header - no title, no **Session history**, no **New session** - where a tab from the side bar has one. `claude-vscode.primaryEditor.open(sessionId, prompt)` calls `createPanel(sessionId, prompt, pr(), undefined, true)`: the last argument is `fullEditor`, which reaches the webview as `window.IS_FULL_EDITOR`, and the header's title and both buttons are drawn only when it is false. A full editor also skips the diff for an edit or write to approve. The flag is kept in the panel's state: a reload restores it, and a panel restored with no flag in its state is a full editor when it sits in the first editor group. **The way round it.** `claude-vscode.editor.open(sessionId, prompt, viewColumn, group, fullEditor, options)` - the same order in 2.1.281 and 2.1.283 - calls the same `createPanel` with `fullEditor` as given. With `options.programmatic` set it never rewrites `claudeCode.preferredLocation` (without it, it sets `panel`) and does not focus the input; `pin-to-panel` always makes a tab, never the side bar. Given a column, `createPanel` neither starts a new group nor locks one. `pr()`, the column `primaryEditor.open` uses, is a group holding only Claude tabs (the active one first), else the active group when it holds a Claude tab, else `ViewColumn.Active`; the extension now works out the same (`claudeColumn`). **Side effects.** An ordinary tab asks for a diff for each edit or write to approve (`vscode.diff`, no column given, so the active group): with the chat's group unlocked, as the extension leaves a group of Claude tabs unless `claudeCode.lockEditorGroups` is set true, the diff opens in that group, in front of the chat. And Claude Code's own `reopenClosedSession` brings back a full editor into `pr()`'s column but an ordinary tab into the column it had; with that column gone and no group of Claude tabs, it makes a new group, locked unless `claudeCode.lockEditorGroups` is false (`dG`). Not yet seen in a window: S40 |
| A1 | auto-continue: does a VS Code panel chat continue itself after the limit? | **Open, leaning no.** Not run on purpose - it needs a real limit. Read-only from this machine's transcripts (2026-09-27): four cut-offs of chats open in VS Code panels on Claude Code 2.1.282 and 2.1.283 (one on 09-26, three on 09-27 with one reset), `autoContinueAtUsageLimit` set nowhere in `~/.claude/settings*.json`. In none did anything write to the transcript after the reset until a typed `continue`, 11 to 53 minutes later. Whether each panel was on screen and idle at the reset is not recorded, so this is not the controlled run. As the spec says for a no, the 5-minute hold stays (`$script:ChatqAutoHoldMinutes`, and the reset ask's `$script:ChatqAskAfterMinutes`) as a guard, and chatq's continue is skipped if the panel's went first. If a controlled run finds the panel reliably does continue, such a chat should be left alone as a terminal's is |
| A2 | auto-continue: the words of Claude Code's own continue | **Open**, with A1: the wait's own continue was never seen here. What was seen (2026-09-27, read-only): when a chat whose last turn the limit cut off gets its next prompt, Claude Code first writes an `isMeta` user record `Continue from where you left off.` and a synthetic assistant `No response requested.`, then the prompt - from a panel (2.1.263) and from `claude -p` (2.1.280, chatq's own continues, whose prompt is those same words). So `$script:ChatqContinueText` names a record Claude Code does write. The moved-on check reads the last turn's error shape, not these words, so nothing depends on it but the comment |
| A3 | auto-continue: is the limit record's `uuid` stable? | **Yes.** Read 2026-09-27 from this machine's top-level transcripts (Claude Code 2.1.246 to 2.1.283, only the records around each limit record): 25 limit records (`"error":"rate_limit"`) in 16 chats. 22 have a uuid no other record in their chat has, and each is the `parentUuid` of the next turn once one came. One chat holds the same record three times - the same uuid and timestamp, copied, never rewritten. None came back under a new uuid, whatever followed: a typed prompt, a queued one, a task's note. So the marker both modes share keys on the uuid (`Get-ChatqCutKey`, the time only where a record has none). **Found beside it:** a chat woken before its reset - a background task's note arriving - hits the limit again, a new record and uuid with the same reset (seen 6 minutes apart). A new uuid is a new cut-off, so a continue removed for the first would have been queued again for the second; `Get-ChatqAutoState` now holds a removed continue - or one the reset ask left - for every cut-off of that chat with the same reset. Nothing of the transcripts went into the repo |
| A4 | auto-continue: which registry `kind`s hold a chat | Read 2026-09-27 from this machine's `~/.claude/sessions/*.json` (Claude Code 2.1.283, keys and those values only, no `.key` opened): six entries, all `"kind":"interactive"` and `"entrypoint":"claude-vscode"` - no background or agent-view session was running. S38 item 5 saw a `claude -p` register as `interactive` with `entrypoint` `sdk-cli`. So check 3 goes by the entrypoint as well as the kind: only `interactive` (or none) **and** `claude-vscode` is a panel; anything else - a terminal's `cli`, `sdk-cli`, a kind other than `interactive` - holds the chat. `Read-ChatqSessionRegistry` reads both fields for every entry, and the reset ask's `held` goes by the same rule |
| S-A4 | `codex app-server` over stdio, read-only: does it answer after stdin's end, how slow is a cold start, and does a read touch the login (codex-cli 0.159.2, the VS Code extension's copy, 2026-10-02) | Only `initialize`, `account/rateLimits/read`, an unknown method and `thread/list` with `useStateDbOnly: true` were sent - nothing that starts a turn or writes `~/.codex`. **Stdin's end ends it.** Written all at once and stdin closed, the server answers `initialize` and exits 0 within 0.15-0.2 s, dropping the `account/rateLimits/read` still in flight - so the run-once runner ([Invoke-ChatqProcess](src/queue.ps1)) cannot drive it, and [Invoke-ChatqCodexRpc](src/codex-appserver.ps1) holds stdin open until every reply is in; closed then, it exits 0 within 50 ms. **Cold start:** `initialize` answered in 0.06-0.28 s, the rate-limit read in 0.5-1.0 s, three requests in one start 0.63 s. **The login:** `auth.json`'s write time unchanged over about seven reads (its contents never opened). Along the way: a `remoteControl/status/changed` notification (`disabled`) after `initialize` and an `account/updated` one, neither with an id; logged out (an empty home) the read is error -32600 `codex account authentication required to read rate limits`; a method it does not know is -32600 `Invalid request: unknown variant ...`; and a `CODEX_HOME` that is empty or not there is filled with its state databases at start - so the client refuses a home that is not there rather than make one |
| S-A5 | which of S11, S14, S16 and S18 still hold on codex-cli 0.159.2 (the VS Code extension's copy, openai.chatgpt 26.928.40906, 2026-10-02), read without a turn | Read from `--help`, the strings in the binary, the app-server's JSON schema (`app-server generate-json-schema`, with and without `--experimental`), the running processes and `~/.codex`'s layout - nothing that starts a turn or writes `~/.codex`. **S11 holds as far as its flags go:** `exec resume --help` still lists `-c` overrides, and the help for resuming still takes an id or thread name and `-` for a prompt on stdin. `sandbox_mode` takes only `read-only`, `workspace-write` and `danger-full-access` - a `managed` fails at config load, which is why [ConvertTo-ChatqCodexSandbox](src/queue.ps1) exists. That the run keeps the thread id and appends to the same rollout was not run again: that takes a turn. **S14 was wrong about the panel.** Each VS Code window runs its own `codex.exe app-server` over stdio - two seen, with different parents and no `--listen` - and no shared daemon was running: `app-server daemon version` could not reach its control socket, and `~/.codex/app-server-control/` was not there. `codex queue` refuses `--no-daemon` ("Queuing must discover the shared server"), so with no daemon it writes through an app server of its own, into `queue_1.sqlite`; whether the panel's own server then runs the message is not known. `thread/queue/add`, `list`, `update`, `delete`, `reorder` and `start` are in the experimental schema only - a first read of the stable schema alone had called them absent. **S16 holds as far as its flags go:** `archive`, `unarchive` and `delete` take an id or a name, and `delete --force` still says "SESSION must be a UUID". Where `archive` puts the rollout was not checked again, since that moves a thread. **S18 holds as far as its flags go:** the help for resuming still offers images attached to the prompt; whether the model sees them takes a turn |

The end-to-end run on a throwaway chat went probe → run → done through the
background watcher in 10 s, with a real `claude agents --json`. The merged file
indexed this machine's 218 real chats in 15 s and resolved a real title.

Attachments went end to end the same way, through the built code rather than
the spike's: `chatq <id> -Prompt … -Attach 'otter shot.png', plum.pdf` for a
throwaway Claude chat and a throwaway Codex thread, each job sent by
`Invoke-ChatqJob`. Both answered `IMAGE=OTTER 88 PDF=PLUM 3`. The clipboard
reader read this machine's clipboard the same both ways: in-process from 5.1's
STA console, and - from a shell started with `-MTA`, which cannot - through the
`-STA` child Windows PowerShell it starts for that. It left no folder behind.

The overlay ran on this machine, with ten real Claude sessions registered.
Nothing drove the mouse or keyboard: the window was read back with
`PrintWindow` and its extended style, and every command went through
`chatoverlay` or `data/overlay-cmd`.
- **Rows:** `chatoverlay` started it in 1.5 s, top right. The captured window
  showed the one chat waiting on input (amber, `input needed`) first, then
  the two working, then the idle ones. New chat tabs with nothing sent in them
  were left out. That was after a fix: they had shown as rows named like
  `as-bw-02`.
- **Usage:** the first pass asked the usage endpoint. It read 87% for the 5 h
  window while `~/.claude.json` still said 55%, fetched 153 minutes earlier.
- **Window style:** `WS_EX_TOOLWINDOW | NOACTIVATE | LAYERED | TRANSPARENT`.
  WPF had also set `WS_EX_APPWINDOW`, which would have put a button on the
  taskbar; it is now cleared.
- **Commands:** `-Unlock` dropped `TRANSPARENT` and `-Lock` put it back. `hide`
  hid it and `chatoverlay` showed it again. A `restart` handed over to a new
  process in under a second, and `-Stop` closed it in 2.2 s with its pid file
  and lock gone.
- **Cost:** one pass over the ten sessions took 40-60 ms, and the first read
  2 MB of transcripts. CPU was 0.07% of the machine over 20 s. The process held
  288 MB until WPF was switched to software rendering, then 162 MB, flat over
  90 s. A collector alone is about 115 MB.
- **Its parent:** it outlived the shell that started it, which exited at once.
  That shows only that it survives its parent exiting; closing a whole Windows
  Terminal or VS Code, which can end every process they started, is below.

`docs/make-demo.ps1` then found two more by rendering from a sandbox with no
Codex home. An `if` whose branch yields an empty array assigns `$null`, so the
usage header failed there, and every pass queued an empty command, which made
the panel redraw every 2 s. Both are fixed and in the table above.

### The overlay's own cost

Not in the self-test: what the overlay costs is measured by hand, on the
live overlay, read-only.

- **The processor, by cycles.** On the machine this was written on,
  `Process.TotalProcessorTime` reads PowerShell's work at a fraction of
  what it is: a 2 s busy loop read as 0.28 s, and the overlay as 1% of a
  core where its cycles said 5.6%. So count cycles -
  `QueryProcessCycleTime` for the process, `QueryThreadCycleTime` for
  each thread - over a sample of a minute or more, and divide by the
  cycles a busy second takes, from a C# spin timed the same way before
  and after the sample. The panel's thread is nearly all of it.
- **One function's cost.** The calling thread's cycles around the real
  function: loaded through the parser with its native calls stood in
  for, or in a child `powershell.exe -STA` with the panel shown off every
  screen.
- **At 2026-10-06**, on that machine (some 390 processes, 5 open chats):
  the overlay at 9.0% of one core before a first pass over its cost (60 s,
  the panel's thread 8.7%) and 5.6% after it (90 s, 5.1%), one sample each,
  with the pointer and the chats as they happened to be; 283 to 287 MB
  private. Piece by piece: the pointer check with the pointer away, 2.9
  to 3.1 ms a check, now a compare of rects; the rows' rects, 8 to 10 ms
  a check with the pointer on the panel, now kept; the process list,
  0.19 to 0.34 s by `Win32_Process` and 13 to 22 ms from Toolhelp32; the
  C# as it starts, three compiles of 0.46 to 0.64 s together, now one of
  seven types in 0.22 to 0.25 s; the VS Code windows' files, 47 ms a
  read, 2.6 ms while they are unchanged.
- **A second pass, the same day**, with 104 transcripts written in the
  last week. The cut-off scan's cold start: 219 ms split whole, 49 ms
  read back from the end, the same answer for each transcript. A redraw
  for an age's minute: about once a minute, 24 ms, some 0.04% of a core -
  left as it is ([Update-ChatOverlayView](src/overlay-windows.ps1) says
  why). The queue read whole: 1.2 ms a file, 24 ms at 20 files, 114 at
  100, and only as a job file changes - left as it is
  ([Get-ChatqJobs](src/queue.ps1) says why). A shell's load:
  168.5 MB private and 503 ms with all 25 parts, 124.3 MB and 395 ms
  without the overlay's three, a bare PowerShell 51.9 MB - each a fresh
  `powershell -File` under fake homes with `CHATQ_WATCHER=1`, the median
  of 7 alternated, after a full collection. The heap compacted three
  minutes in, by the overlay's log: 22, 41, 52, 56, 71 and 82 MB given
  back in 74 to 120 ms on six starts - the 120 with the suite running -
  232 to 236 MB left each time. It grows back: one run's large object
  heap went between 22 and 40 MB with the full collections and its
  private between 252 and 269 MB an hour in; the next held 52.7 and 284
  MB from 38 to 50 minutes in, with no full collection between, where an
  overlay not compacted had held 58 and 300 an hour in. What one holds an
  hour on is within one run's difference from the next. These by the
  `.NET CLR Memory` counters, every
  `powershell` instance read in one go and the overlay's found by its
  `Process ID`, since the instance names shift between reads - and by
  the instance in each sample's path, `powershell#3`: a sample's
  `InstanceName` drops the `#3`, so matching on it mixes in every other
  `powershell`'s counters.
- **A third pass, 2026-10-07**, on the large object heap: the CLR's
  allocation events on the live overlay, three minutes at a time (an ETW
  session on the .NET runtime's provider, GC keyword - one tick per some
  100 KB allocated, with the heap and the type), and those counters a
  minute apart. Reading a grown transcript on from 64 KB back put a
  130 KB string on that heap for each busy chat every pass: 28 ticks
  there in three minutes, some 160 KB each. Read on from the last whole
  line instead, an [Update-ChatOverlayText](src/overlay-data.ps1) call
  on a transcript 2 KB longer takes 920 KB and 8.7 ms where it took
  1,168 KB and 13.9, 300 of them bring on no full collection where they
  brought one, and three minutes of the overlay after it held 4 ticks
  there, about 1 MB each and none of them again. The background scan's
  first look at a long chat gone idle, 8 MB a call and a 16 MB string
  each, took that heap from 10 MB to 89 between two counter reads, and
  it stayed. [Update-ChatBackgroundScan](src/chatrm.ps1) from the start
  of a 40 MB transcript, twice in one process, what each call allocates
  by `AppDomain` monitoring: 8 MB a call after the first took 46 to
  87 ms and 27 to 32 MB, with one and two full collections a read; in
  40 KB pieces, 34 to 48 ms and 19 to 23 MB, and none. A shell's load
  again, that machine near its limit (93% of commit, under 1 GB free),
  the median of 5 alternated: 101 MB private and 0.54 s without the
  overlay's three parts, 111 MB and 0.68 to 0.73 s with them, under
  `CHATQ_WATCHER` and `CHATQ_OVERLAY` alike. The .NET heap after a full
  collection, 38 MB against 46, differs by the same 8 MB as with memory
  to spare; the private bytes, 10 MB where they differed by 44 - the GC
  holds less with memory short.
- **The overlay that stopped, 2026-10-07**, the machine's commit charge
  full: its log said `ui:` and an `OutOfMemoryException`, then nothing
  for 80 minutes, while its process took 47 ms of the processor in a
  20 s sample - no pass, no command read, no restart on the new code put
  in meanwhile. A `DispatcherTimer` queues its next run only once its
  Tick returns: in a child `powershell -STA`, one whose Tick throws,
  handled, reads as running with its private `_operation` empty, where a
  running one's holds its next run - the same under Windows PowerShell
  5.1 and pwsh 7.6. The self-test's check of
  [Register-ChatOverlayUiCatch](src/overlay-windows.ps1) fails against
  each wrong way to mend it: no timer started again (one throw, then
  none), every running one (the 1 s timer's place held back through 102
  throws, never ticking) and a stopped one too (a third tick, and left
  running).
- **An hour on, the same day**, those counters a minute apart from 19:02
  to 20:03, on the overlay as it started with the third pass's changes
  in, the machine near its commit limit again. The heap compacted three
  minutes in, 283 MB private to 239. The large object heap went from
  6.3 MB after that to 13.1 in 17 minutes, then held 13.1 to 14.6 and was
  12.3 at the end, where two runs before the third pass held 22 to 53 MB.
  So the overlay still compacts it once
  ([Invoke-ChatOverlayHeapCompact](src/overlay-windows.ps1)): a second
  would have little to give back. The full collections came 17 to 21
  minutes apart, generation 2 going from 89-95 MB up to 146-159 and back,
  and the private bytes with it, from 250-252 MB up to 272-290.
- **The C# compiler's own limits**, each compile in a `powershell.exe`
  of its own with a time bound: under a `TEMP` of up to 210 characters
  it works, at 211 it fails (`Error generating Win32 resource`), and at
  262 and 280 it hangs. Under a folder named with a character outside the
  code page it fails - Thai, `é` and `ü` on code page 949 - and with
  Korean, Hanja, Cyrillic, Greek, a space, `(` or `&` it works. The
  folder it makes in `TEMP` is gone after a normal exit and left behind
  by a forced one, and taking it away while the process lives harms
  neither the next compile nor the exit.

### Still to check by hand

- **S4, a chat still open in the VS Code panel.** Open a throwaway chat, leave it
  idle, queue a prompt for it and let it run. Does the panel show the run, or
  does it need the reload the extension now offers? Then set `"liveIdle": "stop"`
  in `data/config.json` and repeat. The result decides the `liveIdle` default,
  and whether the reload offer after a run is needed at all. S29 answered the
  first half: the side bar does not show the run by itself, and keeps its
  cached view even once the process is ended. S30 item 5 closes the rest.
- **S9, closing the terminal and quitting VS Code while the watcher waits.**
- **S12, at the next real limit:** the probe reports rejected with the right
  reset time, the job sends a minute after, and the transcript holds no stray
  prompt or error from the wait.
- **S13, at the next real 529:** what `claude -p` prints — an `api_retry` per
  retry, then an `is_error` result with `api_error_status: 529`, the shape
  `overloaded.jsonl` assumes — and the resume once status.claude.com is
  operational.
- **After S16:** that a thread archived and unarchived shows in the Codex panel
  again, and that one archived from the panel itself lands in the same
  `archived_sessions/`.
- **S17, the toast from the hidden watcher,** a separate hidden process rather
  than the shell.
- **S19, a screenshot through `-Paste`.** Win+Shift+S, then
  `chatq '<title>' -Prompt x -Paste -WhatIf` should say `with 1 file (… KB):
  clip.png`. Not run here: putting an image on the clipboard would have
  overwritten whatever was on it.
- **S20, Ctrl+V in the prompt tab.** Paste a screenshot into the tab `chatq
  '<title>'` opens, save and close it: the job should list `+1 file` and its
  prompt link `<job id>/image.png`. VS Code decides where the image is saved;
  chatq takes it from anywhere under `data/queue/` - beside the prompt by
  default, or in a folder named after it - so only a setting that saves it
  outside `data/queue/` would leave it behind.
- **S22, the warning in a real window.** S21 drove the extension's functions,
  not a running window, and left its request where no window watches. Reload a
  window so it runs the new extension, start a workflow in one of its chats,
  let the turn end, then `chatrm` a throwaway chat in the same project. The
  window should show a warning with **Reload anyway**, not the plain
  **Reload** offer.
- **S23, the overlay by hand on Windows.** What reading the window back could
  not show:
  1. A click on the panel's rows lands in the window under it, and typing
     stays there; one on its top strip, the bar, does not - locked too.
  2. The bar of buttons shows with the panel, in its top strip - collapse,
     refresh, settings, minimize, maximize, × at the right end - with no
     pointer on it. The pointer turns to the four-way arrow over its empty
     part, with a tooltip saying it moves the panel and the edges size it,
     and to the plain arrow over a button. Resting the pointer on the panel
     for a moment brings up the edges; sweeping across brings up nothing,
     and they go a moment after the pointer leaves. With the panel low on
     the screen the settings box opens above it, its right end at the
     bar's; dragged to the top of the screen, under the bar over the rows;
     either way the bar stays in the panel's top strip. At 30% opacity the
     buttons fade with the panel, and the bar still takes clicks.
  3. Holding the bar off its buttons drags the panel, the bar with it, and
     the position is kept after `chatoverlay -Stop` and a start. A press on
     a button never drags.
  4. The settings box opens above the bar, outside the panel: the slider
     changes the opacity as it moves and `config.json` has it a second after
     release; dragging past the box's edge keeps the slider. Dark, Light and
     System redraw at once; with System, switching Windows between light and
     dark mode follows within 5 s. Focus stays in the window you were typing
     in throughout.
  5. Collapse folds the panel to one line and the chevron turns; expand
     brings the rows back; collapsed survives a restart.
  6. Refresh inside a named wait asks nothing (the log shows no new
     `usage:` line) and Claude's line ends `not asked - wait`; outside one,
     the icon turns, and within seconds the line ends `checked` and the time,
     for 10 s. A second click inside 20 s says `just asked`. Codex's line
     ends `last run` and its date; with `gh` logged in, Copilot's line shows
     and its time moves on refresh. Lines and Bars in the settings box switch
     at once; in bars the same few words sit under each name, and neither
     view has a row of notes about usage.
  7. Minimize hides it and its bar, a balloon says the tray icon brings it
     back (once), and the tray icon does, the bar too - also after
     `chatoverlay -Stop` and a start while hidden. Maximize turns it into
     the console, the bar gone, and Esc brings the panel back with the bar.
     × closes it, a balloon saying it stays closed until
     the next sign-in; a new shell or VS Code window does not start it, and
     `chatoverlay` does, shown.
  8. **Ctrl+Alt+Shift+O** unlocks it, a drag anywhere on it moves it (the
     bar follows), and the key locks it again; locked, only the bar drags.
     Left unlocked, it locks itself two minutes after the pointer leaves.
  9. The tray icon's left click hides and shows it, and its menu's Lock, Hide,
     Collapse, Refresh usage, Move to top right and Quit work. The icon is
     Charlie, sharp at 100% and 150% scaling, with a dot at her bottom right
     that turns amber as a chat needs you and green as one works; its
     tooltip starts `Charlie:` and, past 63 characters, still ends in
     5h's `resets 13:00` whole.
  10. Neither window is in Alt+Tab or on the taskbar.
  11. With a monitor unplugged, it moves onto the main one within 5 s.
  12. It survives closing a whole Windows Terminal window, and quitting VS
      Code, when started from each. If it does not, launch it through
      `Invoke-CimMethod Win32_Process Create`, outside their job object.
  13. `-AutoStart on` (the default on Windows since the overlay starts by
      itself) brings it back after signing out and in and opening a shell
      - also when it was closed by × or `chatoverlay -Stop` before signing
      out, the close kept only until then.
  14. After an hour, memory is still about 170 MB, and CPU stays under 0.2%
      with the 120 ms pointer check running; the log shows no 429 at the
      five-minute pace.
  15. `/compact` in a chat: its row reads "command running" while it runs
      and `/compact` once it ends.
  16. Rested on, the buttons stay still - no flicker between two places -
      and each one takes a click; the settings box covers the panel only
      where the screen's top leaves it no room above.
  17. Background work, in a chat of any folder. Ask it for a workflow: once
      its turn ends the row stays green and reads `workflow` and the time
      since the launch, then goes idle within 2 s of its report. Again, and
      interrupt the turn while the workflow runs (Esc, or reject a tool):
      the row goes idle though no report comes, as the workflow is killed.
      A background agent reads `agent`. A command sent to the background
      (`run_in_background`, or a long one past its timeout) reads `shell`
      until it ends, and stopping it from the task list, or by asking the
      chat to stop it, turns the row idle within 5 s. Checked on
      2026-09-28 against live chats: a killed workflow idle, two chats'
      background test runs `shell 6m` and `shell 17m`.
  18. **A close held across shells.** Close it by ×, then the tray's Quit
      after `chatoverlay`: each time the balloon says it stays closed until
      the next sign-in, and a new shell and a new VS Code window leave it
      closed (`overlay.log` reads no start). Sign out and in: it starts
      again by itself. Close it by × and, inside the balloon's 4 s, type
      `chatoverlay`: the panel comes back and stays, and a new shell finds
      it running. Close it, then `chatuninstall` and `chatinstall`: a new
      shell starts it again.
  19. **New code restarts it.** With the panel up, change a file under the
      tool folder's `src` (a `git pull`, or a copy over it): within a
      minute and a few seconds the panel goes and comes back at the same
      place, and `overlay.log` reads
      `the code on disk changed - restarting on it`. With the console open,
      or a slider or an edge held, it waits until that is over.
  20. **A full screen.** Play a video full screen, start a game in
      exclusive full screen, and a slideshow: the panel goes within a
      second, the tray icon stays, and it comes back when that ends. Note
      any app that hides it while not full screen (Windows' busy state).
      The bar goes and comes back with it.
  21. **Stretched into Recent.** With a few chats open, drag the bottom
      edge down: the open chats not drawn come first, then Recent lines,
      newest first, one per line's height; past the last one the panel
      grows no further. Drag back up: the Recent lines go first, then
      rows. Let go and open the settings box: its Recent chip is lit for
      0, 5 or 10, none for another count, and `config.json` has the new
      `recent`. With Recent off, a stretch brings Recent lines back. Near
      the screen's foot, the top edge dragged up brings back the cut rows,
      then the Recent lines, one at a time, the bottom held.
- **S25, a new chat from `claude -p`** - half run. Claude Code 2.1.281 took
  `claude -p --session-id <uuid> --name "chatq spike"` in a scratch folder:
  the init line carried that id, the transcript landed at
  `projects/<slug of the folder>/<id>.jsonl` exactly as `Get-ChatSlug`
  predicts, its first record is a `custom-title` with the name, and the
  index reads it as that title (`renamed`). Its records say
  `entrypoint: sdk-cli`. The prompt itself got `ECONNREFUSED` - the shell
  that ran it had no network - which chatq reads as a network drop. Still
  open: **does VS Code's chat list show such a chat** after the window on
  that folder reloads? If not, the console's Write to this chat, or
  `claude --resume <id>` in a terminal, is the way in; the README would say
  so. *Answered by S37: it does not - a first record saying `sdk-cli` hides
  a chat from Claude Code's lists for good. The open chip offers such a
  chat in a terminal (CHANGELOG, 0.8.1); listing it is in FUTURE_WORK.*
- **S26, the console by hand on Windows.** What the off-screen test cannot.
  **Since the console became the panel's own window (CHANGELOG, 0.7.2)**
  item 11 is superseded - it opens from the panel's corner, only its size
  kept - and in item 1 the panel is the console while it shows; S33 items
  28-34 check the mode itself. The rest stands.
  1. Each way in opens it: the maximize button on the overlay's bar, Open
     console in the tray, Ctrl+Alt+Shift+Q, `chatconsole` from a shell (it
     may only flash its taskbar button - Windows keeps the focus where you
     were), and `chatconsole` with no overlay running, which starts one.
     The overlay's panel never takes focus throughout.
  2. Dropping files from Explorer onto the prompt makes chips, and a big
     one shows `copying` without the window stalling; dropping a folder on
     + New chat's folder box fills it in.
  3. Win+Shift+S, then Ctrl+V in the prompt: a `clip.png` chip. Ctrl+V of
     files copied in Explorer: a chip each. Ctrl+V of text: text.
  4. Typing Korean with the IME in the prompt and the search box.
  5. Send (Next) into a chat open and idle in VS Code: it runs within
     seconds, the window offers the reload, and the reply is there after it;
     the console shows the job done with its reply.
  6. Send (Next) into a chat working in VS Code: it waits, and goes within
     about 30 s of that chat going idle.
  7. + New chat in a folder: the job runs, a window on that folder is
     offered the reload, and the chat is in its list afterwards (S25).
  8. At a reset, Continue all queues one per cut-off chat, and the orange
     rows on the overlay turn into their jobs, ahead of a prompt queued
     In turn for another chat.
  9. Cancel on a running job stops it within seconds; Remove asks twice;
     an edit to a waiting prompt is what gets sent.
  10. Close the console mid-sentence with a file attached, restart the
      overlay (`chatinstall`, or `chatoverlay -Stop` and `chatoverlay`), and
      open it: the chat, the text and the file are all still there.
  11. Drag it to a monitor at another scale, resize it, close and reopen:
      it opens where it was, the size it was.
  12. Typing stays smooth with the collector running behind it.
  13. **Maximize** in the header, and a double-click on it: the console
      fills the monitor it is on, the taskbar still showing, no grip;
      **Restore**, or a double-click again, gives back the size and place
      it had. Left maximized, **← Panel** then the console again: it opens
      maximized, and **Restore** gives the size it was left at.
  14. A waiting Claude job's **Mode** and **Model** chips in its details:
      a click fills the chip, the status line says it, and the run's
      `--permission-mode` and `--model` in its log are those. **Open in VS
      Code** on a waiting job whose chat exists: the chat opens in its
      window as the overlay's open chip opens it.
  15. `chatq -New .\some-folder 'Scratch' -Prompt 'say hi'` from a shell
      in its parent: the job is queued as + New chat queues one, and after
      its run `chatq` with the first 8 of the id it said picks that chat.
- **S27, at the next lapsed subscription:** what `claude -p` prints. On
  2026-09-23 one read as `Claude is logged out` — every 401 and 403 did — and
  the CLI's words were not kept, so the shape is unknown.
  `tests/fixtures/stream/auth-403.jsonl` guesses a 403 `permission_error`. The
  watcher log's `error text:` line now keeps the whole error, type and all, to
  check it against; `codex-auth.jsonl` is a guess the same way.
- **S30, showing a chat fresh in a real window.** Everything 0.6.0 does in
  VS Code was driven through stubs only. Use throwaway chats, with the 2.1.0
  extension installed and the window reloaded once so it runs it. **Since
  chats open as tabs (CHANGELOG, 0.7.2)** there is no Reload Webviews and
  no chip that only focuses: items 1-3, 10, 14 and 15 assumed one or the
  other and are superseded, kept for what they asked; 16 is answered. S33
  checks what replaced them.
  1. **Auto show.** *Superseded: the chat now opens in a tab, and nothing
     redraws the side bar.* `quietMinutes` 1, one window on exactly the
     folder, the chat idle in the side bar. Queue a prompt and leave the
     PC. The side bar shows the run, still on that chat after the redraw;
     `watcher.log` has one `show: ended idle chat process` line; the
     window's other idle chats start again when picked; a terminal's
     scrollback is intact.
  2. **Show it, nothing working.** *Superseded: Show it opens a tab
     whatever is working.* The same, within seconds of the click;
     the status bar says it is checking; the old pid is gone. Before the
     click, type a line into the input box of another chat in that window
     and do not send it: is that draft still there after Reload Webviews?
  3. **Show it, another chat working** (a workflow running in another chat
     of that window). *Superseded: a tab is the way whenever the old
     process is gone, whatever else works - where it is not, a reload is
     offered - and the status bar no longer says why.* A fresh editor tab
     opens with the run, the status bar says why, and the workflow
     finishes.
  4. **A stale editor tab.** The chat open in a tab, a run into it, then
     Show it. That tab closes and reopens fresh, and no other tab closes.
     Note the `viewType` and `label` the `chat manager` output channel
     logged for a Claude tab. A title over 25 characters is S33 item 4.
  5. **The process of the chat on screen ends.** What does the side bar
     show then - nothing, a banner, an error? Is an unsent draft in its
     input box lost? Typing gets a reply that knows the run, from a new pid.
     This decides whether a present user's process may be ended at the
     run's end, as an away one's is.
  6. **The chip.** A 1 s rest after moving onto a row shows **open** (400
     ms since 0.7.2, `chipDelayMs`; S33 item 18); a sweep shows nothing. A
     pointer left parked where a chip comes up never opens anything with
     its next click. Clicks elsewhere on the panel go through, and the
     keyboard focus stays where it was. The chip is in neither Alt+Tab nor
     the taskbar. A click brings the window forward, or only flashes it on
     the taskbar: note which.
  7. **`code` from where the overlay runs.** Start the overlay from a VS
     Code terminal, and from a Claude Code session's shell: `code` exits 0,
     with no ICU error. Half answered: from a Claude Code session's shell
     the running install's `code --version` exits 0 (S29's ICU crash was a
     broken second install). The chip's own `code -n` is still to see.
  8. **`code -n <folder>`.** On a folder already open it brings that window
     forward and opens no second one. With no window on it, it opens one and
     the chat shows as the window starts.
  9. **A folder open only inside a multi-root window.** The chip gives the
     balloon for 25 and opens no second window; check that
     `Test-ChatWindowExact`'s title rule told it right, also with a
     `window.title` of your own, and with a profile other than Default
     active in a window exactly on the folder (its name then follows the
     folder's in the title): that one is brought forward, not 25.
  10. **The chip on a working chat.** *Superseded: the chip ends nothing
      and never only focuses. A working chat's one tab here is brought
      forward; one working outside the tabs is not opened at all (S33 item
      11).* It only focuses; the turn is not cut.
  11. **The chip on a chat a terminal `claude` holds.** The balloon, and
      nothing opens - also while that `claude` is mid-turn.
  12. **The host pid.** The output channel logs `activated in extension host
      <pid>`; it equals the parent pid of that window's `claude.exe`, which
      is what `hostPids` names.
  13. **Later versions.** On Claude Code 2.1.282 or later
      `claude-vscode.primaryEditor.open` still exists and takes a session
      id; a failed `executeCommand` is logged to the output channel. *Since
      0.8.1 the open is `claude-vscode.editor.open`, pinned to a tab (S39);
      a Claude extension before 2.1.281 still gets `primaryEditor.open`.*
  14. **Other web views.** *Superseded: nothing runs Reload Webviews. The
      busy judgement's blind spot for Codex stands.* A Codex chat working
      in the same window during Reload Webviews: is it cut off? And does
      the busy judgement see it? For Codex it has only the rollout's write
      time (`Test-ChatIdle`), so a turn quiet on disk for longer than the
      judgement looks back may read idle.
  15. **A stale cache on focus.** *Superseded: the chip opens a tab, which
      a chat no process held loads from disk (S33 item 2).* A chat whose
      process ended on its own, then a run into it, then the chip. Does the
      side bar show it fresh? If not, an open that no process held should
      use Reload Webviews too, when nothing is working.
  16. **`primaryEditor.open` while the same chat shows in the side bar.** A
      second surface, or only a focus? *Answered from the Claude extension's
      code (2.1.282): a second surface with a second process - it never
      looks at the side bar. S33 item 3 watches it.*
  17. **Optional - decides deletes and new chats.** After `chatrm` in an
      exact window, does Reload Webviews drop the chat from the history, with
      no stub written back? Does `editor.open(<new id>)` show a chat the list
      does not have yet?
  18. **Who started background work.** Queue a prompt that starts a
      background agent or a workflow into a chat idle in the side bar, with
      you at the PC. Its `async_launched` record in the transcript says
      `"entrypoint":"sdk-cli"` (read that key only), and Show it afterwards
      ends the old process rather than reading the chat as held. While the
      run goes on, `sessions/` has a file for the `claude -p` process: note
      its `kind` and `entrypoint` (a kind not `interactive`, or an `sdk-*`
      entrypoint, is what `Test-ChatPrintLive` counts on - S38 item 5 saw
      `interactive`, `sdk-cli`; with no file at all, only the queue tells
      chatq a run is under way). Then run your own
      `claude -p --resume <id> "..."` into the same chat from a terminal, and
      read the `entrypoint` its records carry: `sdk-cli` is what
      `Get-ChatBackgroundTasks -SkipPrint` goes by.
  19. **Pointing straight at the overlay's buttons.** With them hidden, move
      the pointer from elsewhere on the screen directly to the spot above the
      panel's top-right corner and rest there: they come up under it in about
      a third of a second, and a click there works. Sweep the pointer across
      that spot without stopping: nothing comes up, and a click on the window
      underneath lands there. Drag an editor tab or a file across it, pausing
      there with the button held: nothing comes up, and the drop lands in the
      window underneath.
  20. **The chip after a Show it not taken** (CHANGELOG, Unreleased). A
      chat idle in a tab, the handover off and
      `chatManager.autoReloadAfterRun` false (else Show it runs by itself),
      a prompt queued into it: **Not now** on its Show it, then the chip on
      its row.
      The tab closes and opens again with the run's turn in it, and **Chat
      Manager: Show log** has `its run's Show it was not taken here - shown
      its way`; the chip again only brings the tab forward. Then the same
      with the tab closed by hand before the chip: one new tab, no word of
      a side bar copy. And `chatrm` of another chat within 2 s of a run's
      end: both the run's offer and the delete's come.
- **S31, the one-line installer from GitHub's zip.** Checked here only in
  Windows PowerShell 5.1, against a local zip laid out as GitHub's archive
  is - one `VS-code-chat-manager-main/` folder - with a scratch profile and
  empty chat homes. After the push that brings `src/`, with
  `$env:CHAT_MANAGER_DIR` on an empty folder: it prints `downloading`, the
  folder holds the script and every part in `src/`, `data/download/` is
  gone, and `chat` works in that shell. In PowerShell 7 too. After the
  0.7.0 push on 2026-09-25, GitHub's own zip was checked: its loader is
  0.7.0 and every part the loader lists is in `src/`, and
  raw.githubusercontent.com already served the new `install.ps1`. The full
  run, `chatinstall` included, is left for a spare Windows user, since here
  it would write this machine's profile.
- **S32, the Marketplace extension** (docs/marketplace-spec.md). Checked here:
  `vsce package` packs 0.7.0 - the loader and all 14 parts in `payload/` -
  and, against this machine's own profile, the profile step's two read-only
  calls answer right (the line is there; the policy is RemoteSigned). Spike
  M2 on 2026-09-25: neither `vs-code-chat-manager` nor "VS Code Chat
  Manager" is taken - the page for the ID is a 404, and the Marketplace's
  search for "chat manager" has neither. 0.7.0 was uploaded by hand on
  2026-09-25 and is live; the package step passed on GitHub's runner for
  the first time with that push. **An install from a VSIX is pinned** and
  never updates by itself (docs/marketplace-spec.md, M4). Turn **Auto
  Update** on for it before items 2 and 6. Still to see, in Windows
  Sandbox or a spare Windows user:
  1. **A clean install from the Marketplace:** the scripts in
     `~/Tools/VS-code-chat-manager`, the profile question, then - from
     `Restricted` - the policy question, and `chat` in a new terminal.
  2. **An update, 0.7.0 to 0.7.1**, with three windows open: one window
     copies, the files are replaced, the watcher hands over after its job
     and the overlay restarts, and the update note says terminals keep the
     old commands.
  3. **This machine:** the folder is a git checkout, so nothing is written;
     at another version it says so once. Half seen on 2026-09-25: the log
     reads `setup: none - carries 0.7.0, ... has 0.7.0 (in a git
     checkout)`. The message waits for versions that differ.
  4. **The old extension** (spike M3): the new one leaves requests to it,
     one window offers to uninstall it, `workbench.extensions.uninstallExtension`
     takes a copied-in, unpublished extension away, and the reload finishes it.
     The first two were seen on 2026-09-25: the log reads "every request is
     left to it", and `data/old-extension.lock` shows that one window asked.
     The uninstall itself is still to see. **The offer is easy to miss.** It
     came up as the window opened, slid into the notification bell, and sat
     there for four and a half hours. Asked to "uninstall the old one", the
     owner went to the Extensions view and removed "VS Code Chat Manager" -
     the new one - beside "VS Code chat manager - reload". The new
     extension's log shows the offer was never answered: "asking about the
     old extension failed: Canceled", as the extensions restarted. While
     both are installed the new one handles nothing, and the old 2.0.0
     ignores the overlay's open chip, so a missed offer leaves the chip dead.
     Reinstalled with `code --install-extension redaechan.vs-code-chat-manager`,
     which comes from the Marketplace and so is not pinned. **Then it
     passed:** after a reload, the offer was clicked, and six seconds after
     the new extension started, VS Code's log reads "Successfully
     uninstalled extension from the profile phal40lax78.chat-manager-reload".
     After the reload the offer asks for, the new extension no longer finds
     the old one. A few minutes later the new one was removed by hand once
     more and installed again. The two names, "VS Code Chat Manager" and
     "VS Code chat manager - reload", are easy to mix up.
  5. **A Remote-SSH or WSL window:** the extension runs on the local side.
  6. **Spike M4:** after a Marketplace update, do open windows restart the
     extension by themselves, or wait for *Restart Extensions*? The code
     says they wait (docs/marketplace-spec.md). Watch it happen at 0.7.1.
  7. **publish.yml, run by hand,** once M1's app exists: it prints the
     profile ID, and after that ID is a member, "The publisher accepts it"
     passes. Passed 2026-09-25, on the second run: the first was refused
     before the ID was a member, as it should be.
  8. **The first `v*` tag:** tests, publish, then a GitHub release with the
     VSIX and the changelog section, and the new version on the
     Marketplace page.
- **S33, chats open as tabs, and the overlay starting by itself**
  (CHANGELOG, 0.7.2). The extension's side was driven through stubs
  only, against what the Claude Code extension 2.1.282's code says its
  commands do. Throwaway chats, the new extension running in the window.
  Each click leaves `open: <id>` and `open: <id> ended <code>` in
  `data/logs/overlay.log`, a `show (chip) <id>: ...` line in `watcher.log`,
  and `open <id>: new|revealed|failed` under **Chat Manager: Show log**.
  1. **The chip on a chat open in a tab.** The chat idle in an editor tab,
     another tab in front. The chip brings that tab forward and opens none;
     the chat's `claude.exe` keeps its pid (its `~/.claude/sessions/` file
     is the same), and the log reads `revealed`. Click again: the same, and
     neither click leaves a view on "Claude Code process exited with code
     1" - the 2026-09-25 failure.
  2. **The chip on a chat with no process.** A chat no window holds - its
     tab closed, say. A new tab opens with the chat loaded from disk, the
     log reads `new`, and nothing is said about two places.
  3. **The chip on a chat in the side bar.** The chat idle in the side bar,
     with no tab. A new tab opens, and the window says the chat now runs in
     two places; `sessions/` has two files for the chat. Typing in the tab
     gets a reply; note what the side bar's view does once it is closed.
  4. **Show it and a stale tab with a long title.** A chat whose title is
     over 25 characters, open in a tab - its label is the first 24 and `…`.
     Queue a prompt into it while at the PC, and click Show it when the run
     ends. That tab closes and reopens with the run, no other tab closes,
     and the log names no `not closed` tab.
  5. **A fresh VS Code window starts the overlay.** `chatoverlay -Stop`
     and `chatoverlay -AutoStart on` (the stop alone holds until the next
     sign-in: a new window then logs `overlay: off`), then open a new VS
     Code window. Within seconds the panel is up and the extension's log
     reads `overlay: started`. A second window opened after it logs `overlay: running` and starts no second panel. A new shell
     prints `chatoverlay started` only when it was the one to start it.
  6. **`-AutoStart off` keeps it from starting.** `chatoverlay -AutoStart
     off`, `chatoverlay -Stop`, then a new shell and a new VS Code window:
     no panel, and the extension's log reads `overlay: autoStart is off`.
     `chatoverlay -AutoStart on` brings both back.
  7. **Resize by the edges.** Rest on the panel, then point at each side
     and corner: the pointer turns to that edge's arrows and a blue line
     marks the side it sizes; the middle of the panel still lets a click
     through. Drag the left side left: the panel widens, its right edge
     and the buttons stay where they were, the bar widening with it; back
     narrows it, down to 260. The right side: it widens to the right, its
     left edge held. The bottom: a row comes for each row's height of
     travel down, up to the chats open, then Recent lines (S23 item 21);
     up takes them away again. The top: the same upward, the bottom edge
     held. A corner does both. Collapsed, the top and bottom
     do nothing and the corners move only the width. With the panel at
     the foot of the screen and `+N more` under its rows, drag the top up
     a row's height: one more row, still at the foot. Let go: `config.json`
     has `width` and `maxRows` - and `recent`, when Recent lines came or
     went - and a restart keeps them and the panel's place. At 150%
     scaling as well as 100%, and unlocked as well as locked.
  8. **The sliders.** The settings box's Width and Rows move the panel as
     they move, the width with the right edge held, and `config.json` has
     both a second after release. Rows at 30 on a short screen: the panel
     stops at the screen's bottom and `+N more` counts the rest. Drag it
     by its bar half way down: it still stops at the bottom, from
     where it now sits, with fewer rows; dragged back up, the rows come
     back as it is let go.
  9. **`chatoverlay -Width 460 -Rows 12`** on a running panel: it says
     `width: 460` and `rows: 12 at most`, and the panel takes both at once,
     its right edge held. `-Width 200` or `-Rows 31` says the range, and
     nothing on that line is saved.
  10. **The chat's group ends unlocked.** With `claudeCode.lockEditorGroups`
      on (the default), open a chat with Claude Code's own Open in New Tab,
      so its new group shows the lock. Then the chip on another chat whose
      tab lands in that group: the lock is gone, and a file opened next goes
      into that group. Put a file tab in a Claude group, and the chip leaves
      that group's lock as it was; the log says so. With
      `"claudeCode.lockEditorGroups": true` in the user settings, the chip
      leaves every lock, and the log reads `group left locked:
      claudeCode.lockEditorGroups is set true`.
  11. **A chat working in the side bar.** Start a long turn in a side-bar
      chat, with no tab of it open, and click its chip: no tab opens, the
      window says it is working in the side bar, and the log reads
      `not opened - working here outside the tabs`. `sessions/` still has
      one file for the chat. Once the turn ends, the chip opens it (item 3).
  12. **An overlay started by the extension outlives its window.** Close
      the overlay and lift the close (`chatoverlay -AutoStart on`), open a
      VS Code window so the extension starts it (item 5), then quit that
      window, and all of VS Code: the panel stays up. If it goes with
      them, the launch needs `Invoke-CimMethod Win32_Process Create`,
      outside VS Code's job object, as S23 item 12 says.
  13. **A first install starts the overlay before its question.** In a
      spare Windows user, install the extension with no tool folder yet.
      The panel comes up while the profile question is still on screen, and
      the log reads `overlay: started` before any answer. Leave the
      question unanswered: the panel stays.
  14. **Chat Manager: Open chat... lists the chats.** In a window on a
      folder with a dozen chats: the picker is up at once, newest first,
      each by the title the Claude panel shows - a rename, Claude's own
      title, else the first prompt - with its age and `open`, `working`,
      `in a terminal` or `a queued prompt running` beside it, and none for
      a closed one. A side
      transcript is not listed. In a multi-root window each shows its
      folder. A second open of the picker lists the titles at once.
  15. **Open chat... on each kind of chat.** Pick a closed chat: a new tab,
      and the log reads `pick <id>: closed -> new`. One open in a tab here:
      that tab comes forward, nothing asked. One idle in the side bar with
      no tab: it asks, **Cancel** opens nothing, and **Open here too** opens
      a tab. One working in the side bar: it says so and opens nothing
      (another window's: item 36). One a terminal `claude` holds: it says so and opens
      nothing. One a queued prompt is going into (the console's Send with Next,
      picked mid-run): it says a queued prompt is going into it, not that it is
      in a terminal, and opens nothing; the log reads `running -> refused`.
      `sessions/` never gets a second file for a working chat.
  16. **Recent.** Close a chat's tab: within two seconds it heads the faint
      Recent list under the open rows, with its project and age. Rest on
      it: **open** comes, and a click opens it as a tab, and it leaves
      Recent for the open rows. The settings box's Recent **off** empties
      it at once, and **10** lists ten; `chatoverlay -Recent 0`
      does the same as off from a shell. On a short screen the lines that
      do not fit are left off, never the open rows.
  17. **The unread dot** (Windows only). Send a prompt in a chat, then
      bring another program to the front - not a VS Code window, not the
      terminal that runs the chat - and wait: as the turn ends, a small
      blue dot comes before its state, and the tray tooltip and the
      collapsed line say `1 new`. Reading the chat in VS Code leaves the
      dot; the chip opening it clears it (`ended 0` in `overlay.log`, or
      `25`, `40` or `41` - the request sent, the window perhaps not
      brought forward), and so does a new turn. Send another and stay in
      its VS Code window, or in any window of that VS Code, until it ends:
      no dot. The same for a terminal `claude`, with its Windows Terminal
      in front - one started in that Windows Terminal, not a console
      Windows handed off to it (its default-terminal setting), which
      cannot be matched and gets the dot anyway. The chip on a chat a
      terminal holds keeps its dot (`ended 20`). `chatoverlay -Stop` and
      start it again: no dots. Note how long a finish holds the panel up: the process
      snapshot is taken then, on the panel's thread, and `overlay.log`
      says so when it takes over 250 ms.
  18. **The chip's delay.** Rest on a row: **open** comes after about half
      a second, not a whole one, and a sweep across still shows nothing.
      `chatoverlay -ChipDelay 1500`: it waits a second and a half, at once,
      with no restart. `-ChipDelay 50` says the range and saves nothing.
  19. **Compact rows.** The settings box's Style **compact**: every chat is
      one line, with no prompt under it, and the panel is shorter. **full**
      brings the prompt lines back. `chatoverlay -Compact on` does the same
      from a shell, and `config.json` has `prompts` false.
  20. **Where a chat runs.** A chat in a VS Code panel has a small window
      outline after its dot; one a terminal `claude` holds has `>_`. A job
      row and a cut-off row have neither. `chatoverlay -Print` puts `>_`
      before the terminal's chat alone.
  21. **The width slider by the screen's left edge.** Drag the panel by
      its bar to the left edge of its screen, and slide Width up: the left
      edge stays on the screen and the panel grows to the right, the
      buttons at its right end and the bar as wide as it, less its ends.
      Let go, then restart the overlay: it comes back where it was left,
      as wide. On a second screen to the
      left of the main one as well.
  22. **Dragging down never lowers Rows.** With Rows at 8 and three chats
      open, drag the bottom edge down a little and let go: `config.json`
      still has `maxRows` 8. Down further: past the three open rows only
      Recent lines come, and `maxRows` stays 8 while `recent` takes the
      new count. Up one row's height from the start: with no Recent drawn,
      two rows drawn, and 2 kept; with Recent drawn, a Recent line goes
      first. Open the settings box after each: Rows shows what was kept.
      With no chat open, dragging up takes only Recent lines, and
      `maxRows` stays as it was.
  23. **A Cline tab is left alone.** With Cline installed, open its tab
      in the group where Claude tabs go and put it in front. Show it on a
      stale chat (item 4) and the chip on a chat with no tab: the Cline tab
      is never closed, and that group, holding it, keeps its lock. The log's
      `a Claude tab: viewType ...` line names a Claude panel, never Cline's
      `claude-dev.TabPanelProvider`.
  24. **Two chats of one label.** Rename two chats of one folder to titles
      that share their first 24 characters, and open one in a tab. Start a
      long turn in it and click its chip, then pick it from Open chat...:
      neither opens anything - the chip says it is working outside the
      tabs, the picker that it is working elsewhere - and the log reads
      `not opened - working here outside the tabs` and
      `working -> refused`. Once it is idle, the picker asks with
      **Open here too**, which only brings the tab forward. After a queued
      run into it, Show it leaves the tab and says to close it; the log
      reads `another chat of its folder has that label`. Rename one of the
      two apart: the chip and the picker bring its tab forward, and Show
      it closes and reopens it.
  25. **Show it while another chat works - on a Mac.** Show it's check
      leaves the chat's old process running (`kept`) only on a Mac; on
      Windows only a `sessions/` file vanishing mid-check does, which
      cannot be set up by hand, so `tests/extension-check.js` stands in
      a `kept` verdict there ("Show it finding another chat busy, this
      one not held (live or kept)"). On a Mac, queue a run into the chat
      at the PC, and start a long turn in another chat of the folder
      before clicking Show it: it warns that another chat in this workspace is still
      working and a reload now would cut it off, with **Reload anyway** -
      not that chatq could not end the old process. The log's `Show it`
      line reads `busy true, oldProcess kept`. With the chat itself
      working, it says that chat was working, as before.
  26. **The picker re-reads after its question.** A chat idle in the side
      bar of another window; pick it, and leave **Open here too** up.
      Start a turn in it from that window, then click Open here too: it
      says the chat is working elsewhere and opens nothing, and the log
      reads `working -> refused`.
  27. **The autostart switch from the palette.** With the overlay up,
      **Chat Manager: Overlay: start by itself...**, then **Off**: the
      panel closes, the window says so, `config.json` has
      `overlay.autoStart` false, and a new shell and a new VS Code window
      start none. Then **On**: said, and the next shell or window starts
      it. The extension's log reads `overlay autoStart: off, the overlay
      closed` and `overlay autoStart: on`.
  28. **Into the console and back, every way.** Note the panel's place,
      width and rows. Open the console by the maximize button: it grows
      from the panel's top-right corner - its right edge and top where the
      panel's were - with the prompt box taking the keys, its own header
      as before with no bar's room above it, and neither the bar nor the
      open chip come over it. **Esc**: the panel is back exactly where and
      as it was, its bar with it, lets clicks through again below the bar,
      and stays over the next window you click. Then in by the tray's **Open
      console** and back by **← Panel**; in by Ctrl+Alt+Shift+Q and back
      by it again; in by `chatconsole` from a shell and back by Alt+F4 -
      the overlay and its tray icon stay. The same with the panel collapsed,
      unlocked (its blue edge), and hidden in the tray - opened from the
      tray's item, Esc puts it back in the tray. With no overlay running,
      `chatconsole` starts one straight into the console.
  29. **Files from Explorer onto a covered console.** With the console
      open, click an Explorer window so it covers part of the console, and
      drag a file from it onto the prompt: a chip; a folder onto + New
      chat's folder box: its path. The console does not jump over Explorer
      by itself, and the drop works where it shows.
  30. **The taskbar and Alt+Tab.** While it is the console, the taskbar has
      a button for it and Alt+Tab lists it as `Charlie - console`, with Charlie's icon; either
      brings it back from behind another window. Minimized from the
      taskbar and restored, the draft is there. Back to the panel: no
      taskbar button, nothing in Alt+Tab, and the panel never takes the
      focus from the window you were in. Drag the header: it moves. Drag
      the grip at its bottom-right corner: it resizes, no smaller than 640
      x 420.
  31. **The hotkey on a covered console.** Open it, then click another
      window over it: Ctrl+Alt+Shift+Q brings it forward with the prompt
      box taking the keys - it does not go back to the panel. Pressed again
      now that it is in front: the panel. Ctrl+Alt+Shift+O while in the
      console: the panel too. With the console in front, `chatconsole`
      from a shell (or the tray's **Open console**): it stays the console.
  32. **A theme change mid-draft.** Type half a prompt, attach a file and
      pick a chat, then `chatoverlay -Theme light` from a shell (or Windows'
      own switch, under `system`): the console redraws in the new look with
      the text, the file's chip and the chat still there, and it is still
      the console.
  33. **The size, and a second monitor at another scale.** Resize it by
      the grip, go back, and open it again: the same size, grown from the
      panel's corner again. Unlock the panel, drag it to a monitor at
      another scale (100% and 150%), lock it and open the console there: it
      grows from the panel's corner on that monitor and stays on that
      screen, its text sharp; back gives the panel at its place there. A
      panel near that screen's left edge or low down: the console is pushed
      onto the screen, never off it. Note whether the size kept on one
      monitor holds as much on the other: it is kept in units, not pixels
      (`units` in `console-state.json`). Shrink it by
      the grip to its least on the 100% monitor, go back, move the panel to
      the 150% one and open it: at least 640 x 420 there too, its right edge
      still at the panel's, the **← Panel** button on the screen. Then open
      it on the panel's monitor, drag it by the header to the other one,
      and press Esc: the panel is back on its own monitor at its own place
      and width, its rows cut at that screen's foot, not left too tall.
  34. **Hide, collapse and quit from the console.** With the console open,
      left-click the tray icon: the console goes and the panel is hidden in
      the tray; click again: the panel, not the console. The tray's
      Collapse to one line: the panel, collapsed. Quit: the overlay closes,
      and `console-state.json` has the draft, the size and `max`, no `x`
      or `y`. With + New chat's **Browse** picker open over the console,
      press Ctrl+Alt+Shift+O and pick the tray's Collapse to one line:
      nothing happens under the picker; close it, and the console goes back
      to the panel, collapsed. Ctrl+Alt+Shift+Q under the picker does
      nothing.
  35. **Delete from the chip.** Rest on a Recent line: **open** and
      **delete** come. Click delete once: it reads **sure?** in red; wait
      5 s - it reads delete again, and nothing went. Click it twice: the
      tray says `Deleted "<title>".`, the transcript and its leftovers are
      gone, the line leaves Recent on the next pass, the log reads
      `delete: <id> deleted`, and the window offers its reload. On an open
      chat idle in a VS Code tab, and on a cut-off one: delete comes, and
      deletes the same way. On a chat at work, waiting on you, or run by a
      terminal `claude`: delete is there, greyed, with no hover, and a click
      does nothing - the chip is as wide as on an idle row. Rest on an idle
      chat, start a turn in it, then click delete twice: the tray says it
      is working, and nothing goes.
  36. **Open chat... across windows** (Windows). Two VS Code windows on
      one folder, A and B. Open a chat in a tab in B, and pick it from
      Open chat... in A: the picker reads `open in another window`, and
      the question has **Show it there** first. Click it: A says it was
      handed to the other window, and B brings that tab forward - the log
      in A reads `open -> handed to <B's host pid>`, B's reads `open
      <id>: revealed`. Start a long turn in it in B, then pick it in A:
      no question, handed the same way. Move the chat to B's side bar,
      idle: picked in A, Show it there opens a tab in B and B says the
      chat is in two places. Pick it in A again, and with the question up
      close its tab in B: Show it there opens it in A from disk, nothing
      handed. Pick a chat in A's own side bar: `open in
      this window`, and the question names the side bar. Each pick costs
      about a second the first time - one PowerShell - and the picker
      comes up at once regardless.
  37. **A stale registry entry.** Kill a chat's claude with Task Manager
      (End task on the `claude.exe` under that window's Code), then start
      a few programs until one gets its pid - `Get-Process -Id <pid>`
      answers - leaving `~/.claude/sessions/<pid>.json` in place. Open
      chat... lists that chat with no state, and opens it from disk.
  38. **The queue in the status bar.** Queue a prompt for later
      (`chatq -At 16:05 ...`): within 5 s every window reads `chatq 1
      queued · 16:05` at the left of its status bar; a click opens
      `data/queue.md` in the preview. `chatqrun -Stop`: `· watcher
      stopped`. Run it, and while it runs queue another: `· after #<n>`.
      Queue one into a chat whose tab you are in, nothing else queued:
      once its handover finds you there,
      `· waits for you to leave its tab`, as the board says it - no
      time. Empty the queue: the item goes.
  39. **A tab with no process.** Open two titled chats in tabs, plus an
      untitled new tab, then reload the window and type in neither:
      within a few seconds `data/open-tabs/<the extension host's pid>.json`
      lists the two titled tabs and not the untitled one, and the panel
      shows both as idle rows, out of Recent, the window mark after the
      dot. Their chip opens each, bringing its tab forward. Close one tab:
      within about 2 s its row goes and the chat is back at the head of
      Recent. Rename a third chat to share a tab's first 24 characters:
      that tab's row goes. The phone board lists the rows too, with the
      overlay running and closed.
      Quit the window: the file goes.
- **S38, a chat Claude Code hides, in a real window** (CHANGELOG, 0.8.1).
  S37 read the rule in Claude Code's code and ran the CLI; the extension's
  side went through stubs only. Each open leaves `open <id>: ...` under
  **Chat Manager: Show log**.
  1. **The chip on a chat hidden by its tail.** A chat whose first prompt
     is a screenshot, and a queued prompt run into it by a copy from before
     0.8.1, so its last records say `sdk-cli`: the side bar's history
     leaves it out. Its row's open chip: a tab with the chat, not a blank
     one; the transcript ends with one `chatq-listed` line and keeps its
     write time; the log reads `listed again`, then `open <id>: new`; the
     history lists it again.
  2. **A queued prompt now.** Queue one into that chat, or answer it from
     the phone: `watcher.log` reads `listed again` as the run ends, and the
     history still lists it.
  3. **A chat hidden by its head** - any chat + New chat made. The chip
     opens no tab and offers **Open in a terminal**; the terminal runs
     `claude --resume <id>` in the chat's folder and shows the chat. **Not
     now** leaves nothing open. Start a queued prompt into it, then answer
     **Open in a terminal**: no terminal, and the window says it runs by
     now.
  4. **+ New chat's window.** After its first run, the window on that
     folder names the chat and offers no reload.
  5. **While a run writes to it** (not driven here: the chip, the picker
     and Show it each turn such a chat away first, so only a race reaches
     it). Note whether a `claude -p`'s entry in `~/.claude/sessions/` says
     `busy` while it runs, and its `kind`: the extension's hold, and
     `Repair-ChatListed`'s, rest on `busy`, since Claude Code 2.1.283's
     code gives such a run the kind `interactive`. *Seen 2026-09-27, a
     phone reply's run: `kind` `interactive`, `entrypoint` `sdk-cli`,
     `status` `busy` (FUTURE_WORK).*
  6. **A job parked on input, answered in the chat.** Answer a chat from
     the phone with something its mode denies, so the job parks and the
     row turns amber (`#n needs you`). Then type into that chat in VS Code:
     within a couple of seconds the row takes the chat's own state,
     `overlay.log` reads `job <id> skipped: answered in the chat`, and
     `chatqlist` no longer lists the job as needing you. The same with the
     chat's tab closed after typing, and with the overlay off: then
     `chatqlist` itself skips the job as it lists.
- **S40, the tab the overlay opens has its header** (CHANGELOG, 0.8.1).
  S39 read it in Claude Code's code; the extension's side went through
  stubs only. With the fixed extension installed and the window reloaded:
  1. **A new tab.** Close any tab of a chat, then open it from the
     overlay's chip or **Chat Manager: Open chat...**: the tab shows the
     chat's title, **Session history** and **New session** at its top, in
     the same group the old way used - a group of Claude tabs, else the
     active one - no new group made, none locked, and
     `claudeCode.preferredLocation` unchanged in settings.json.
  2. **An edit to approve** in that tab shows its diff, which a tab from
     before the fix never did. Note where: with the chat's group unlocked
     (the default here), in that group in front of the chat.
  3. **A tab from before the fix.** Opened from the overlay by an older
     copy, it has no header, and a reload keeps it so. The chip only
     brings it forward; closed and opened again, it has the header.
  4. **Show it** on a stale tab: closed and opened again, with the header.
  5. **A reply from the phone into a chat open here.** At the PC, with
     the chat's tab open and idle, answer its alert from the phone: as
     the run ends the tab closes and opens again by itself - no Show it?
     question - showing the run's turn, and **Chat Manager: Show log**
     reads `ran <id> by itself: Show it, its idle process here`. Type in
     the tab: the answer knows what the run did. Then the same with
     another chat of the window working meanwhile.
- **S41, the ask at a real limit's reset** (CHANGELOG, 0.9.0). The
  self-test drives it with stood-in cut-offs, balloons and notifications;
  nothing here has met a real limit with it. Let the usage limit cut off
  two chats - one with its tab closed, one left open in a VS Code panel -
  and a third in a terminal's `claude`.
  1. **Before the reset.** The usage line reads `5h 100% resets 13:00` in
     red, the collapsed line and the tray tooltip say `resets 13:00`, and
     the orange rows are there. Nothing asks yet. The time goes from the
     line once the reset passes.
  2. **Five minutes after it.** One toast, `Charlie - limit over at 13:00`,
     naming the two chats and not the terminal's. A banner at the foot of
     the header; its tooltip lists the two and names the terminal's as
     left to it. `overlay.log` reads `ask: 2 cut-off chats can continue
     after the 13:00 reset - ...`. Note whether the panel chat was already
     continued by Claude Code itself in those five minutes (spike A1 of
     docs/auto-continue-spec.md), and if so, that it is not asked about.
  3. **The toast's click** opens the console, with the chats listed and
     `limit over at 13:00 - 2 can continue` in the Cut off header; it
     answers nothing.
  4. **The banner's chip.** Rest on the banner: **continue 2** and **leave
     them**. A parked pointer answers nothing. **continue 2**: two jobs,
     the watcher up, a balloon `queued 2 continues - ...`, the banner and
     the tray's items gone; `data/auto/` holds two `.json` answered
     `continue` with their job numbers.
  5. **The tray's items** and **Leave them**, at the next limit: the same
     from the tray's **Continue N cut-off chats**, and **Leave them** from
     the tray and from the console - the rows stay orange, nothing is
     queued, and the console's **Continue all** still continues them.
  6. **A restart.** `chatoverlay -Stop` and start it during an ask: no
     second toast, the banner still there.
  7. **Away.** With the phone set up and you away, one `limited` alert,
     `limit over at 13:00 · 2 chats it cut off can continue - answer on
     the PC`; its page offers Status alone.
  8. **The setting.** The settings box's **Cut off** → **Leave**: nothing
     asked at the next limit, the rows only orange; **Ask** again. The same
     with `chatq -AutoContinue off` and `ask`, a running overlay following
     each at once; `config.json` has `autoContinue` at its top level.
     **Continue** is the automatic mode, S42.
  9. **macOS** (untested there): the `CQ` menu's two items at its top
     during an ask, a notification once, and the lines view's
     `resets 13:00`.
- **S42, auto-continue with a real limit** (docs/auto-continue-spec.md,
  whose S35 this is; CHANGELOG, 0.9.0). With the switch on
  (`chatq -AutoContinue on`), on a real subscription, with the limit
  reached on purpose: a model's weekly limit, the reset brought within 24 h
  by waiting, is a cheap way.
  1. **A panel chat cut off and left open, you away.** Its row reads `#n
     auto HH:mm`; the phone gets `limited` with **Don't continue**; the run
     waits till 5 minutes past the reset, then goes; the window shows it by
     itself. `watcher.log` has `held: auto-continue waits until`. No reset
     ask comes.
  2. **The same with you at the PC:** **Show it** is offered, in the words
     `chatq continued ... after the usage limit reset`.
  3. **A chat whose tab was closed:** continued a minute after the reset.
  4. **A terminal's chat:** chatq leaves it (`· terminal`), and Claude
     Code's own wait continues it. Exit that `claude` before the reset with
     the chat still cut off: the next look queues one.
  5. **Don't continue** from the chip, from the console, and from the
     phone's two taps. Each time the row reads `· skipped`, and nothing runs.
     A press on don't continue dragged onto open does nothing.
  6. **The switch:** the settings box's **Continue**, **Ask** and **Leave**,
     the tray item, `chatq -AutoContinue on|ask|off` and **Chat Manager:
     Auto-continue cut-off chats...** each set it, and each shows in the
     others. Turned on with an old cut-off on screen: not queued, and the
     balloon once; the first continue queued, its own balloon.
  7. **Look,** with the settings box open, with the panel at the top of
     the screen and at its foot, at the default width and compact: the
     seventh row's three chips all there, the box on the screen; the chip
     over an auto row left of its words.
- **S45, a new version installed while the window's chats work**
  (CHANGELOG, 0.9.0): the steps are under
  [A new version, and the chats a reload stops (S45)](#a-new-version-and-the-chats-a-reload-stops-s45),
  in a VS Code of its own - never the one the work runs in.
- **S46, Claude's questions against the real CLI** (CHANGELOG, Unreleased):
  the spike is recorded under
  [Claude's questions from the phone (S46)](#claudes-questions-from-the-phone-s46),
  and its items 1, 2 and 4 - the dialog closing in VS Code, a hook picked up
  by open chats, the terminal - are still open, in Tier 2 with S47, which
  does them:
  [Claude's questions from the phone (S47)](#claudes-questions-from-the-phone-s47).
- **S48, a queued run takes a real tab's place** (CHANGELOG, Unreleased).
  The self-test drives both halves with the other stood in for; no real
  window has answered a handover yet. **Chat Manager: Show log** and
  `watcher.log` say each step.
  1. **The close's timing.** A chat idle in a tab, you away (or the tab
     behind another), a prompt queued into it: the window's answer within
     3 s of the handover (`handover <sid8>: <pid> closing`), the chat's
     process gone from `~/.claude/sessions/` within 15 s (`tab closed
     after N s`), the live view where the tab was, and no tab reading
     *Claude Code process exited with code 1*. The same with the tab in
     front of you: nothing closed, the notice once, **Hand over now**
     sending that job alone. Then the end: close the live view, stay
     away until the run is over - the chat opens where its tab was on its
     own (`the chat where its tab was - nobody at the PC`); queue another,
     leave while it starts and come back before it ends - asked, **Open
     chat**, nothing opened (`its live view closed - asked`).
  2. **Show it reveals by the session id.** With several Claude tabs
     open, Show it on one of them brings that chat's own tab forward
     every time, before it closes it; so for a tab restored by a window
     reload and not yet clicked (not revived), where the reveal goes by
     label - note whether it still brings the right tab.
  3. **The live view on a real long run** - a prompt that runs tests and
     edits files for 10 minutes or more: rows keep up within a couple of
     seconds, tool clocks tick, the todo stays pinned, an edit's `+N -M`
     matches the diff, a subagent's rows indent, and the end turns the
     view back into the chat with the run's last turn in it. Cancel once
     on another run: the modal, then `failed - cancelled`. A window
     reload mid-run brings the view back.
  4. **A panel's channels.** In one Claude tab switch from chat A to chat
     B with **Session history**, then close the tab (or hand it over):
     does A's process leave too? `~/.claude/sessions/` before and after.
     If it does, closing a panel ends more than the chat named
     (FUTURE_WORK, "Closing a Claude panel may end another chat's
     channel").
  5. **`/effort ultracode` in a VS Code tab** - answered 2026-09-29, on
     2.1.284: typed in a tab it switches Ultracode on at any level
     (`Ultracode on (this session only) ... Effort stays xhigh`), and a
     typed `/effort max` after it leaves it on (`Set effort level to max
     (this session only)`), while the effort menu offers Ultracode only
     at max. So a reopened tab is pre-filled with it.
  6. **A typed `/effort high` in a VS Code tab:** does its answer say
     `(this session only)` or `(saved as your default for new sessions)`?
     The reopen notice has you type the level when Ultracode was lost
     too, and promises only that it leaves Ultracode on (FUTURE_WORK,
     "Ultracode and a session-only effort on a tab chatq opens again").
  7. **The pre-fill**, with `chatManager.keepSessionSettings` off - on,
     the default, S50 has it. A chat idle in a tab after `/effort ultracode` and
     `/effort max`, you away, a prompt queued into it: after the run the
     chat's new tab holds `/effort ultracode`, and the notice says so and
     names `/effort max` to type after; Enter there answers `Ultracode on`.
     With `claudeCode.useCtrlEnterToSend` on, the notice says Ctrl+Enter.
     Show it on the same chat: the same. **Open chat** clicked on the
     handover's notice after opening the chat by hand: no pre-fill, and
     no notice.
  8. **Show it right after an extension-host restart.** A chat idle in a
     tab, **Developer: Restart Extension Host**, then Show it on it within
     30 s: the log says `this extension host: restart` at activation and
     `judged only, nothing ended` for a new tab, and no tab reads *Claude
     Code process exited with code 1*. **Developer: Reload Window**
     instead: `this extension host: reload`, and Show it as ever. A lost
     tab behind others, selected only after 30 s, is not covered
     (FUTURE_WORK.md: "A tab Claude Code reopens late").
  9. **A watch tab not brought back.** A run handed over, a window reload
     mid-run with its live view in a tab behind another, and the tab left
     unclicked: 10 minutes after the run ends the log says `its watch tab
     not brought back in 600 s - put back without it`, and the window asks
     **Open chat**; clicking the watch tab after it shows the end with
     **Open chat**.
- **S49, a queued run's command line against the real CLI** (CHANGELOG,
  Unreleased). The fake agent only records the environment and the flags.
  1. **Background tasks off.** A prompt that asks for a long test suite in
     the background: the run's log offers no `run_in_background` - the
     Bash call has none, the command runs in the turn - a command past the
     old 2-minute default finishes, and nothing is killed after the turn.
  2. **Ultracode and a level.** A chat in auto mode with Ultracode on and
     `/effort max` in its tab, then a prompt queued into it: the run gets
     `--effort max`, and its `--settings` file `"ultracode": true`; its
     turns record `"effort":"max"` and it writes no `ultra_effort_exit`
     (`sdk-cli`), as a plain run does at its first prompt; its history
     reads `with Ultracode, at effort max, as the chat had them`; and a
     workflow the prompt asks for runs, unasked. The same chat in default
     mode: `--effort max` still, no Ultracode, and the history's
     `Ultracode left off (default mode asks before each Workflow)`.
     **Part answered 2026-09-30, on 2.1.285**, by hand with `claude -p
     --settings <file of {"ultracode":true}>` in a scratch folder: a new
     session writes `ultra_effort_enter` and runs at its `modelSettings`
     level (`high`); `--resume` with the same file writes no Ultracode
     record - the history says on already - and `--resume` without it
     writes `ultra_effort_exit`. So a queued run with neither record, into
     a chat whose history says on, ran with Ultracode, as that day's run
     into a panel chat did. That run went at `medium`, not `high`,
     unexplained.
  3. **Opened by hand after the run.** A chat with Ultracode on, a run
     queued into it with its tab behind others, and the run's end asked
     about (its live view closed): pick the chat from another tab's
     **Session history** within 30 minutes. The log has `run <id8> ended,
     the chat not opened again: Ultracode ... armed` and `spawn <id8>:
     carried Ultracode`, and the new tab's effort chip shows Ultracode.
     `tests/extension-check.js` makes that launch by hand.
- **S50, Ultracode and max carried into a reopen, in a real window**
  (CHANGELOG, 0.10.2). `tests/extension-check.js` stands in a fake
  `child_process` and makes each launch by hand; whether Claude Code's
  own launch goes through the hook is only seen here. A local window,
  Claude Code 2.1.284, `chatManager.keepSessionSettings` unset.
  1. **Show it.** A chat idle in a tab after `/effort ultracode` and
     `/effort max`, then a prompt queued into it beside the tab (the
     handover off) and **Show it**: the new tab's input box is empty, no
     notice comes, and its effort chip shows Ultracode and Max without a
     click. **Chat Manager: Show log** has `spawn <id8>: carried
     Ultracode, effort max` and `reopened <id8>: Ultracode, effort max
     carried`. The chat's first turn after it writes `ultra_effort_enter`
     and records `"effort":"max"`.
  2. **The chat put back after a handover**, and the live view's **Open
     chat**: the same.
  3. **Another chat within the minute.** Right after 1, open a different
     chat from Claude Code's own list: it starts as it would have - no
     Ultracode, its own level - and the log has no `spawn` line for it.
  4. **A later /effort.** In the reopened tab `/effort high`: `Set effort
     level to high (this session only)`, the chip following. And whether
     `/effort` can switch off an Ultracode that came from `--settings`
     (FUTURE_WORK, "Ultracode and a session-only effort on a tab chatq
     opens again").
  5. **Setting off.** `chatManager.keepSessionSettings: false`, then 1
     again: the input box holds `/effort ultracode` and the notice names
     `/effort max` to type after, as S48 item 7.
  6. **A remote window** (WSL or SSH), 1 again: nothing is carried and
     nothing waits - the input box holds `/effort ultracode` and the
     notice comes at once, as in 5; the log has no `spawn hook in` or
     `spawn` line.
  7. **Reload.** Reload the window after 1: the new window's log has
     `spawn hook in` right after `activated` - the hook sees the launches
     of the tabs Claude Code brings back - and 1 again carries as before.
  8. **A tab only revealed.** The chat's tab kept over a reload and not
     shown since, then a run into it and the chat put back: the open
     reveals that tab. Whether Claude Code starts its process as it shows
     is settled here - the log then has `spawn <id8>: carried` and no
     notice comes; else, about a minute on, the notice names both
     commands to type, and the log has `no launch of it within 60 s`.
  9. **Stale Ultracode is not carried.** A chat whose Ultracode was
     switched on before the window's last reload, or under an older
     Claude Code, and not since: `/effort max` in it, then Show it. The
     log has `spawn <id8>: carried effort max` - no Ultracode - and its
     chip shows Max alone. Run on 2026-09-30 with ac284315 before the
     fix, it carried Ultracode entered under 2.1.283 two days before.

### Permissions from the phone (S35)

**S35, the bridge against the real CLI** - ran once, 2026-09-27, five
`claude -p` runs on haiku in a throwaway folder (the spike's limit). What
it answered is recorded in the spec, section 12: an allow without
`updatedInput` runs the call as asked; a deny's message reaches Claude and
`permission_denials` carries `tool_use_id` (and no
`system/permission_denied` streams); a call past `MCP_TOOL_TIMEOUT` is a
tool error the model retries, never a deny, and claude cancels it; a bridge
that cannot start shows `failed` in `init` and ends the run at the first
prompt with `mcp__chatqpermit__decide ... not found` on stderr; the model
never sees `decide`; `SystemRoot` arrives; the bridge is up in 0.2-1.3 s.
**Still open, by hand:** the `//c/...` form of the data deny rules
(`acceptEdits` editing `data/`), elicitation under `host`, a call `auto`'s
classifier sends to a prompt, and two tool calls in one message.

### A new version, and the chats a reload stops (S45)

**S45, by hand, still to do** - never in the VS Code the work runs in (below).
In a VS Code of its own - `code --user-data-dir <scratch>\user
--extensions-dir <scratch>\ext` - with the Claude Code extension and
this one installed from a VSIX:
1. Start a chat that runs a background workflow or agent, and wait until
   its turn has ended and the work goes on.
2. Build a VSIX one patch higher and install it into that instance only:
   `code --extensions-dir <scratch>\ext --install-extension <vsix>`.
   Within 10 s the notice names that chat, "(background work running)".
   **Chat Manager: Show log** reads `installed: <v> - this window still
   runs <old>`.
3. **Reload when they're idle**: the status bar reads *reloads when 1
   chat is idle*. The chat keeps working; nothing reloads. Once its work
   reports back, within about a minute and a half the window reloads,
   the new version's log says `running ... <v>` - the step that matters:
   `restartExtensionHost` never got this far (the 0.9.0 review read VS
   Code 1.108.2's workbench, where it does not rescan) - the chat's tab
   comes back, and the terminals are still there.
4. Again with a turn running and **Reload now**: the turn ends there, as
   it would with VS Code's own button. `data/host-work/<old host pid>.json`
   named the chat before the reload; within a minute after it the overlay
   asks `VS Code restarted · 1 chat it cut off can continue`, and
   **continue 1** queues a prompt that says the window restarted
   mid-turn, which goes into the chat in its own mode. With **Later**,
   nothing happens and the same install is not said again.
5. A delete with `chatManager.autoReload` on while a chat of the window
   runs a workflow: no reload, and the warning names the chat.

**While developing chatq:** installing a VSIX into the VS Code the work
runs in ends every chat there - Claude Code's sessions, their permission
prompts, their workflows and agents - on that window's next restart or
reload; on 2026-09-27 it took this repo's own sessions down twice. Answer
the notice with **Reload when they're idle**, or try the extension in an
Extension Development Host (`code --extensionDevelopmentPath=<repo>\extension`)
or a VS Code with its own `--extensions-dir`, as above.

### Claude's questions from the phone (S46)

**S46, the spike against the real CLI** - part 1 ran 2026-09-28, part 2 on
2026-09-29, on `claude.exe` 2.1.283 from the VS Code extension, `--model
haiku` and `--tools AskUserQuestion`, a Node script playing the extension
(`--permission-prompt-tool stdio`, `can_use_tool`). Part 1, six runs, about
$0.20, with Node hooks: with no hook the host's answer reaches Claude; a
PreToolUse hook that answers skips the dialog, and one that waits holds it
back for as long as it waits - so the hook is a PermissionRequest hook, which
runs beside it; the host answering first wins and the hook's later answer is
dropped; the hook answering first wins, the CLI sends the host a
`control_cancel_request`, and Claude takes it; a hook killed at its timeout
changes nothing, and `Red, Blue` reads as both options. The hook's stdin
carries the session, transcript, mode and input, and no `tool_use_id`. Part
2, ten runs, the items a script can run:
1. **Item 3:** the `tool_use` line is in the transcript before the hook
   reads it.
2. **Item 5:** a plugin's `PermissionRequest` hook fires for
   `AskUserQuestion` and answers; a `timeout` of 43260 raises no error; one
   with none ran 75 s unkilled.
3. **Item 6:** in `plan` and `bypassPermissions` the hook fires with the real
   `permission_mode`, and the host is still asked.
4. **Item 7:** an edited label is taken; answers keyed to no question close
   the dialog with `The user did not answer the questions.`
5. **Item 9:** the registry says `waiting`, `input needed` all the while the
   hook holds the question; a `claude -p` run registers too.
6. **Item 10:** `powershell.exe -File` loads chatq in 4-8 s and 124-137 MB;
   its parent is Git bash, not claude; a kill at the timeout ends the whole
   tree; stdout holds the decision line only.

## Tier 2: other hardware

### Still to check on other hardware

- **S10, Join**, and **ntfy**: `chatnotify … -Test` reaches the phone, Hangul
  intact.
- **S24, the overlay on macOS** (never run):
  1. The panel and `CQ` appear, focus stays where it was, and any Dock icon
     flash is noted.
  2. Clicks go through it; it shows on every Space and over full-screen apps.
  3. Unlock, drag, Lock, and the position is kept.
  4. Rows update, and the `procStart` format in `~/.claude/sessions/` is noted.
  5. Hidden for ten minutes, it is current when shown again (App Nap).
  6. `kill -9` of the pwsh host takes the panel away within 20 s.
  7. `osacompile -l JavaScript data/overlay-mac.js` succeeds.
  8. Hangul draws.
  9. `-LiveUsage on` reads the keychain once, after the password prompt.
  10. `chatinstall` restarts it and `chatuninstall` stops it.
  11. `-Theme light`, `-Theme system` (then flip macOS's appearance) and
      `-Opacity 60` each show within a few seconds.
- **S36, a tool call approved from a real phone** (CHANGELOG, 0.9.0): the
  steps are under
  [Permissions from the phone (S36)](#permissions-from-the-phone-s36), and
  S35's items 5-8 are still open in Tier 1, under
  [Permissions from the phone (S35)](#permissions-from-the-phone-s35).
- **S43, usage heads-ups, quiet hours, voice and Tasker on a real phone**
  (CHANGELOG, 0.9.0): the steps are under
  [Usage heads-ups, quiet hours, voice and text from Tasker (S43)](#usage-heads-ups-quiet-hours-voice-and-text-from-tasker-s43).
- **S44, the phone board and the whole answer on a real phone**
  (CHANGELOG, 0.9.0): the steps are under
  [The phone board and the whole answer (S44)](#the-phone-board-and-the-whole-answer-s44).
- **S47, Claude's questions on a real phone** (CHANGELOG, Unreleased): the
  steps are under
  [Claude's questions from the phone (S47)](#claudes-questions-from-the-phone-s47).
- **macOS and Linux** are untested; the Unix branches are written but have never
  run.

### Phone alerts and replies (S34)

**S34, by hand with a real phone.** Android and Chrome, Join installed.
Each step leaves lines in `data/logs/replies.log` and `watcher.log`; a live
alert also in `overlay.log` and `outbox.log`.
1. **The page is served.** The repository's **Settings → Pages**: deploy
   from a branch, `main`, `/docs`. On the phone,
   <https://phal40lax78.github.io/Charlie-and-the-chat-factory/reply.html> opens
   and says the phone is not paired.
2. **The window.** `chatnotify -Setup`, the tray's **Phone alerts...** and
   **Chat Manager: Phone alerts...** each open it, and a second ask says it
   is open already. Paste a whole Join push URL: the device is picked out
   of it. **Find devices** lists the phone and the groups without the
   window stalling; **Send test** reaches the phone while the window stays
   live. From a pwsh 7 shell whose Windows PowerShell policy is
   `Restricted`, it still opens.
3. **Pair.** `chatnotify -Pair`: the push arrives; tap it, **Pair**, and a
   code shows on the phone. The same code comes up at the PC; `y`, and a
   `paired` push arrives. Pair again from the window: the phone warns that
   it is paired already, names the server and topic, and wants a second
   tap; confirm in the window this time.
4. **The way back.** `chatnotify -Test`, tap it, **Send a test reply**:
   `reply reached <PC> after N s` comes back as a push within about 15 s.
5. **Reply to a job.** Queue a prompt that stops on a permission prompt,
   and leave the PC past `quietMinutes`. On its `needs input` alert, type a
   prompt and **Send**: a `queued #n` push, the job queued in the chat's
   own mode (no `(phone's limit)` in the push), the old one skipped; with
   `chatnotify -ReplyMaxMode acceptEdits`, a chat in `auto` or above is
   queued in `acceptEdits` and the push says the phone's limit. On a
   `started` alert, **Stop** - two taps -
   stops the run within about 30 s. **Status** answers with the queue.
6. **A live alert.** `chatnotify` says the chats you run yourself are on,
   and the overlay running. Start a turn in a VS Code chat, leave VS
   Code in front and the PC alone: once `quietMinutes` pass and the turn
   ends, a `done` arrives. A permission prompt left 20 s gives
   `needs input`; its page offers only **Send** and **Status**. Send a
   prompt from it: the push says it goes once the prompt at the PC is
   answered, and after you answer it there, it does.
7. **A reply while the PC slept.** Send an alert, let the PC sleep, and
   send a prompt from the phone. Wake it: within about 15 s the watcher
   reads the reply and queues it; `replies.log` has the one line, not two.
8. **Off and on.** `chatnotify -Reply off`, then answer an old alert: the
   page says sent, and nothing runs. `-Reply on`: still nothing from that
   answer, and a new alert can be answered.

### Permissions from the phone (S36)

**S36, by hand with a real phone** (after S34): permits on
(`chatnotify -Permit on`); queue a prompt that needs `git push` and leave
the PC. The `chatq · permission` push names no command; the page shows it,
redacted where it should be. **Allow once** (two taps): the run goes on
within about 10 s and an `allowed` push follows. Again with **Deny** and a
note: Claude's reply quotes it, and the job is `done`. Again without
answering: after 10 minutes `needs input ... - no answer from the phone`,
and Allow then says too late. **Stop** from a `started` alert while a
request waits. At the PC: the toast and the phone both show it.

### Usage heads-ups, quiet hours, voice and text from Tasker (S43)

**By hand, with a real phone (S43):**
1. **A threshold.** With the overlay running and the phone away from the
   PC, let the 5-hour window cross 90%: one push, none on the passes after.
2. **Quiet hours.** `chatnotify -QuietHours` set to the next five minutes,
   queue a job that finishes inside them: no push then, one summary as the
   window ends.
3. **Voice.** `chatnotify -Say test`, then `-Test`: the phone says
   `chatq test`. A chat with a Hangul title and `-Say 'needs input'`: heard
   in Korean. If it is not, `language=ko` needs to be `ko-KR`
   ([Get-ChatqSayLanguage](src/phone-extras.ps1)).
4. **Tasker, route B** (README, Reply from Tasker): step 1's Flash shows
   the push's title and link; type `테스트 ok` in the dialog, the page opens
   with it in the box and the note under it; **Send**; a `queued #N` push.

### The phone board and the whole answer (S44)

**S44, by hand with a real phone** (Android Chrome, then an iPhone on
Safari 16.4 or later), after S34:
1. **The whole answer.** A job that ends `done`: tap the alert, and the
   answer shows above the box within a few seconds, Hangul and code
   blocks drawn. One over 4 KB sealed goes as an attachment and shows too.
   Three hours later, the same page says ntfy.sh dropped it; **Ask the PC
   for it** brings it back within about 15 s.
2. **The board.** `chatnotify -Listen always`; the bare page from a
   home-screen shortcut shows the board within 30 s, the overlay's rows as
   the overlay has them; **Older chats** adds the rest, a Codex thread
   among them. `chatoverlay -Stop`: the next board says the overlay is not
   running, and still lists the open chats.
3. **Acts.** Send to an idle chat: the ack on the page and a `chatq ·
   reply` push, the job in the chat's own mode - `acceptEdits` at most once
   `-ReplyMaxMode acceptEdits` is set. **Send now** on a queued
   job, **Skip** with two taps, **+ New chat** in a listed folder.
4. **Nobody listening.** `chatnotify -Listen alerts` with no alert out:
   the page gives `No answer from the PC` at 45 s.
5. **Budget.** `replies.log` has one line per act; after a day of use
   `down` in `replies.json` stays under 200.

### Claude's questions from the phone (S47)

**Still open, by hand** (S46 items 1, 2 and 4 - S47 does them), before
`-Ask on` is recommended: in real VS Code with the plugin installed, does the
dialog close when the phone answers; what does the panel show while the hook
runs (`statusMessage`, a spinner, nothing); does the CLI end the hook when
the PC answers first, or does the hook's own 5 s look; is a hook installed
while a chat is open picked up, and does `/reload-plugins` or a window
reload do it (the install line's words wait on this); and in the terminal's
`claude`, does the hook run beside its prompt and does its answer close it -
until it does, a terminal chat is declined `term`. **Item 8** waits for a
design of its own (FUTURE_WORK, "Questions in chatq's queued runs"): a queued
run with `--permission-prompts host`, a run-scoped `PermissionRequest` hook
and the MCP prompt tool - which is asked first, and does `localDisplayOnly`
deny before the hook can answer.

**S47, by hand with a real phone** (after S46's items above; Part A needs
none of it):
1. **Seeing it.** Make a chat ask and leave the PC alone for 5 minutes. The
   push says only `waiting on you: input needed (a question)`. The page
   shows the question, every option with its whole description, and `Answer
   it at the PC.`; the board from the bookmark shows the same card.
2. **Answering.** `chatnotify -Ask on`, and a new chat asks. Answer from the
   phone: within about 20 s the dialog closes and the chat goes on with that
   answer; the transcript's `answers` shows it and `replies.log` says
   `landed`.
3. **Two questions,** one a multiple choice and one answered with Other.
4. **The PC first.** Answer at the PC: the phone's Send is told `already
   answered at the PC`.
5. **The gates.** A `bypassPermissions` chat: read-only, `mode`. A question
   open before `-Ask on`: read-only, `hook`. A terminal chat: `Answer it in
   the terminal.`
6. **Off.** `chatnotify -Ask off`: the plugin is gone from `/plugin`, and
   questions still show on the phone. `chatnotify -Ask on -Manual` prints
   the block, and `chatuninstall -All` stops with a message until the hook is
   out of the settings.

## Review

v0.1.0 went through a four-angle review with a separate skeptic per finding;
the 30 confirmed defects are fixed. The v0.2.0 plan went through a design
critique before a line was written — 37 findings, among them leftovers removed
before the transcript was confirmed gone, network retries that dropped
themselves as "already continued", a watcher handoff that could leave nobody
watching, and StrictMode breaking at load. Each is fixed and, where a test can
hold it, in the table above.

The 0.4.0 overlay's buttons, collapse, refresh and usage waits went through a
three-angle review (WPF and Win32, PowerShell pitfalls, state and
lifecycle) with a skeptic per finding. It found 11 distinct defects, and
all are fixed. Among them:
- a panel hidden before a restart came back off every screen;
- the buttons popped up the moment the pointer crossed the panel, with ×
  nearest it, so a click meant for the window beside it could close the
  overlay;
- the `rate-limited until` note was hidden whenever a live figure showed, so
  the refresh button looked broken;
- a command sent during start-up was dropped;
- the style checks read the windows before WPF shows them, which is when it
  puts the taskbar flag back.

It missed one, found in use: the buttons blinked and could not be clicked.
Their placement was handed the window's rect where its size belonged, so
each pass put them somewhere new. The placement function's own tests passed
a size and were right; only the call was wrong, and nothing ran the call on
a shown window. The panel test now does, on a stood-in screen.

0.5.0 went through three independent reviews before release: the overlay
and the docs, the console, and the job core with the runner. Together they
made 33 findings - 29 distinct defects, four found by two of them - and
all are fixed.
Among them:
- two jobs for one chat inside a second got ids where one began the other,
  and the watcher could not look the first up by id, so it looped on it and
  held up the whole queue;
- a new chat's transcript was looked for only where its folder's slug said.
  Claude cuts and hashes a path over 200 characters, so there every retry
  passed `--session-id` again, which Claude refuses;
- a new chat's title went to `claude.cmd` through cmd.exe, where a `"` and
  an `&` in it ran the rest as a command of its own;
- a running job's log could not be read (`File.ReadLines` shares only
  Read), which left the console's details pane half drawn;
- Cancel on a job whose run had just ended, and whose watcher had gone,
  marked it failed and lost its result;
- the cut-off scan read every working chat's transcript each minute, and
  one folder it could not list ended the whole scan;
- the console parsed the whole chat index on its window's thread each time
  the index changed: 250 ms for 226 chats here, about 2 s for 2,000. It now
  reads it in a runspace of its own.
Each is in the table above where a test can hold it.

0.7.0's extension, which writes PowerShell profiles and can change an
execution policy, went through one review before release: 13 findings, 11
fixed, all in the table above. Among them:
- a stale `chatManagerReload.signalFile` became the place the scripts were
  written, so one naming `C:\reload-request` would have put them in `C:\`;
  a relative `chatManager.folder` would have written beside Code.exe;
- a loader whose version did not read as three numbers was taken for no
  loader, and overwritten;
- "Added." was said, and the answer kept, even when `chatinstall` failed;
  a PowerShell that gave no answer counted as one lacking the line;
- a failed copy said nothing, left `.new` files, and was tried again at
  every start;
- the git check looked at the folder only, not the ones above it;
- with the old extension watching another file than `chatManager.folder`'s,
  nobody handled requests;
- the policy was offered only after the line was written, and never where
  a line already there could not run.
Two are left as they are: one duplicate delete prompt at the switch, since
the new ID starts with no memory of requests seen, and a profile line that
does not spell the path out is asked about again, as `chatinstall` itself
would not recognise it.

The overlay's cost pass (in [CHANGELOG.md](CHANGELOG.md) under 0.10.5)
went through a five-angle review - the pointer check, the rows' rects, the
native process list, the VS Code windows' files, and the tests - with a
skeptic per finding. The native code drew none. It found one defect: on a
panel at its height cap, the lines view's reset time going took a line off
the usage line and moved every row up while the panel's size stayed, so
the kept rects - and the chip that follows them - were a line off until
the next redraw. And four checks that passed with the fault they were
written for put back:
- the fifth tick's never looked at what the tick mid-drag did;
- the open tabs' passed with every look parsing the file again, and with
  a clock set back trusting a look from the future;
- the process table's, and the failed compile's, were met by the
  `Win32_Process` query the list falls back on.
All are fixed. Each check was then run with its fault put back, and failed -
that check and no other.
