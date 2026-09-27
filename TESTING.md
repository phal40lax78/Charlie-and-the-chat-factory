# Testing VS-code-chat-manager

## The self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File tests/run-tests.ps1                                  # PowerShell 7
node tests/extension-check.js                                              # the VS Code extension
node tests/overlay-mac-check.js                                            # the overlay's macOS panel (JXA)
```

The exit code is the number of failed checks, and `-Keep` leaves the sandbox
behind for poking at. It uses no Pester, no network and no model.

- **Fake CLIs.** Every `claude`/`codex` call goes to `tests/fake-agent.ps1`
  through `tests/fake-claude.cmd`. `CHATQ_CLAUDE` and `CHATQ_CODEX` point there,
  and `FAKE_*` variables choose what it does: a stream to replay, a transcript to
  land the prompt in, a new chat's transcript written where Claude Code would
  write it for `--session-id` (`FAKE_NEW_CHAT`), live chats for `claude
  agents`, `codex archive` and `unarchive`. The `.cmd` hands its arguments over as one string, because
  `powershell -File` refuses a bare `-` (Codex's read-stdin marker).
- **A generated sandbox.** Claude, Codex and Copilot chats are written into fake
  homes under `tests/.sandbox/` with timestamps relative to now, so nothing goes
  stale. `CHAT_CODE_USER` points the Copilot provider there too — otherwise an
  index sync would read this machine's real Copilot chats.
- **A private copy.** The script and its `src/` are dot-sourced from a copy
  in the sandbox, so the run gets its own `data/`.
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
  runs on its own. A new section goes in that list.
- **Seams, so nothing real leaves the sandbox:** no desktop toast
  (`ChatqToastSeam`), no push service (`ChatqNtfySeam`), no idle clock
  (`ChatqIdleSeam`, as if nobody were at the PC), no real background watcher
  (`ChatqSpawn`), no ghost-watch events (`ChatNoGhostWatch`). For the overlay:
  no real overlay process (`ChatOverlaySpawn`), no usage endpoint
  (`ChatOverlayUsageSeam`), no GitHub CLI - `CHATQ_GH` names one that does
  not exist, for the child processes too, since `gh`'s login is the
  machine's and no sandbox reaches it; `ChatOverlayCopilotSeam` stands in for
  its answer - no real Windows light/dark setting
  (`ChatOverlaySystemDarkSeam`), a screen of the test's own off every real one
  for the panel's buttons (`ChatOverlayWorkAreaSeam`), no real clipboard for
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
- **Synthetic streams only** in `tests/fixtures/stream/`. The repo is public, so
  no real transcript goes in it.

What it covers (at 0.9.0, 1032 checks in `run-tests.ps1` under 5.1 and
1033 under pwsh 7, 279 in `extension-check.js`, 250 in
`reply-page-check.js`, 78 in `board-page-check.js` and 35 in
`overlay-mac-check.js`):

| area | checks |
|---|---|
| relevance | bigram cosine: identical = 1, disjoint = 0, Hangul overlap > 0 |
| resolver | exact, contains, every-word; Hangul exact and NFD-typed Hangul; the prompt breaking a tie between look-alike titles; no match stays in this project and never reaches the nested `…-Mobile` slug; a title only found in another project; hex id; a title past the 60-char clip; the 5 h edge at 4h59 (relevance) and 5h03 (newest); Codex thread names; a Copilot title named and refused, never guessed; a sentence typed where a title goes points at `-Prompt`, and a real title never does |
| metadata | cwd, last permission mode even 1.3 MB from the end, last real model, cut-off detection with its reset time, Codex cwd/sandbox |
| limits | future reset found, past one ignored; Codex full window; Codex "try again at …" prose; a cut-off chat the index has no row for yet is still listed by its title, not its uuid |
| classifier | denied → needs-input; rejected event / legacy `…\|epoch` / weekly text → limited; 529 → overloaded; a connection error → network; an expired login (401) and a plan refused (403) → auth, each reason in the API's own message — read out of the error JSON, escapes and all, else the text on one line from the refusal on, cut at 160 characters, and never from the chat's own reply; a Codex refusal the same, its `unexpected status 401` code kept; Codex "stream disconnected" → network; chatq's own time limit never counts as network; a rejected event before a successful turn → done; plan and max-turns → needs-input; error and missing result → failed; a trailing question → done with `asks` |
| overload | a 529-stopped chat recognised and listed; the status page read from a fake `status.json`; the backoff; page polled every minute; operational → probe at once; page silent 15 min → probe anyway; one alert; a reminder past 6 h |
| retries | a network drop requeued a minute out, its landed prompt as a continue that is always sent, gone after three retries; the no-reply cap counting only runs that got no reply, and starting over after one that did; a refused login holds the lane with one alert, which quotes the API, as do the watcher log (the error text whole, its type too, on a line of its own) and the status line — whether the probe met it or a run did; a block an older watcher saved, its source still `probe`, reads right |
| model and order | `-Model` kept apart from the chat's own model, used by the probe and the run (`--model`, and Codex's `-m` before the thread id); `-First` ahead of older jobs, in the list's "sends" too; `chatqrun <n> -First` |
| watcher | one full loop runs the queue and exits; a second watcher will not start; `-Now` reaches a running watcher; a restart request hands over — lock released, successor started last, state carried — and never in `-Foreground`; a cold start does not carry state |
| alerts | the toast at the PC and the phone quiet; `-Test` gets through anyway; ntfy's JSON with Hangul, the title's middle dot and priority 5; the ntfy topic never printed whole; the command hook's environment, `&` and `%PATH%` left as text; a hanging hook stopped; a pasted Join push URL gives up its key and device; `-Off`; the idle clock reads without an error; away only when known — not at the PC, not with `quietMinutes` 0, not on a clock that cannot be read |
| usage | Claude's from its cache with its age, Codex's from the newest rollout that has any, and the `chatqlist` line; a five-hour limit reads `5h limited` rather than the percent cached before it, a weekly one leaves the 5 h figure alone, and a figure an hour old is marked `stale` |
| attachments | a missing file queues nothing; `-Continue` with files refused; `-WhatIf` names them and copies none; copies in the order given, a space out of a name, the original changing later changes nothing; `chatqlist` counts them; Claude gets every path under the prompt and `--add-dir` for the job's folder; Codex gets `-i` per image and `--` before the thread id, the rest in the prompt and the image only said to be there; the same file twice goes once; a wildcard brings every match; a file locked after its check queues nothing and leaves no folder; `chatq <n> -Attach` adds to a queued job, not to one already sent, and `-Paste` of text there adds nothing; `-Paste` through a seam — a screenshot as `clip.png` without the caption that came with it, Explorer files but not folders, text as the prompt or under one, an empty clipboard refused; a pasted image beside the prompt moved in and its link rewritten; a file linked twice one copy, a look-alike name its own link; a link to a file elsewhere, `../` into chatq's data and a `\\share` all left as written and untaken; a name with parentheses and a folder named after the prompt taken, the emptied folder removed; `chatqrm` removes the job's folder |
| jobs.log | a job's queueing and its removal by `chatqrm` both land in `data/logs/jobs.log`, which outlives the job file |
| find and delete | the index holds all three providers; a Hangul Codex name read as UTF-8; an escaped Claude title unescaped; `chatfind` by title, by prompt, and `-Deep` for text past the previews; the index saved while a reader holds it for 150 ms, and a warning, not silence, when the hold outlasts the tries; `chatrm -Force` removes the transcript and every leftover (sidecars, file-history, session-env, tasks, debug, security, telemetry, todos, a job folder by the id inside it, plan files) and writes a tombstone; a plan another chat shares is kept; a locked transcript keeps its leftovers; a chat with a queued prompt is kept, and `-DropJobs` drops the job then deletes |
| archive | Claude archive → tombstone and index row gone → restore over the window's stub, leftovers and all, tombstone cleared; never over a chat with messages; not while open in a window; Codex through `codex archive` / `unarchive`; `chatuninstall -All` refuses while the archive holds one |
| reload safety | in a project of its own: all finished → idle; `busy` or `waiting` from `claude agents` → active though the transcript reads finished; a workflow started and not reported → active, where the transcript alone reads finished; the chat's process gone, or the start older than the process → idle; its `<task-notification>` → idle; a background agent, reported, then woken by SendMessage → active again; a background shell → not counted; the reload request carries `busy` either way; a chat written this minute → active, unless it is the one a queued run just wrote (`-Except`) — but that chat busy in a window still counts; a neighbour written 3 minutes ago → active over `quietMinutes`, not over one minute; a folder whose only chat is the one the run wrote → idle, not unjudged; a queued run into that chat, open and idle, with nobody at the PC → a `ran` request with `away` true and `busy` false, the one the window may take by itself |
| completion | one completer per command: `chatq 3` completes nothing, `chatq` never offers Copilot, subagent chats only with `-All`, hex completes an id, a hex-looking title still completes, a typographic apostrophe quoted; the cycler skips subagents and, for `chatq`, Copilot; a tail left mid-line comes off a `chatq` line |
| install | one profile line replaces chatrm's and chatq's; uninstall leaves the rest of the profile; `chatinstall` moves a running watcher and overlay to the new copy, and `-NoRestart` leaves them; `Test-ChatProfileLine` counts only a line loading this copy, never an old tool's; the script copied without `src/` names the parts missing and defines no command |
| extension: the terminal half | `tests/extension-check.js`, `setup.js` and `build.js` with no PowerShell started: the loader's version read, an unreadable one (`0.8.0-rc1`) no version, and compared by number; the decision - nothing there → install, older → update, the same → nothing, newer → left, a loader of no readable version → left and said once, a folder holding other files → nothing written, not even `data/`, a git work tree at the folder or above it → never written, the difference said once per version pair, no payload → nothing; when the profile is looked at at all and when asked (never after Never, after Not now at the next version, always from the palette); the lock - taken, refused, taken over once stale, and a place that cannot be written thrown rather than read as another window; `setUp` in a sandbox folder: installed parts first with no `.new` left, the same again copies nothing, settled it starts no PowerShell, updated, a newer copy left, nothing copied while another window holds the lock, a copy that fails said once a version with no `.new` and no half install; the profile step with PowerShell stood in for: Add runs `chatinstall` where the line was missing and checks again, after an update also where it was, one restart; Add with the line still missing after it → no "Added", the answer not kept, and said; a policy that would stop the line → the question says so and scripts are allowed before the line is written; a policy that will not change → no line, and said; a PowerShell that gives no answer → neither asked about nor installed into; a line already there that never runs → the policy offered once a version; Never kept until the palette asks; setup runs one at a time, a palette run after a start's rather than dropped, and an `onReady` joining a run already going called once that run's loader is ready, or at once where it was; `onReady` called the moment the copy put the loader there, or at once where it was there already, before the profile step - which may never end - and never for a folder it did not install into; the build: the loader's own part list, every part present, the extension's version the script's, an SVG image caught and a link to one not, the listing README free of them; the old extension on the same file → none of it watched here and one window offers it away, another within 10 minutes not, on another file than `chatManager.folder`'s → this one handles its own; without it both files watched in the tool folder; `chatManager.folder`, `~` in it, a relative one refused for the default, the old `signalFile` taken only as a `data/reload-request`, and `chatManagerReload.*` read where the new ones are unset |
| StrictMode | dot-sourced and used from a `Set-StrictMode -Version Latest` shell — once as the tests run it, once as a real shell loads it (not the watcher, no queue yet, stop on the first error; `autoStart` off in its copy, or the shell-start path would put a real overlay on the screen) |
| runner | stdin byte-exact on 5.1 (Hangul, quotes, `\`, `%`, newlines, no BOM); API key and `CLAUDECODE` kept out; 400 KB of stderr without deadlock; timeout kills the whole tree; argument quoting round-trips through a compiled echo exe |
| jobs | queueing records cwd and mode; the prompt file is named after the chat; done / limited / needs-input / skipped `-Continue` / busy chat deferred / idle live chat run, with a reload request for that window; 529 mid-run; an interrupted run failed and not resent; `chatqrm -Force` with no watcher |
| job core | a job `chatq` makes has the fields it always had, in their order, plus `sendNow`; a row by its id, exact and in any case, never fuzzy; `New-ChatqJob` says why and leaves nothing behind for an empty prompt, a Copilot chat, a continue with files, a chat whose transcript is gone, a file gone before it was copied; first, send now, a model, a not-before time, a staged file moved in and a pasted image; two jobs for one chat inside a second get ids of their own, and a job is found by its whole id even when the other's id starts with it (a prefix match found both and returned neither, and the watcher spun on the first); the first one put first sorts ahead; files go only to a job still waiting; `Remove-ChatqJob` takes the prompt and files; a run's log read as entries, a tail read reading fewer, and read while a run holds it open to write (`File.ReadLines` threw there); `Stop-ChatqJobRun` leaves a job that already ended as it ended; `Request-ChatqWatcher` never waits - the wake to a running watcher, a start when none runs, 'waiting' then 'failed' after 10 s, one that was running when poked and has gone since started again once |
| new chats | the job's session id chosen when it is queued and its transcript's path known, named by the prompt's first line; its first run is `--session-id` and `--name`, no `--resume`, and lands where it said; a window on that folder is offered the reload, in words of its own; the chat it made is found by id and the next prompt resumes it; limited after its prompt landed, it goes on as "continue" in that same chat, and its reload is offered when that finishes, not lost with the run the limit cut; filed by Claude under a folder that is not the slug (`CLAUDE_CODE_PROJECT_DIR_NAME` in the fake; a path over 200 characters does the same), it is found by its id, kept, and a requeue resumes it - the fake refuses a second `--session-id`, as `claude.exe` does; a title with `"` and `&` reaches `claude.cmd` whole but for those, and nothing after it is lost to cmd.exe; deleted since, its continue fails as a chat gone and nothing starts; a folder that is not there, or no prompt, makes no job; a new chat at a drive's root keeps `C:\` and Claude's slug `C--`; a job with no session never breaks the cut-off list |
| Claude Code's lists | the rule as the extension has it (`Get-ChatEntrypointIn`, `Get-ChatUnlistedWhy`), case for case; `Repair-ChatListed` on sandbox transcripts - hidden by its tail, one line as the extension writes it, its write time kept, a second look adds none; a last line lacking its end; hidden by its head untouched; a process busy in it, or a print-mode run, held; one idle, mended; no file, none made; a job run into a chat hidden by its tail lists it again as it ends, and `watcher.log` says so, while a new chat's first record, an SDK's, is left; the open and run requests carry the transcript's path where given, and no such field where not; the append lands after a record another writer added since the open - it never writes over one - and makes no file |
| status | the board folds prompts; Hangul cell widths; a zero-width cell; Join URL length and device routing |
| extension | `tests/extension-check.js`: which window a request is for (not the `-Mobile` sibling), the wording per kind and while a chat works, `autoReload` never while one works and never alone after a queued run; a queued run reloads by itself only with `away` true and `busy` false — not at the PC, not while another chat works, not on either unjudged or missing, not with `autoReloadAfterRun` off, not in a window that is not exactly the job's one folder (a subfolder, a multi-root window), and with it unset it does; a new chat a run started is never reloaded for by itself, with `autoReload` or on an away verdict; end to end from a request file — a window just opened marks a recent run, or a recent new chat, seen and neither asks nor reloads, an open one reloads, a multi-root one asks; the file watched |
| show fresh: the old process | the registry's `entrypoint` read, its `.key` never opened; `-RegistryOnly` never starts `claude agents`; VS Code's own process told apart - `claude-vscode` under `Code` or `Code - Insiders`, an unnamed entrypoint counting, a terminal's, a shell's child, or a parent younger than the child not; `Stop-ChatIdleProcess`: idle with its registry file → ended, the window's host pid named; busy or waiting → held; a workflow the window's process started (`entrypoint` `claude-vscode`) → held, one a print-mode run started (`sdk-cli`) with that run gone → ended; a print-mode claude of the chat alive → held, a window's process beside it not ended; a terminal's claude → other, and nothing ended, not even a window's beside it; `-JudgeOnly` → live, nothing ended, and whose a busy one is still found - a terminal's → other, a window's → held with its host pid; busy when its file is read again → held; no file to read → kept; `liveIdle: stop` ends the process once and the window is told, and with a workflow in flight the job waits and nothing is ended |
| show fresh: the request | after a run with nobody at the PC → ended, `busy` false, the host pids in the request; at the PC → live, nothing ended; the chat itself working → held and busy; background work told apart by who started it, never by when - `Test-ChatIdle` passes over a print-mode run's leftover workflow once no such run is alive and counts it while one is, a run that left one behind still ends the process with `busy` false, and so does Show it afterwards, while the chip leaves it live - neither reads it as held for good, as both had, while a workflow the window's own process started during the run → held, busy, nothing ended; Show it while a queued prompt runs into the chat, or a print-mode claude does → `running`, held, busy, nothing ended; a check that judged nothing (missing) says `kept`, not `none`; after a `ran` or `open` request for a chat, the next run into it waits 30 s - not counted as busy, no attempt used - and another chat's request, or one past 30 s, holds nothing; a run a window opened the chat during (the fake writes its registry file mid-run) → its process ended, a `ran` request, the alert; one in the registry from before that nothing listed live → no request; the chip's `data/open-request` BOM-less with the chat, its folder, title, verdict and window, `code` asked once for the folder, and a run's `reload-request` left byte for byte; the chip ends nothing - its idle process left `live`, `busy` not judged; one ASCII `watcher.log` line per show - how, which chat, the process, busy, the windows, the outcome - and none for a call with no session id; the chip on a terminal's chat → 20, nothing written, no `code`, and the same while that terminal's claude is mid-turn (it had read as held); on a window's working chat → 10, the request naming that window; with a queued prompt running in it → 15; held in a window with none exactly its folder → 25 and no `code -n`, one exactly it → `code`; not started → 30; no `code` → 40; no session id → 50; Show it's verdict one ASCII line of four fields; end to end, the alert per old process - `Show it in VS Code to see the run`, `before typing`, `open in a terminal too` |
| show fresh: code and the chip | `VSCODE_*` and `ELECTRON_*` dropped for `code`, in any case, the rest kept; `code.cmd` through cmd with `&` literal, a `%` refused, an `.exe` started itself with `-n`; `CHATQ_CODE` first, else the installers' place; with two installs, the `code.cmd` beside the running `Code.exe` before PATH, one with no `bin\` beside it passed over; the chip's child command - `'` and `’` doubled, the title only as base64, `CHATQ_OVERLAY` set, exiting with the outcome, no spawn for a non-GUID row; the chip after a 400 ms rest unless set - the config's default too - and not before, one of 250 ms set in `config.json` at 250, held to 100-3000, never on a sweep, kept while on it, gone at once on another row, kept 300 ms off everything and then gone, never with a button held, collapsed, mid-drag or twice in one visit; the rest starting only when the pointer moves onto a row; a chip that came up under the pointer taking no click until the pointer has been off it; a row's last pixel in and the next out; placed flush right, centred, kept on the screen; only a Claude row with an id and a folder; the tray's words per exit; a window exactly on the folder told from its title, also with a profile's name after the folder's - only a name VS Code's `storage.json` lists is taken off - and the chip on such a window brings it forward rather than giving 25; in the STA panel test, rows carrying their row, the chip's style (tool window, no activate, layered, not click-through, no taskbar), flush with its row, and hidden by a redraw without its row and by hiding the panel |
| extension: show fresh | `tests/extension-check.js`: the plan over every verdict - a terminal's → nothing, held, live or kept → reload, ended or none → a tab whatever else is working or unjudged, an old writer, `showFresh` off or no Claude extension → reload; the tab label Claude shows - no title `Claude Code`, 25 characters whole, 26 cut to 24 and `…`, and a real title as the Claude extension showed it; the target window by live host pid, not a window when another live one held it, by folder once every holder is gone; never by itself on a held chat or a judgement over 20 s old; the words for Show it, held, terminal, old writer, after Show it, and for an open - no Claude extension, not opened, now in two places; Reload Webviews and the side bar's focus gone; a tab: none open → one opened, a stale one with the chat's title, or with the label Claude shortened it to → closed and opened again, an untitled Claude tab never taken for a chat of no title, a title that does not match or an editor that is no Claude tab → nothing closed, a slow new tab caught by the second look → nothing closed, a new tab that came just before the close → taken as the chat's, nothing closed, two Claude tabs of one shortened label → never closed and said, the front tab unchanged → one more look before anything closes, a lone tab whose label another chat of its folder has - the same title or the same first 24 characters, open or not, never itself, a chat of no title or another folder's - → never closed, stale and said, while a label of its own is closed and opened again; a Claude tab the Claude extension's panel by its `viewType` alone - never Cline's, whose name holds "claude" too, nor a markdown preview; one tab of the chat only when exactly one reads as it - twins, or a chat of no title, are none; the group holding the chat's tab unlocked only while it is the active group and holds Claude tabs alone - a mixed or empty group left, no active group left and logged as that, `claudeCode.lockEditorGroups` set true left locked while false or unset is unlocked, a stale tab's new one's group unlocked too - and an unlock that fails logged and never thrown; a command that never settles timed out, logged, taken as failed and not asked again, with the queue going on; two shows queued together never interleave; Show it's command quoted (curly ones too), marked as the overlay, and never built for a non-GUID; the verdict read past noise, bad JSON or wrong types none; end to end a quiet exact window opens a tab by itself and logs the verdict it acted on, a multi-root one asks and Show it opens a tab and logs its check, a new tab where this window held the chat - by the request's host pids or Show it's - says once that the side bar's copy is stale, and not when the tab here was closed and opened again, a verdict a minute old asks, a run into a chat open here on an idle process → Show it by itself, at the PC and with another chat busy - its tab closed and opened again, nothing asked - and the check finding it working by then → the held wording, while `autoReloadAfterRun` off or a word a minute old asks and another window's chat is left to that window; away, its process ended by the run's check → a tab by itself though another chat works, a multi-root window asking; a failed check on a process left running offers the reload, and so does a check that judged nothing (`missing`, `bad`) - never a tab beside that process; Show it finding the chat held working → the held wording and **Reload anyway**, and another chat busy with this one live or kept → that other chat's work named and **Reload anyway**, never the held wording - in both, never "could not end" and **Reload**; a check that fails, or judges nothing, on a request that found another chat busy keeps that busy - the other chat's work named and **Reload anyway**, never "could not end" and **Reload**; Show it while a queued prompt goes into the chat shows nothing, reloads nothing and says why - in the picker's words too, naming either kind of print-mode run, a queued prompt or `claude -p`, and promising no offer only a queued one brings; an open: `editor.open` with the chat id, no prompt, a column, no group, `fullEditor` false and `programmatic: 'pin-to-panel'` - never `primaryEditor.open`, whose full editor has no header - its column the one `primaryEditor.open` picks (a group of Claude tabs alone, the active one first; else the active group when it holds one; else the active group), worked out again for the second open of a stale tab - an inactive group holding a Claude tab among others, or an empty one, never picked; `editor.open` refused, not timed out → `primaryEditor.open` with the chat id alone, the tab opened and the log saying it has no header, for the chip and Show it alike; both refused once → tried again, the column worked out again; a Claude extension before 2.1.281, or of no version, still `primaryEditor.open` with the chat id alone, and its tab opens; versions compared as numbers, a suffix left aside; a new tab logged `new`, a tab there already only brought forward with nothing closed or said; a new tab for a chat a process of this window held says once that it now runs in two places, with the side bar's idle copy to close when it was live - not when a tab here showed it, when no process held it, or when another window's did; one working in a process of this window with no tab of its title → not opened, and says to click open again once it finishes, while a tab of its shortened title is opened; with two tabs of its label, one tab of a label another chat of its folder has, or of no title → counted as in no tab, and not opened, while one tab of a label of its own is revealed; where no window can be told (a Mac, `hostPids` empty) → refused as held here, unless exactly one tab reads as it; refused twice both ways → said, nothing else tried; no Claude extension → said, no command and no reload offer; `showFresh` off → still a tab; one for a window not exactly its folder does nothing, at startup a tab and nothing else, five minutes old is dropped as seen, and the same one twice acts once; `open-request` beside the signal file and following `signalFile` |
| extension: the overlay | `tests/extension-check.js`, PowerShell stood in for: the lock missing, or there and opened by nobody, not held, and held for real by a `powershell.exe` holding it open (skipped with no `powershell.exe`); on Windows, Windows PowerShell by its own path, never setup's `hosts()` and its `where.exe`; on Windows with no `config.json` → `Start-ChatOverlayAuto` once, through the tool folder's loader, and its word taken; once per activation; `autoStart` false, with a BOM or without → not started; on a Mac off by default and started only when on; Linux never; the lock held → running, no PowerShell; no loader → not started; no word from the script, or PowerShell throwing → failed, never thrown; a `config.json` that does not parse or cannot be read → off, a missing key the default; a look before the loader is there does not use up the one start; activation with the loader in place starts it at once, once, even while the setup waits on its question for good, and on a first install once the setup has put the loader there, from it, once - with the profile question still unanswered; during an update never from the old loader, only once the copy is whole, from the new one, once; while another window holds the install lock (`elsewhere`) not at all, that window starting it; **Chat Manager: Overlay: start by itself...** in `package.json` and registered - On runs `chatoverlay -AutoStart on` through the tool folder's loader and stops nothing, Off runs `-AutoStart off` then `chatoverlay -Stop`, and says whether the overlay was closed, not yet or not running; the script not saying it took → failed, said, no `-Stop`; nothing picked → nothing run; no loader → said before any question; no panel on the platform → said |
| extension: the chat picker | `tests/extension-check.js`, the Claude home a sandbox folder - `CLAUDE_CONFIG_DIR` an empty one for the whole run, so no check reads the real `~/.claude`: a folder's project named as `Get-ChatSlug` names it; noise and titles as `Test-ChatNoise` and `Format-ChatTitle` have them; every folder's `<GUID>.jsonl`, newest first - a project folder of another case found, nothing else and nothing deeper listed; a rename first, the newest, then the newest `ai-title`, then the first prompt typed past the noise; the sidecar's rename over an `ai-title`, a big file's `ai-title` from its tail and its prompt from its head; a side transcript, and a small one holding no message, left out; titles kept by path, size and write time, read again only once the file changes; what runs each chat - a panel idle is open, busy or waiting working, a terminal wins, nothing is closed, and a run nobody types in (a `kind` set and not `interactive`, as chatq's `claude -p`) running, never a terminal, while an interactive one still is; an entry naming no `entrypoint` no terminal - working or open, as the script's empty where has it; an entry whose pid is gone, whose `startedAt` is ahead, or from before the machine started, runs nothing; the age as `Get-ChatAge` gives it; listed newest first by title, a codicon for what runs it, the age and state beside it, the folder in a multi-root window; a `$(` in a title or a folder's name kept as typed, never drawn as a codicon - only a whole codicon pattern (`$(terminal)`, `$(sync~spin)`) escaped, as VS Code's `escapeIcons` does, one escaped already left alone, and `x $(a b)` or `echo $(git rev-parse HEAD)` as typed; accepted - open idle elsewhere asks with **Open here too** and **Cancel**, Cancel opening nothing and Open here too opening through the chip's core; open with its one tab here brought forward, nothing asked; a terminal's refused and said; a queued prompt going into it (a print-mode run) refused as running, in words of its own, not as a terminal; working refused and told to open it once it finishes, twin tabs too, its one tab here only brought forward; a label another chat of its folder has - the same title or the same first 24 characters, never itself, nor for no title, nor in a folder neither the window nor the chat is on - its one tab counted as none: working refused, open asked; every folder of a multi-root window looked in beside the chat's own, twins in two of them found; each folder's newest 200 read (200 of 205); a look not done within `labelBudget` taken as shared and logged, and 0 no limit; read again after the question, and again right before the open, which waits behind another show - working, or a terminal's, by then refused as it would have been at once; closed opened from disk and logged; titles slow to read listed at once by id and filled in as they come, the item under the cursor kept; the newest 200 only, listed before every title is read - the rest by id, each read made 5 ms slower and no wall-clock limit asserted - and then every title read |
| extension: hidden chats | `tests/extension-check.js`, in a sandbox Claude home: the first `entrypoint` found as Claude Code finds it - the key without a space first, the last by place, escapes read, one cut off none; an SDK's first in the head hides a chat for good, with none in the head the tail's last decides, a window's listed; hidden by its tail - one `chatq-listed` line naming `claude-vscode`, no timestamp, added at the end, byte for byte the script's, listed again, its write time kept, and a second look adds none; a last line lacking its end gets the new one on a line of its own; a process idle in it - mended beside it; one busy in it, or a print-mode run - left, and a head that hides it, a listed chat, or no transcript found - nothing written, no file made; a request's transcript path taken where the slug finds nothing, but only a file named for the chat; the open chip on a chat hidden by its tail - the line written before the open is asked for, then a tab as any other; on one a run writes to - not opened, and said; on one hidden by its head no tab, a terminal offered - `claude --resume <id>` as the terminal's own process, in the chat's folder and Claude home - and "Not now" makes none; the offer taken once the chat runs somewhere - no terminal, and said - and a second offer while one is up - none; a chat whose line cannot be written - not opened, and said; Show it on one hidden by its head, and the picker on one hidden by either, the same; a new chat a run started - said, and no reload offered |
| overlay: transcripts | the newest prompt and title of a 3 MB chat from its last 256 KB, counted in bytes read; read back past a 3 MB line when no record follows it; a budget stops the search and keeps the title found; a `last-prompt` that is machinery falls back to the real prompt; a Hangul prompt cut by a block edge put back together; a rename wins over the generated title; a transcript that grew read only from where it was; `/compact` the way it goes - while it runs, the dequeue with no record after it marked pending; once written, the command newer than the prompt before, not the compaction's summary; kept while only the old `last-prompt` is written again, 100 KB on; replaced by the same words as the prompt before, typed again (by its timestamp), and by the next prompt; a prompt after `/model opus[1m]` wins, the arguments read; a skill the model loads is no command; a working row on a pending command says so, an idle one does not; an open chat nothing has titled shows its first real prompt, past a noisy one (two user lines or more had been read as one, and none found) |
| overlay: sessions | `sessions/<pid>.json` read and the `.key` beside it never opened (held locked, so a read would fail); a dead entry, a new chat tab with no transcript, and chatq's own `claude -p` runs get no row; one chat in two windows is one row at the more urgent state, and one window closing leaves the other; the watcher's fallback reads the same registry with `waitingFor`; against a real process: matching start → alive, `procStart` an hour off, a reused pid and another machine's entry → not, a macOS date `procStart` not held against it |
| overlay: rows | waiting oldest first, then working, running, idle newest first, queued in queue order; a prompt queued for an open chat rides on its row; a job row carries its first line; the snapshot's counts match its rows |
| overlay: answered jobs | what was last typed into an open chat kept - a prompt typed after a command, not the command; a job parked on input answered only by something typed into its chat after it stopped, never by its own prompt nor for a job in another state; a pass skips, `answered in the chat`, the one whose open chat was typed into since and the one whose closed chat's transcript was, its tail read only once it changed after the job stopped, and leaves the one nobody answered |
| overlay: usage | the live answer's 5 h, week, and a model's week once used, in the server's colours; not asked again on the next pass; a window whose reset passed reads empty and is asked about at once; a 401 falls back to the cached figure and waits 10 minutes, a 429 with no Retry-After 5 and says when it asks again; the refresh button asks at once after that, but not twice in 20 s; what a click did is said at the end of Claude's usage - asking, then when Claude answered, gone 10 s on, or why it did not ask - and reaches overlay.json on the next pass; an old Codex figure says it is from Codex's last run; each provider's line ends in when its figure is from or what is happening to it (asking, checked, cached, last run, retry at the named wait) - under its name as bars - and in neither view does any of that take a row of its own, and a time over a week old shows its date (`Mar 13`, not the weekday that read six months as last Friday); Copilot's quota read from GitHub's answer on the free plan (chat, code) and a paid one (premium alone), a fraction of a percent kept as one (`[Math]::Max(0, 0.1)` had rounded it away), a Copilot line from gh's answer, and none - quietly - when gh is not logged in or not there; Retry-After read from a real `HttpResponseMessage` as seconds (2867, the figure the live endpoint sent) or as a date; a 429 with Retry-After waits that long, says `rate-limited until`, and the refresh button keeps to it; the panel's note says so over the last live figure too; a live figure 16 minutes old is not stale while idle asks are 15 apart, a cached one is; with live usage off, only the cache shows; a restart restores the last live figure and that wait from `overlay.json` and does not ask; an expired login is not used; a failed ask is logged and the token appears in no file; a machine with no Codex still gets Claude's |
| overlay: control | a running overlay is shown, never started twice; `-Stop`, `chatinstall` and `chatuninstall` reach it; commands taken once, a stale one dropped, a pass with none queues none; the collector loop ends on `restart`; `overlay.json` BOM-less with Hangul, schema 1, epoch ms; `-Unlock` / `-Reset` / `-Collapse` wait in `overlay-state.json` while it is not running, and `-Expand` undoes it; `-AutoStart on` read at shell start, `-AutoStart off` kept and honoured; on by default on Windows, with no `overlay` block or no `config.json` at all, and started then; `Start-ChatOverlayAuto` prints one word - off, running while the lock is held, started once through the launch, failed when it fails - and none of the launch's own words, which go to `overlay.log` with the reason, or what it threw; a `config.json` that does not read → off, nothing started; `-Width` and `-Rows` kept and said, out of range refused with nothing on that line saved, out of range in the file held to 260-800 and 1-30, and a running panel sent `reload`; the resize handle's sum - left widens and right narrows with the right edge where it was (at 150% too), a row per row's height of travel, none within the first, collapsed width only, an unknown row height taken as 36 units, and from fewer rows drawn than kept, down never below those kept while up takes one off those drawn; `-Compact on` the prompt line off and `-ChipDelay` kept, both said, out of range refused with the rest of its line, and a running panel told; `-Recent` 5 unless set, kept and said, 0 off, out of range refused, held to 0-20 in `config.json`, a running panel told; where a chat runs from its registry entry's `entrypoint` - `claude-vscode` a VS Code panel, any other a terminal, none nothing, a job nowhere - in the snapshot the view key is made of; `-Print` marks a terminal's chat `>_` and lists Recent under the rows; `overlay.log` writes a line once in 5 minutes, and every time with `-Always`; hotkeys parsed and nonsense refused; `-UsageView` and `-CopilotUsage` kept, lines by default and for a view it does not know; `-Theme` and `-Opacity` kept, a percent read as one, an opacity out of range refused, an unknown theme drawn dark; `system` following the (stood-in) Windows setting; both palettes name every colour; the buttons' window on the panel's top edge flush with its right, under the panel when the screen's top leaves no room, kept on the screen side to side (on a second screen too), and left on its side when the box opens where only the buttons fit; the panel's default spot leaves room above it for them; the buttons come only after the pointer rests 350 ms on the panel or on the spot they go - their zone takes in the gap to the panel, above it or below - never with a mouse button held, stay while it is on either or a button is held or a drag runs, and go 700 ms after it leaves; placement back onto a screen; the launch line (`powershell.exe -STA`, `CHATQ_OVERLAY`); the tray tooltip under 64 characters; reset countdowns |
| overlay: cut off | an open idle chat the limit stopped says when it resets and sits just under those waiting; a working one has moved on; one not open gets a row of its own with its project; a 529 says what it waits on; a continue queued replaces the row; a limit that is over says so; the scan the overlay runs every minute reads a transcript again only once it moved (none the second time, one after it grows), never reads a chat it is told is working, and names where each chat ran; a limit record with no `cwd` of its own takes the tail's; one folder it cannot list costs only that folder |
| reset ask | `tests/sections/reset-ask.ps1`, beside the overlay section's sandbox: `autoContinue` read as ask, on or off - `false` and `"false"` off, `"on"` on, missing and `true` ask - and written at the top level by `chatq -AutoContinue`, which refuses a target (the switch is for every chat) or another switch and saves nothing on `-WhatIf`; the answer's own pass run first in the panel child, since a process's first pass over the whole sandbox can outlast the 10 s a watcher is given; a cut-off's key from its limit record's `uuid`, else its time, and none for a name that would not make a file; which chats are asked about - a limit, not a 529; a reset 5 minutes behind and under 12 hours, none with no reset time; no job queued or running; not answered; a terminal's chat named in `Left`; nothing while a 5 h or week window is still limited - newest first, with the latest reset; the answer markers made once, `.shown` once, both gone after 8 days; an answer acting only on the chats it was shown, a changed ask acting on nothing; continue queuing a job each and marking only the chats that got one or had one, a failed one asked again; leave marking all; `ask-go` and `ask-leave` from `overlay-cmd`, and one naming the keys the Mac menu showed answering those only; announced once, across a restart, and never by `-Print` or a `-Peek` pass; the phone's one `limited` alert only when away; the rows kept 12 hours after their reset; the reset time on the usage line, the collapsed line and the tray tooltip; in the Windows panel child, the banner and its two chips, the tray's items - there while an ask is out, gone (`Available`) once it is answered - the balloon and its click opening the console, the settings box's **Cut off** row (Continue, Ask, Leave); the console's header and **Leave them**; the console's Cut off list with `overlay.cutOff` off, from the ask itself, each chat once |
| auto-continue | `tests/sections/auto-continue.ps1`, before `host-work.ps1`: [Auto-continue](#auto-continue) has it in full |
| phone extras | `tests/sections/phone-extras.ps1`, after `phone.ps1`: [Usage heads-ups, quiet hours, voice and text from Tasker](#usage-heads-ups-quiet-hours-voice-and-text-from-tasker) has it in full |
| permissions | `tests/sections/permit.ps1`, after `phone-extras.ps1`: [Permissions from the phone](#permissions-from-the-phone) has it in full |
| phone board | `tests/sections/phone-board.ps1`, after `permit.ps1`: [The phone board and the whole answer](#the-phone-board-and-the-whole-answer) has it in full |
| host work | `tests/sections/host-work.ps1`, the last section: [A new version, and the chats a reload stops](#a-new-version-and-the-chats-a-reload-stops) has it in full |
| overlay: recent and unread | in a Claude home of their own: Recent newest first, the open chat, a side transcript, an empty one and ones with no folder, or a folder gone, left out; titled as an open row is - a rename, the sidecar's, Claude's own title, else the first real prompt - with its folder from the head; as many as `overlay.recent` says, and 0 off with nothing read; not built again within the minute, and after it only a transcript that moved read again; the listing kept between builds, and taken again a minute on or when the open chats change; a chat that closes in it at once, not a minute on; a build past its slice stopped with one transcript read, each pass going on from the same listing until the list is whole; a folder asked about once in 3 minutes, timed by `-Now`: a chat whose folder is deleted after it was read gone once that is up, and back with the folder, its transcript not read again; a folder on a share (`\\` or `//`) or a mapped network drive never asked about and listed, and a folder asked about counted against the slice as a read is; `-Print` listing the whole Recent count, the slice lifted; the macOS collector listing and reading nothing, its snapshot with no Recent; the snapshot's `recent` beside `rows`, not in them, its head the chat just closed, none that is open, and in the view key; unread marked when a chat goes from working or waiting to idle and carried on its row, never for one idle all along; cleared by the open chip only once its child says the open request was written - 0, 25, 40 or 41 - and kept on 10, 15, 20, 30, 50 or no answer in 60 s; cleared by working again, and by its session going; never marked for a chat whose window is in front as it finishes - a VS Code chat by its window's `Code.exe`, a terminal's by what draws it, five hops up - its chain walked in one process snapshot a pass, taken for four chains at once, only at that change and never twice, stopped at `Explorer.EXE` in its own case and at a parent younger than its child (a pid used again), and let go once the process is gone, while one with nothing known in front is marked; a snapshot that failed marks the chat, keeps no chain and is taken again the next time, and one over 250 ms is logged; none marked or counted off Windows, the pass skipping it; a pass counting them, and the tray tooltip saying `N new` |
| console: pure | When - now first and looked at every 30 s, in turn neither, at/in a time or why not; search by every word in the title or project, any case, with a cap; the line saying what Send will do - soon, a limit and when it sends, a busy chat, behind others, a new chat, a 529, the watcher starting, and a refused login in the CLI's own words or a failed probe, never as "limited until"; each job's words and colour in the queue; the limit the preview names, from a usage window marked limited, else the latest reset of the chats it cut off, and never Claude's for a Codex chat - with nothing read from disk; where it opens - grown from the panel's top-right corner, its right edge and top held, at the size it was left, pushed onto the panel's screen - right, and up - and no bigger than it, a size saved under the window's least raised to it in the screen's pixels before the right edge is held; `chatconsole` tells a running overlay, or starts one with `-Open console`; the console hotkey's default, `none`, and nonsense refused |
| console: in the panel's window | in its own child `powershell.exe -STA`, run from a file in the sandbox - encoded, the script had passed the 32,767 characters a command line holds - the panel shown off every screen and never activated, then made the console: its window takes clicks and focus and is on the taskbar - `WS_EX_APPWINDOW`, no tool window, no `NOACTIVATE`, not click-through - and is not topmost, grown from the panel's top-right corner, its right edge and top held (pushed up on a stood-in screen 1020 pixels tall), at 980 x 680 by the screen's scale, the buttons' window and the chip hidden; a collector pass meanwhile keeps its snapshot and draws nothing into the window; Esc (raised on the prompt), the header's back button, and a close with the dispatcher run after it, each give the panel back exactly - its place, width, rows, fold, styles, topmost, content, shown - the close leaving the window there; hide, collapse, lock, unlock and stop go back to the panel first, and a panel that was hidden goes back to the tray; there and back from the panel each of those left - collapsed, collapsed and locked, hidden, hidden and unlocked, unlocked - each comes back exactly; a slider not yet at rest kept as the console opens, with the panel's place, and none kept from the console's rect; a width a reload set meanwhile holds the panel's right edge, never past a stood-in screen's left, and the place it leaves is kept in `overlay-state.json`; a size saved under the window's least opens at that least, its right edge at the panel's; its size kept in `console-state.json` - not its place - and used the next time; the chat index read in a runspace of its own and its rows taken once ready (on the window's thread it had cost 250 ms here each time the index changed); its lists hold the cut-off and open chats, and the search narrows them; each chat drawn by the panel's row builder - the same first line as the panel's row for it, where it runs and the unread dot included, compact - and a recent one as the panel's Recent; a click raised on a cut-off chat picks it - the accent's bar on the selection's colour, the others plain, Continue kept - and a chat picked is the one written to; a file dropped and a screenshot pasted (through the clipboard seam) become chips, a folder dropped is turned away; Send makes the job chatq would - first, sent now, both files moved in, the box and the staging folder emptied, the status saying so; a queued prompt being edited outlives a redraw of the queue; Remove asks, the second half of a double-click is no answer - timed from when the pane has redrawn, since a slow redraw on a busy machine had used up the 0.4 s and let it delete - and a click a second later is; Continue clicked twice queues one; a Codex chat is offered no mode or model and is sent none even when picked before; a theme switch keeps what is typed, and the console's mode; going back keeps the draft in `console-state.json`. In a second child, the whole way round as the user goes it, brought forward through `ChatConsoleFrontSeam`: the console hotkey's verb opens the console and brings it forward, and again only forward; with `ChatConsoleActiveSeam` standing for a console in front, the command's verb (`chatconsole`, the tray) only brings it forward and the hotkey's goes back to the panel as it was; a theme switch keeps the draft typed; Esc, and the panel as it was with the draft saved; the console again, the draft back; a close, and the panel as it was, rows and all; with the folder picker's loop stood in for (`Modal`), a collapse held until it ends and then done, the console key dropped; a panel mid-drag does not become the console |
| overlay: Windows panel | in a child `powershell.exe -STA`, built but never shown: 10 rows draw as 8 and `+2 more · 2 idle`, none as one line; both windows shown the way the host shows them, still off every screen, and their styles read after that - WPF sets `WS_EX_APPWINDOW` again as a window shows: the panel a tool window that never activates and lets clicks through, the buttons' window one that takes clicks but never focus, neither with a taskbar button; eight buttons, the console's among them, hidden until the pointer comes, the grip at the left end and close at the corner; placed by the code the pointer check runs every 120 ms, on a stood-in screen: above the panel, 4 units off and flush with its right, where they were placed before they first showed, still there after more passes (fed their own rect where their size belonged, they had jumped between two spots each pass - the blink this caught), and moved up as the settings box opens above them, never over the panel; the refresh icon turns while an ask is out and stops after; switching to light redraws the frame and keeps the settings box open; the slider itself moved sets the window's opacity, and the next pointer pass saves it to `config.json`; collapsed, one line of counts and usage and a chevron that offers to expand; usage drawn as a line - name, the windows, when it is from - and as bars, the time under the name, once the settings box says so; while the buttons are hidden, the spot the pointer check counts is the one they then show on, with the gap to the panel; their side held only while they are up - under a panel at the stood-in screen's top, still under it once it is moved down, above it after they go and come again, the hidden spot counted there too (held for good, they had stayed under it until a restart) |
| overlay: size | in a child `powershell.exe -STA`, shown off every screen, the pointer never read: the resize handle between the grip and collapse, its tooltip and cursor, the line eight wide with it, and the settings and close tooltips; the settings box's width and rows sliders, whole numbers, their values beside them; the width slider widening the panel with its right edge held, the rows slider redrawing with `+7 more`; `config.json` given both once they rest; the handle dragged left and down - wider, the right edge held, a row a row's height, kept on release with the panel's place; collapsed, the width only; on a screen 500 pixels tall, a panel whose top is 197 pixels down it held to the 303 below that edge - never past the screen's bottom from where it sits - its rows cut to what fits and the rest counted on `+N more`; `reload` taking both from `config.json`, the right edge held; the width slider at rest keeping where the panel's left edge went, for the next start; a `reload` with a slider still moving writing it first, so `config.json` and the panel agree and the shell's other setting is kept; widened by the screen's left edge, held there and growing to the right; fewer chats than rows - dragged down the rows kept never drop, up one off those drawn; the settings box opened after a drag showing what was dragged to, a nudge moving on from there (a width within one unit: at 125% WPF reports 641.6 for 641); width and rows on one row of the box, **Style** full or compact, compact drawing one line a chat and full bringing the prompts back; where a chat runs after its dot - a window for VS Code, `>_` for a terminal, nothing for a job |
| overlay: recent panel | in a child `powershell.exe -STA` of its own (with the size checks the `-EncodedCommand` line had passed Windows' 32 K limit): Recent under the open rows - a faint header, a compact line each that the open chip takes, none counted as a row; a row that finished a turn unseen with the accent dot just before its state, the others none; collapsed, no Recent, and the one line saying `1 new`; the chip on a recent line kept through a redraw, and gone when its line goes; the settings box's Recent off, 5 or 10, the one in force filled, kept in `config.json`; the height cap from WPF's own scale - the room from the panel's top edge down a stood-in screen 1020 pixels tall, over `TransformToDevice.M11` - and not the window rect's ratio to its width, which a drag can put out of step: a rect that disagrees is passed over; the cap going by the panel's top edge, worked out again as a grip drag is let go higher up a screen 500 pixels tall, more rows drawn at once; dropped at the screen's foot, still one row; `Get-ChatOverlayHeightCap` alone, the working area's own top counted |
| overlay: macOS panel | `tests/overlay-mac-check.js`: the JXA pulled out of `src/overlay-mac.ps1`, pure ASCII, free of `?.` and `??`, compiled; its countdowns, bars, lines, row cap, prompt toggle, unlocked hint, commands taken once and only when newer than the panel, the menu bar count; the theme chosen from the config and the OS, both looks with every colour, usage as a line a provider ending in its time, or as bars when set; opacity held to 0.3-1; a terminal's chat marked `>_` and one in VS Code not; no unread mark - a row that says unread drawn as any other, the dot being Windows only |

## CI

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

`docs/make-icon.ps1` makes `extension/icon.png`, the Marketplace icon, from
`docs/icon-source.jpg`: a 256 px square with the photo's left end cut and
the shotgun whole at the right, and bands above and below that shade into
the photo's edge rows with no line at the seam. Its corners are rounded
and transparent; the straight edges are fully opaque. Checked by eye and
by pixel on 2026-09-25.

On pwsh 7 `Add-Type` builds libraries only, so the argument-quoting check builds
its echo exe with .NET Framework's `csc.exe` instead. Where neither can, it says
`skip` and is not counted as passed.

## Phone alerts and replies

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
  with nothing changed; an unreadable `replies.json` is put aside as
  `replies.json.bad`; a pairing push that did not go out says so and leaves
  no pairing waiting.
- **The link:** the Join push carries it with the icon, a `notificationId`
  for the chat and `dismissOnTouch`; the link names the alert, the job and
  the chat, and no key, topic or server; Join and ntfy carry one link; an
  ntfy server that is not https gets none; the Join URL stays within 1900
  characters with Hangul in it, dropping the icon, then the title in the
  link, when 20 characters of text do not fit, and never cutting an emoji.
- **Acting on a reply:** a prompt queues a job and skips the `needs input`
  job it answered; the push that answers carries a fresh link; the same
  message again - by the same id, a new id or a new watcher - does nothing;
  a message id with a line break is skipped; the mode cap for prompt, retry
  and allow, `reply.maxMode` set elsewhere, and Codex's sandbox; the chat's
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
- **The watcher:** a listening watcher's saved limits are not trusted; it
  listens while a window is open, holds nothing awake, writes the board
  coming in and going out, and leaves when the window shuts; one started as
  the last left, but never over a stop; `chatqrun -Stop` shuts the window.
- **Chats you run yourself,** driven through
  [Update-ChatqLiveAlerts](src/phone.ps1) with registry entries made in the
  test and the clock moved by hand: nothing on the first pass; `needs input`
  at 20 s and not at 19; `done` 5 s after busy to idle, `asks:` and all; once
  per chat and event every 3 minutes; nothing at the PC, sent once away
  while still news and never later; sent away with the chat's window in
  front; nothing for the watcher's own run or a non-interactive entry;
  `-LiveAlerts off`, no phone channel and `-Events` each silence it; the
  status line saying the overlay runs an older copy; the outbox sent through
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

**Not covered by the run:** the setup window - only the VS Code command
that opens it is checked, with PowerShell stood in for - and everything
past the seams: Join, ntfy.sh, GitHub Pages, a phone's browser, a PC that
sleeps, and a real overlay sending a live alert.

**S34, by hand with a real phone.** Android and Chrome, Join installed.
Each step leaves lines in `data/logs/replies.log` and `watcher.log`; a live
alert also in `overlay.log` and `outbox.log`.
1. **The page is served.** The repository's **Settings → Pages**: deploy
   from a branch, `main`, `/docs`. On the phone,
   <https://phal40lax78.github.io/VS-code-chat-manager/reply.html> opens
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
   prompt and **Send**: a `queued #n` push, the job queued in `acceptEdits`
   at most, the old one skipped. On a `started` alert, **Stop** - two taps -
   stops the run within about 30 s. **Status** answers with the queue.
6. **A live alert.** `chatnotify` says the chats you run yourself are on,
   with no older copy running. Start a turn in a VS Code chat, leave VS
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

The phone features went through three reviews before release - 28, 17 and
6 findings, some found by two lenses - covering the crypto and what each
server sees, the reply state and the watcher, the pairing, the setup window
and the page, and the live alerts. Their fixes are held by `phone.ps1` and
`reply-page-check.js` where a test can hold them; what was left on purpose
is in FUTURE_WORK.md.

## Auto-continue

`tests/sections/auto-continue.ps1`, the section before `host-work.ps1`, for the automatic
mode (`autoContinue: "on"`; the ask is `reset-ask.ps1`'s), with chats of its
own in a project folder of its own - cut off minutes ago, their limit
records written as Claude Code writes them - and registry entries made in
the test and handed in. It puts back the config, `auto-continue.json`, the
markers, and the jobs and chats it made.

| area | checks |
|---|---|
| the setting | only `"on"` is on, `true` still ask; `Set-ChatqAutoContinue -Value on` writes `since` as it turns on, not again while it stays on; `auto-continue.json` changed under its lock - held by another writer, a change waits about 3 s and fails unsaved |
| states | `Get-ChatqAutoState` for every state, the row's short words and the long ones exact: ready, armed, due (with the queue's time, a VS Code hold's reason, `after #3`), running, off - and ask, which says it asks - always with the switch off, never, a terminal's entry and any entry not a panel's, a panel's no bar, stopped on its own cut-off only, declined - and a later cut-off with the same reset as one whose continue was removed or that the ask left, never one with another reset or after a failure - failed by its job or by its marker's error, the reset ask's markers read as this mode's (leave declined, a continue whose job failed failed), far (before `since`, over 12 h, a reset 30 h out, no `since` yet), late, and a 529 as it was |
| the scan | a cut-off from before the switch turned on is far; a scan that finds no `since` writes it; a closed chat queued - kind continue, rule auto, `auto`, its cut-off's uuid, the chat's own mode and model - its marker in the ask's shape (`answer continue`, `seq`) naming the job and `jobs.log` saying `continue, auto - limit ..., resets ...`; nothing more on a second scan; a removed continue never back for that cut-off, a new uuid queued again; one the ask left not queued; a panel's chat held to the reset plus 5 minutes, its time reading `(open in VS Code)`; a terminal's, or a print run's, not queued, then queued once it is gone, said once in the log; a 529 not queued, another config dir not scanned; the switch off or ask, always with it off, on again writing `since` anew, never removing the continue; a job you queued already leaves no marker; late and a weekly reset not queued; a marker made once - the second exclusive create refused, a name no key has refused - one with an error never tried again, one over 8 days deleted; a cut-off's id past its chat and its marker's path; two scans at once in two runspaces queue one |
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

## A new version, and the chats a reload stops

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
listed as a `run` of its own, with no pids; a
transcript written this minute is said apart (`Written`); with no process
list (off Windows) nothing is known and every VS Code chat is listed; a
host with no chats, or a home with no registry, lists none. The line the
extension reads is ASCII JSON, the Hangul path escaped and read back
whole, and an empty list is `[]`. Last, the extension's own command runs
in a PowerShell of its own against the sandbox's copy of the scripts and
gives back one line of JSON for that host. Its check names how long that
took: on 2026-09-27, with two suites running at once, 3.2 s under Windows
PowerShell 5.1 and 7.0 s under PowerShell 7 - most of it starting
PowerShell and loading the scripts. That is the price of one look, paid
once for the notice and every 25 seconds while a reload waits.

`tests/extension-check.js` stands in for the script's verdict
(`_hostWork`, nothing working unless a check says so - no check ever
starts that PowerShell), the clock, the status bar, VS Code's
`extensions.json` in a sandbox folder, `onDidChange`, the registry's last
word before the reload (`_movedSince`) and the reload command: another
version, newer or older, said by its version and the same one again only
by another install time; the entry found by id in
any case; the verdict parsed past noise, a field of the wrong kind none;
the command naming this host's pid and the Claude home quoted, and
testing for `Get-ChatHostWork` first - scripts too old for it said as
that, else the error with stderr's first line; a
background-only chat working, one only written this minute working unless
it is the run's own; at activation the running version and its folder's
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
   it would with VS Code's own button. With **Later**, nothing happens and
   the same install is not said again.
5. A delete with `chatManager.autoReload` on while a chat of the window
   runs a workflow: no reload, and the warning names the chat.

**While developing chatq:** installing a VSIX into the VS Code the work
runs in ends every chat there - Claude Code's sessions, their permission
prompts, their workflows and agents - on that window's next restart or
reload; on 2026-09-27 it took this repo's own sessions down twice. Answer
the notice with **Reload when they're idle**, or try the extension in an
Extension Development Host (`code --extensionDevelopmentPath=<repo>\extension`)
or a VS Code with its own `--extensions-dir`, as above.

## Usage heads-ups, quiet hours, voice and text from Tasker

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

## Permissions from the phone

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
  permit is `{"behavior":"allow"}` within 2 s; a refuse carries its note;
  a declined request says why; two pending are answered in reverse order
  to their own ids, with a ping answered meanwhile; a cancelled call is
  marked withdrawn; an answer copied from another request, one naming
  another request and an unsealed one are never believed, and deny at the
  deadline; the next call is then denied at once; stdin closed, exit 0.
  The run prints how long `initialize` took. Alone that is about a
  second; with both PowerShells' suites running at once it was near 7 s,
  still well inside claude's 30 s `MCP_TIMEOUT`. A figure near 30 s means
  the bridge's load has grown: a real run would find it `failed` and be
  queued once more without it.
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

**S36, by hand with a real phone** (after S34): permits on
(`chatnotify -Permit on`); queue a prompt that needs `git push` and leave
the PC. The `chatq · permission` push names no command; the page shows it,
redacted where it should be. **Allow once** (two taps): the run goes on
within about 10 s and an `allowed` push follows. Again with **Deny** and a
note: Claude's reply quotes it, and the job is `done`. Again without
answering: after 10 minutes `needs input ... - no answer from the phone`,
and Allow then says too late. **Stop** from a `started` alert while a
request waits. At the PC: the toast and the phone both show it.

## The phone board and the whole answer

```powershell
node tests/board-page-check.js    # docs/reply.html's board, whole answer and down channel
```

The PowerShell half is `tests/sections/phone-board.ps1`, after `phone.ps1`,
`phone-extras.ps1` and `permit.ps1` (75 checks, one of them the 0.9.0
merge's: a link made again after the whole answer keeps a soon alert's
`w=1` and a permission card's `r=`); the page check (78) is its own CI step, **Board
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
  queue; built again, the same handles. From a scan, with the snapshot
  old: the registry's open chats and the chats the limit cut off, `from`
  scan - sent again 25 s on, and built again with no transcript read
  twice. The list offers a folder on another machine without looking at
  it.
- **The acts:** send - a job for that chat, rule phone, capped, its links
  defused, in its config dir, an ack and a push; new - in the folder the
  board offered, a bidi override out of its name, in `default`, its push
  naming neither title nor folder; now (to the front, the watcher woken),
  skip, stop, retry, allow - a handle's whole id finding only its own job,
  never the same-second sibling `-2`, and only with the handle's number -
  continue at reset and a second one refused, its cut-off marked as the
  ask's answers are, so once skipped auto-continue reads it declined, read
  (no push, counted as a whole answer, and refused with `-FullText off`),
  status, list. Refused, each said: another
  chat's id, an expired handle, a handle of another kind, a job number not
  the handle's, 31 minutes old, the 21st change in an hour, an unknown act,
  `-Compose off`; a replay from the file dropped in silence; refusals told
  once a minute; `replies.json` locked - nothing done, and done on the next
  poll.
- **Listening:** `-Listen always` listens with no alert and starts a
  watcher; 20, 15 and 6 s between polls, 30 and 10 inside a run;
  `chatqrun -Stop` ends it and a shell's start begins it again; no phone,
  nothing; `-Listen alerts`. A save prunes `picks` and `compose`, and a file
  that cannot be read still throws. The five settings, each checked and
  saved; the setup window's three boxes, drawn off-screen in an STA child.

**What `board-page-check.js` holds:** the fixtures against Node's crypto and
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
acts; the sections in the overlay's order, usage lines, the footer; the
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
   reply` push, the job in `acceptEdits` at most. **Send now** on a queued
   job, **Skip** with two taps, **+ New chat** in a listed folder.
4. **Nobody listening.** `chatnotify -Listen alerts` with no alert out:
   the page gives `No answer from the PC` at 45 s.
5. **Budget.** `replies.log` has one line per act; after a day of use
   `down` in `replies.json` stays under 200.

## The demo frames

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

## Spikes against the real CLIs

These ran once while building, against Claude Code 2.1.278 and the Codex bundled
with openai.chatgpt 26.908 (codex-cli 0.154), on throwaway chats only.

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
| S14 | `codex queue`, `archive`, `unarchive` | present in codex-cli 0.154 (`--help`); `queue` goes through the shared app-server daemon |
| S15 | the usage cache | `~/.claude.json` → `cachedUsageUtilization.utilization.limits[]`: `kind` (`session`, `weekly_all`, `weekly_scoped` with a model scope), `percent`, `resets_at`, plus `fetchedAtMs` |
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

## Still to check by hand

- **S4, a chat still open in the VS Code panel.** Open a throwaway chat, leave it
  idle, queue a prompt for it and let it run. Does the panel show the run, or
  does it need the reload the extension now offers? Then set `"liveIdle": "stop"`
  in `data/config.json` and repeat. The result decides the `liveIdle` default,
  and whether the reload offer after a run is needed at all. S29 answered the
  first half: the side bar does not show the run by itself, and keeps its
  cached view even once the process is ended. S30 item 5 closes the rest.
- **S9, closing the terminal and quitting VS Code while the watcher waits.**
- **S10, Join**, and **ntfy**: `chatnotify … -Test` reaches the phone, Hangul
  intact.
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
  1. A click on the panel lands in the window under it, and typing stays there.
  2. Resting the pointer on it for a moment brings up the row of buttons
     on its top edge, outside it, flush with its top-right corner - under it
     once the panel is dragged to the top of the screen, and on top again
     once it is dragged back down and they go and come - grip at the left,
     × at the corner. Sweeping the pointer across it brings up nothing. They
     go a moment after the pointer leaves; moving from the panel onto them
     does not lose them. A click on the panel still goes through, and so
     does one on the empty space beside the buttons. With the panel near
     the top, opening the settings box leaves the buttons where they are.
  3. Holding the grip drags the panel, the buttons follow, and the position
     is kept after `chatoverlay -Stop` and a start.
  4. The settings box opens above the buttons, outside the panel: the slider
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
  7. Hide to tray hides it, a balloon says the tray dot brings it back
     (once), and the tray dot does - also after `chatoverlay -Stop` and a
     start while hidden. × closes it, and `chatoverlay` starts it, shown.
  8. **Ctrl+Alt+Shift+O** unlocks it, a drag moves it (the buttons follow),
     and the key locks it again. Left unlocked, it locks itself two minutes
     after the pointer leaves.
  9. The tray dot's left click hides and shows it, and its menu's Lock, Hide,
     Collapse, Refresh usage, Move to top right and Quit work.
  10. Neither window is in Alt+Tab or on the taskbar.
  11. With a monitor unplugged, it moves onto the main one within 5 s.
  12. It survives closing a whole Windows Terminal window, and quitting VS
      Code, when started from each. If it does not, launch it through
      `Invoke-CimMethod Win32_Process Create`, outside their job object.
  13. `-AutoStart on` (the default on Windows since the overlay starts by
      itself) brings it back after signing out and in and opening a shell.
  14. After an hour, memory is still about 170 MB, and CPU stays under 0.2%
      with the 120 ms pointer check running; the log shows no 429 at the
      five-minute pace.
  15. `/compact` in a chat: its row reads "command running" while it runs
      and `/compact` once it ends.
  16. Rested on, the buttons stay still - no flicker between two places -
      and each one takes a click; opening the settings box never covers
      the panel.
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
  1. Each way in opens it: the speech bubble on the overlay's buttons, Open
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
  5. Send now into a chat open and idle in VS Code: it runs within
     seconds, the window offers the reload, and the reply is there after it;
     the console shows the job done with its reply.
  6. Send now into a chat working in VS Code: it waits, and goes within
     about 30 s of that chat going idle.
  7. + New chat in a folder: the job runs, a window on that folder is
     offered the reload, and the chat is in its list afterwards (S25).
  8. At a reset, Continue all queues one per cut-off chat, and the orange
     rows on the overlay turn into their jobs.
  9. Cancel on a running job stops it within seconds; Remove asks twice;
     an edit to a waiting prompt is what gets sent.
  10. Close the console mid-sentence with a file attached, restart the
      overlay (`chatinstall`, or `chatoverlay -Stop` and `chatoverlay`), and
      open it: the chat, the text and the file are all still there.
  11. Drag it to a monitor at another scale, resize it, close and reopen:
      it opens where it was, the size it was.
  12. Typing stays smooth with the collector running behind it.
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
      its `kind` (not `interactive` is what `Test-ChatPrintLive` counts on;
      with no file at all, only the queue tells chatq a run is under way).
  19. **Pointing straight at the overlay's buttons.** With them hidden, move
      the pointer from elsewhere on the screen directly to the spot above the
      panel's top-right corner and rest there: they come up under it in about
      a third of a second, and a click there works. Sweep the pointer across
      that spot without stopping: nothing comes up, and a click on the window
      underneath lands there. Drag an editor tab or a file across it, pausing
      there with the button held: nothing comes up, and the drop lands in the
      window underneath.
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
  5. **A fresh VS Code window starts the overlay.** `chatoverlay -Stop`,
     then open a new VS Code window. Within seconds the panel is up and the
     extension's log reads `overlay: started`. A second window opened after
     it logs `overlay: running` and starts no second panel. A new shell
     prints `chatoverlay started` only when it was the one to start it.
  6. **`-AutoStart off` keeps it from starting.** `chatoverlay -AutoStart
     off`, `chatoverlay -Stop`, then a new shell and a new VS Code window:
     no panel, and the extension's log reads `overlay: autoStart is off`.
     `chatoverlay -AutoStart on` brings both back.
  7. **Resize by the handle.** Rest on the panel, hold the two-way arrow
     beside the grip and drag left: the panel widens, its right edge and
     the buttons stay where they were; right narrows it, down to 260. Drag
     down: a row comes for each row's height of travel, up to the chats
     open; up takes them away again. Collapsed, only the width moves. Let
     go: `config.json` has `width` and `maxRows`, and a restart keeps both
     and the panel's place. At 150% scaling as well as 100%.
  8. **The sliders.** The settings box's Width and Rows move the panel as
     they move, the width with the right edge held, and `config.json` has
     both a second after release. Rows at 30 on a short screen: the panel
     stops at the screen's bottom and `+N more` counts the rest. Unlock
     it and drag it half way down: it still stops at the bottom, from
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
      the overlay, open a VS Code window so the extension starts it (item
      5), then quit that window, and all of VS Code: the panel stays up. If
      it goes with them, the launch needs `Invoke-CimMethod Win32_Process
      Create`, outside VS Code's job object, as S23 item 12 says.
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
      a tab. One working in the side bar or another window: it says so and
      opens nothing. One a terminal `claude` holds: it says so and opens
      nothing. One a queued prompt is going into (the console's Send now,
      picked mid-run): it says a queued prompt is going into it, not that it is
      in a terminal, and opens nothing; the log reads `running -> refused`.
      `sessions/` never gets a second file for a working chat.
  16. **Recent.** Close a chat's tab: within two seconds it heads the faint
      Recent list under the open rows, with its project and age. Rest on
      it: **open** comes, and a click opens it as a tab, and it leaves
      Recent for the open rows. The settings box's Recent **off** empties
      it on the next pass, and **10** lists ten; `chatoverlay -Recent 0`
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
  21. **The width slider by the screen's left edge.** Unlock the panel,
      drag it to the left edge of its screen, and slide Width up: the left
      edge stays on the screen and the panel grows to the right, the
      buttons over its right end. Let go, then restart the overlay: it
      comes back where it was left, as wide. On a second screen to the
      left of the main one as well.
  22. **Dragging down never lowers Rows.** With Rows at 8 and three chats
      open, drag the resize handle down a little and let go: `config.json`
      still has `maxRows` 8. Down six rows' height: 9, and on from there.
      Up one row's height from the start: two rows drawn, and 2 kept. Open
      the settings box after each: Rows shows what was kept.
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
      width and rows. Open the console by the speech bubble: it grows from
      the panel's top-right corner - its right edge and top where the
      panel's were - with the prompt box taking the keys, and neither the
      buttons nor the open chip come over it. **Esc**: the panel is back
      exactly where and as it was, lets clicks through again, and stays
      over the next window you click. Then in by the tray's **Open
      console** and back by **← Panel**; in by Ctrl+Alt+Shift+Q and back
      by it again; in by `chatconsole` from a shell and back by Alt+F4 -
      the overlay and its tray dot stay. The same with the panel collapsed,
      unlocked (its blue edge), and hidden in the tray - opened from the
      tray's item, Esc puts it back in the tray. With no overlay running,
      `chatconsole` starts one straight into the console.
  29. **Files from Explorer onto a covered console.** With the console
      open, click an Explorer window so it covers part of the console, and
      drag a file from it onto the prompt: a chip; a folder onto + New
      chat's folder box: its path. The console does not jump over Explorer
      by itself, and the drop works where it shows.
  30. **The taskbar and Alt+Tab.** While it is the console, the taskbar has
      a button for it and Alt+Tab lists it as `chatq console`; either
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
      monitor looks right on the other: it is kept in pixels. Shrink it by
      the grip to its least on the 100% monitor, go back, move the panel to
      the 150% one and open it: at least 640 x 420 there too, its right edge
      still at the panel's, the **← Panel** button on the screen. Then open
      it on the panel's monitor, drag it by the header to the other one,
      and press Esc: the panel is back on its own monitor at its own place
      and width, its rows cut at that screen's foot, not left too tall.
  34. **Hide, collapse and quit from the console.** With the console open,
      left-click the tray dot: the console goes and the panel is hidden in
      the tray; click again: the panel, not the console. The tray's
      Collapse to one line: the panel, collapsed. Quit: the overlay closes,
      and `console-state.json` has the draft and the size, no `x`, `y` or
      `max`. With + New chat's **Browse** picker open over the console,
      press Ctrl+Alt+Shift+O and pick the tray's Collapse to one line:
      nothing happens under the picker; close it, and the console goes back
      to the panel, collapsed. Ctrl+Alt+Shift+Q under the picker does
      nothing.
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
     chat's tab closed after typing.
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
  2. **Five minutes after it.** One toast, `chatq - limit over at 13:00`,
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
- **S36, a tool call approved from a real phone** (CHANGELOG, 0.9.0): the
  steps are under [Permissions from the phone](#permissions-from-the-phone),
  with S35's items 5-8 still open beside them.
- **S43, usage heads-ups, quiet hours, voice and Tasker on a real phone**
  (CHANGELOG, 0.9.0): the steps are under
  [Usage heads-ups, quiet hours, voice and text from Tasker](#usage-heads-ups-quiet-hours-voice-and-text-from-tasker).
- **S44, the phone board and the whole answer on a real phone**
  (CHANGELOG, 0.9.0): the steps are under
  [The phone board and the whole answer](#the-phone-board-and-the-whole-answer).
- **S45, a new version installed while the window's chats work**
  (CHANGELOG, 0.9.0): the steps are under
  [A new version, and the chats a reload stops](#a-new-version-and-the-chats-a-reload-stops),
  in a VS Code of its own - never the one the work runs in.
- **macOS and Linux** are untested; the Unix branches are written but have never
  run.
