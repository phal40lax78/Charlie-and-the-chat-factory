# chatqd: the native watcher (SPEC)

Status: revision 2, with M0 corrections found while reading the PS sources for M0 (2026-10-15; listed in §8 "M0 corrections"). Revision 2 answers both critiques. Each gap is either fixed in the section it belongs to, or explained in §8 under "Review items not taken as proposed". M0 and M1 are built, in ChatVersion `0.10.15`, M2 in `0.10.16` and M3 in `0.10.21` (§7), M9a's panel lands opt-in in `0.11.0` and ships in the VSIX, the default, in `0.11.1`: where a section names a module, it says what that module does; the rest is the plan for M4 on. Revision 3 (2026-10-18) writes M2's step contract into §2.4, §3.6, §4.4, §4.5, §6.5 and §8, with your six decisions of 2026-10-18 (§8 "M2 contract notes"). Revision 4 (2026-10-20) adds the M9 spike's findings and memory (§8 "The M9 spike"); M9 itself stays outside this SPEC (§7).
Owner folder: `native/` (new, top level). Binary: `chatqd` (`chatqd.exe` on Windows).

The name `chatqd` follows the `chatq*` command family and the Unix habit of naming a daemon with a `d`. It is one multicall binary: `chatqd watch` now, and later `chatqd ask-hook` and `chatqd permit` (milestone M8). That means one file to sign, one hash for antivirus reputation, and one download per platform.

---

## 0. Goal and the one rule

Replace the hidden PowerShell watcher ([Invoke-ChatqWatchLoop](src/watcher.ps1)) with a native process. No other process should be able to tell the difference. That covers every shell, the overlay, the extension, the phone page, the CLIs and the self-test.

Why: memory. The watcher loads 23 parts and sits at about **104 MB private** in steady state. That figure is from the loader's own measurement in [Charlie-and-the-chat-factory.ps1](Charlie-and-the-chat-factory.ps1); a running watcher measured 150 to 225 MB private over a day on 2026-10-19 (§3.3). Windows PowerShell alone is about 52 MB (DEFERRED.md "A lighter launcher for the ask hook"). The watcher lives for hours: it waits on limits, and with `reply.listen always` it listens all the time. Idle memory is the payoff.

**The rule.** The shell commands stay PowerShell. So every file in `data/`, every environment variable, every lock and every format below is a **contract**, and both engines obey it at the same time. Anything chatqd cannot yet do goes to PowerShell in one of two ways:

- **Helper step.** A one-shot PowerShell runs the existing function. chatqd keeps the lock. (§3.6)
- **Handoff.** The existing `state.json` handoff passes the lock to the PowerShell watcher. (§4.4)

Nothing is ever done half in each engine. A duty is either native from start to end, or a step runs the whole of it. Where a PS function mixes a cheap per-pass decision with a rare costly action (the usage "soon" alert, the permission tick, the reply poll), the decision is ported and the action stays a step. The split is cut where the PS function would have done nothing observable. §3.7 and §3.8 prove each such cut.

**Identical observable behaviour** means these stay the same:

- every byte-level contract in §2;
- every line in `watcher.log`, `alerts.log`, `jobs.log` and `replies.log`;
- the alerts sent, and when;
- the CLI arguments, environment and stdin of each run;
- the poll cadences and timeouts;
- the liveness answers given to every prober.

What may differ is listed in §8 under "Deliberate differences": the process image name, the parent of a run's CLI, and a few hardening and timing details. Each one says why no reader can rely on it.

Diagnostics that only chatqd has go to `data/logs/chatqd.log`, never to `watcher.log`.

---

## 1. Scope: every duty, and its fate

Legend:

- **port**: native in chatqd, at the milestone given.
- **gate port**: the per-pass decision is native; the action, when the decision says one is due, is a step.
- **helper**: run by a PowerShell helper step (§3.6) until the milestone that ports it, or for good where marked "keep".
- **keep-PS**: stays PowerShell and is not the watcher's job to port.
- **drop**: not carried over, with the reason.

### 1.1 The loop ([Invoke-ChatqWatchLoop](src/watcher.ps1))

Rows are in the loop's own order. Start-up first, then one pass, then exit.

| Duty | Today | Fate |
|---|---|---|
| Ensure `data/` exists | `New-ChatqDir $script:ChatqData` | port M0 |
| Acquire `data/watcher.lock`: 5 tries 200 ms apart, give up silently (foreground prints) | `[IO.File]::Open(..., OpenOrCreate, ReadWrite, None)` | port M0 (§4.3) |
| Build the run state | `New-ChatqWatchState`, then `$W.startedAt` | port M0 |
| Write `data/watcher.pid` | `Set-Content -Encoding ASCII` | port M0 |
| Delete a stale `data/stop` at start | | port M0 |
| Log `watcher <pid> started (<ChatVersion>)` | [Write-ChatqWatchLog](src/watcher.ps1) | port M0 |
| Restore handed-over state; log `carrying on from the watcher before it` | [Restore-ChatqWatchState](src/watcher.ps1) | port M0 |
| Repair jobs left `running`, then reset `$W.CutCache = @{}` | [Repair-ChatqInterrupted](src/watcher.ps1) (also [Remove-ChatqPermitLeftovers](src/permit.ps1), `Remove-ChatqAskLeftovers` in [src/ask.ps1](src/ask.ps1)) | helper `repair` op, **keep**. It runs once per chatqd life and the op resets CutCache itself (§3.6). Before M2, the repair is due, and so means a handoff (M0), when any job is `running`, when `D/permit/` exists and holds a subfolder or `D/replies.json` exists ([Remove-ChatqPermitLeftovers](src/permit.ps1) then re-saves replies.json, prune included, even with no subfolder), or when `D/ask/` holds a `*.req.json` (the only files [Remove-ChatqAskLeftovers](src/ask.ps1) lists) |
| Timers start at `MinValue` | `$autoAt`, `$strayAt` | port M0. **Both the auto scan and the stray sweep run on the first pass**, then every 5 min and 6 h (§2.10) |
| `stop` flag at the loop top → log `stop requested`, break | | port M0 |
| `restart` flag (not in foreground) → log `a newer copy was installed - handing over`, handoff=true, respawn after exit | | port M0 (respawn decision, §4.2) |
| `wake` flag: mtime change; `now` honoured only under 5 min old; `Send-ChatqWake 'seen'`; clear blocked/lastAllowed/outage ([WatchState::clear_for_wake](native/crates/chatq-core/src/state.rs)); stamp scannedAt per queued lane; clear `deferUntil` with `Save-ChatqJob -Existing`; log `woken: -Now` | | port M0 (mtime, now, seen); job writes M2. The word is read with `Get-Content -Raw`, trimmed, and compared with `-eq`, so case is ignored and a read failure counts as `''`. The freshness test is `(UtcNow - LastWriteTimeUtc).TotalMinutes -lt 5`, so a wake file dated in the future is fresh too. **Until M2, a fresh `now` found while any job is queued is left unread**: no `seen`, no W change, then the handoff. The PS watcher starts with `$wakeSeen` null and takes it on its first pass, with the `scannedAt` stamps and `deferUntil` writes chatqd cannot yet make. Taken by chatqd and handed over, it would be lost |
| Held-summary check | [Test-ChatqHeldWaiting](src/phone-extras.ps1): `held.jsonl` exists, or a `held-*.sending` file whose LastWriteTime is over 10 min old ([Get-ChatqStaleSending](src/phone-extras.ps1)) | gate port M0 (the M0 handoff rule needs it: true means a handoff); [Send-ChatqHeldSummary](src/phone-extras.ps1) helper `held`, keep until M6 |
| Reply window open? Log `replies closed` on the close | [Test-ChatqReplyOpen](src/phone.ps1) | port **M0**: the M0 handoff rule, the empty-exit recheck and the post-exit respawn all ask it. Its `-eq $true` tests (`reply.on`, `standing`) follow PowerShell's comparison, so `true`, the string `"true"` in any case and any number equal to 1 all pass. Vector `reply-open.json` (in `gates.json`) |
| Poll cadence: 6 s hot / 15 s open / 20 s otherwise | [Get-ChatqReplyPollSeconds](src/phone-down.ps1) | port M3 |
| Poll the reply topic | [Invoke-ChatqReplyPoll](src/phone.ps1) `-MinSeconds` | M3 split, §3.7: fetch, triage, junk handling and the junk-only saves are native; any batch that holds a message passing the MAC goes whole to a `reply` step |
| Check landed phone answers to a chat's question | [Test-ChatqAskLanded](src/ask.ps1), every pass while `$script:ChatqAskSent` is non-empty | gate port M2: chatqd holds `ChatqAskSent` (§3.6) and runs an `ask-landed` step only when the oldest entry's `At` is 20 s old. That is the function's own threshold, and it does nothing before it |
| Auto-continue scan, at start and every 5 min | [Invoke-ChatqWatchAutoScan](src/auto-continue.ps1) `$W` | `$autoAt` and the [Test-ChatqAutoWanted](src/auto-continue.ps1) gate: port M2, except that M0 already ports the gate: wanted means a handoff, since the first pass would scan. The scan: helper `auto`, then decide at M7 by measurement |
| Stray-file sweep, at start and every 6 h; log `removed N stray file(s) and folder(s) from data/queue` | [Clear-ChatqStrayFiles](src/queue.ps1) | helper `stray` M2 → port M7. M0 runs no sweep, so it hands off when `D/queue` may hold a candidate: a root file other than `*.json`, `*.md`, `*.cancel` and `*.tmp`, or a folder with no `<name>.json` beside it, whose newer of creation and write time is older than `$script:ChatqStrayHours`. The test is looser than the sweep's own rules and errs towards a handoff |
| List queued jobs, in order | [Get-ChatqJobs](src/queue.ps1) | port M0 (count), M2 (full sort) |
| Listening-only branch: when not yet listening or a poll acted, keep-awake off, `current`/`next` null, `listening:true`, save state, board, log `listening for phone replies <text>`; wait one poll interval only if nothing was polled | | port M3 (text from [Get-ChatqReplyListenText](src/phone-down.ps1)); the board while listening is a `board` step (§1.1 board row) |
| Empty queue: keep-awake off, save state, board, recheck queue, recheck window, log `queue empty`, exit | | port M0, with only the trivial board: [Write-ChatqBoard](src/alerts.ps1) with no job `queued`, `running`, `needs-input` or `failed`, no `done`/`skipped` job ended in the last 2 days, and no lane in `W.blocked` (until in the future) or `W.outage` writes `# chatq`, a blank line, `chatq · 0 queued · watcher running · updated <HH:mm:ss in the culture>`, a blank line, `_nothing queued_`, each line ending in `Environment.NewLine`. Anything else on the board means a handoff in M0 (golden `board/empty.md`) |
| Per queued job: pass over one its own id does not find (a second job file holds the id, or the id is blank or finds another job), with no step and nothing written; the first time its id is met, log `<file>, <file>: the id '<id>' does not find one job - left queued, not run, until that is put right` | [Test-ChatqJobFound](src/watcher.ps1) ([Find-ChatqJob](src/queue.ps1) `-Exact` over the whole queue), [Get-ChatqJobFiles](src/queue.ps1) | port M2 ([jobs::found_by_id](native/crates/chatq-core/src/jobs.rs), [jobs::files_with_id](native/crates/chatq-core/src/jobs.rs)). Before, the pick found nothing and the next pass picked the same job at once, with no wait: under chatqd a `pick` step a pass, forever. The files are named, not written: a write by id could land in the twin's file |
| Per queued job: refresh the lane's block (every 10 min) | [Update-ChatqBlock](src/watcher.ps1) → [Get-ChatqClaudeBlock](src/queue.ps1) / [Get-ChatqCodexBlock](src/queue.ps1) | gate port M2 (the 10 min `scannedAt` rule); the scan: helper `block`, **keep** (§8 risk 3) |
| Due time | [Get-ChatqDueTime](src/watcher.ps1); `nextAt` defaults to now+15 min | port M2 |
| Keep awake on pick, or when a wait is ≤ 6 h | [Set-ChatqKeepAwake](src/watcher.ps1) | port M0 |
| Mark the job being alerted about | `$script:ChatqAlertJob = "#<seq>"` | port M2: passed to every step that can alert |
| Probe gate | [Confirm-ChatqAllowed](src/watcher.ps1), [Enter-ChatqOutage](src/watcher.ps1), [Test-ChatqOutageOver](src/watcher.ps1), [Send-ChatqOutageReminder](src/watcher.ps1), [Block-ChatqLogin](src/watcher.ps1), [Get-ChatqClaudeStatus](src/queue.ps1) | helper (inside `pick`) M2 → M4: the state machine and the status page are native; the probe process ([Invoke-ChatqProbe](src/queue.ps1), [Get-ChatqCodexLiveLimit](src/queue.ps1)) and its block fallbacks: helper `probe`, **keep** (§1.2) |
| Run one job | [Invoke-ChatqJob](src/watcher.ps1) | helper `pick` M2–M4; M5 split three ways (§3.8) |
| One job's error must not end the watcher: `#<seq> error: <msg> @ <first ScriptStackTrace frame>`, fail the job with `chatq error: <msg>` if queued or running, `failed` alert | the `catch` around the pick | the catch moves into a PS function shared by both engines (`Invoke-ChatqPick`, §3.6), so the step logs the identical line. chatqd's own line, and its pick-failure write (§2.4), apply only when a `pick` step ends without a good answer: it did not start, did not load, exited with no answer, or answered `ok:false` (§3.6 Failure) |
| Usage "soon" alert and its wake time | [Send-ChatqUsageSoon](src/phone-extras.ps1), every pass that found nothing due | gate port M2 (vector `usage-soon.json`): the native gate computes the wake time, and a `soon` step runs only when an alert is due. Alert port M6 |
| Usage "reset" alert | [Send-ChatqUsageReset](src/phone-extras.ps1), called in Confirm on allowed | helper `usage-reset` from M4 (Confirm goes native) → port M6 |
| `state.json` save: when not listening, after a poll, or at least every 30 s | [Save-ChatqWatchState](src/watcher.ps1) | port M0 |
| Board `queue.md` | [Write-ChatqBoard](src/alerts.ps1) | port M2 for every write made while `listening` is false. While listening, a `board` step, **keep**: [Get-ChatqBlocks](src/alerts.ps1) then scans transcripts (§2.11) |
| Wait: 2 s steps, `min(30, max(1, secs))`; ends on `stop` or a wake mtime change; capped at `pollEvery` while listening | [Wait-ChatqUntil](src/watcher.ps1) | port M0 |
| `finally`: keep-awake off, delete pid, save state (current/next null, listening false), release lock, log `watcher <pid> stopped` | | port M0 |
| After exit: on restart, respawn. On empty, no `stop`, and a reply window open: log `a phone alert went out as this watcher left - starting another to listen`, respawn | [Start-ChatqWatcherProcess](src/watcher.ps1) | port M0. The respawn uses the native launch decision on the scripts now on disk (§4.2) |
| Foreground mode (`-Foreground`) | `Invoke-ChatqWatchLoop -Foreground` | **keep-PS**: a debugging console. chatqd has `watch --foreground` for its own debugging only |

### 1.2 Inside a run ([Invoke-ChatqJob](src/watcher.ps1), [Invoke-ChatqRun](src/queue.ps1), [Invoke-ChatqProcess](src/queue.ps1))

From M2 to M4 the whole of this table runs inside one `pick` step, unchanged. The fates below are from M5 on. M5 first refactors the PS code along the boundaries named here, with no change in behaviour, so both engines call the same three PS functions (§3.8).

| Duty | Fate from M5 | Why |
|---|---|---|
| Before the run: chat-gone/skip checks, folder gone, [Get-ChatShowHold](src/live-chats.ps1), `Test-ChatqAutoTerminal`/`Get-ChatqAutoHold`, [Resolve-ChatqLiveAction](src/live-chats.ps1) / [Stop-ChatIdleProcess](src/live-chats.ps1) `-JudgeOnly` / [Set-ChatqJobDeferred](src/watcher.ps1), re-find the job, read the prompt and attachments, `Get-ChatqRunCarry`, delete a stale cancel file, set startedAt/attempts/runnerPid/clear defer fields, `running` with `Save -Existing`, the handover ([Invoke-ChatqHandover](src/watcher.ps1), [Write-ChatRunState](src/chatrm.ps1) `running`, `run-ack`), `Stop-ChatqCancelledStart`, the board, `#<seq> running: <title>…`, `New-ChatqPermitRun` when [Test-ChatqPermitReady](src/permit.ps1) | helper `pre-run`, **keep** | Reads VS Code state, the registry and CIM. Rare, and small next to a run. The extension's protocol is unchanged |
| CLI discovery: [Find-ChatqExe](src/queue.ps1) → `Get-ChatqExePick` (`CHATQ_CLAUDE`/`CHATQ_CODEX`, then `Get-Command -CommandType Application` labelled `local` under `~/.local/bin` or `ChatClaudeHome/local`, then local paths for claude, then `Find-ChatqBundledExe`, the newest under `.vscode`, `.vscode-insiders`, `.cursor`, `.windsurf`); [Get-ChatqCliVersion](src/queue.ps1) cached per path; `$script:ChatqClaudeMin = '2.1.259'` and its refusal text `Claude Code <v> is too old for unattended runs - needs 2.1.259+`; `no <provider> CLI found - install it or set CHATQ_<PROVIDER>` | helper (`pre-run` for runs, `probe` for probes), **keep** | Never ported. PATH/PATHEXT resolution and the bundled-extension version sort are PowerShell semantics, and the plan carries the resolved exe (§3.8). The version cache lives in the step carry (§3.6) |
| Building the run: Codex `exec resume --json --skip-git-repo-check -c sandbox_mode=…`, network, `-m`, `-i` images, `--`, session id, `-`; Claude `--session-id/--name` (title scrubbed of `"%!&|<>^` for cmd targets) or `--resume`, `--permission-prompts none` or `host` with `--mcp-config/--permission-prompt-tool/--settings`, Ultracode into the permit settings or `run-settings/<id>.json`, `--effort`, `--add-dir`; run env (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`, `MCP_TOOL_TIMEOUT`, [$script:ChatqRunEnv](src/queue.ps1) where absent, [$script:ChatqEnvDrop](src/queue.ps1)); [Get-ChatqCmdArgRefusal](src/queue.ps1) | helper `pre-run`, **keep**. It returns the **run plan** (§3.8) | The plan carries the exact command line PS built, so there is nothing to port and nothing to drift |
| The CLI process: spawn, stdin, stdout lines to `.jsonl`, stderr, the 5 s tick, the 4 h deadline, cancel, tree kill, exit wait | port M5 (§2.6) | The hot path. Holding PowerShell for hours of a run is where the memory goes |
| Stream state: [Update-ChatqClaudeState](src/queue.ps1) / [Update-ChatqCodexState](src/queue.ps1) into [New-ChatqRunState](src/queue.ps1)'s shape (Init, Session, Model, Mode, Version, PermitServer from init `mcp_servers` named `chatqpermit`, Denied, Retries, Rate, Limit, SyntheticLimit/Overloaded via §2.9's two regexes, Assistant, LastText, Tools, ToolIds, Result; Codex Thread/TurnStarted/TurnDone/TurnFailed/Failed and the rest) | port M5, vector `stream-state.json` | Needed live: Init triggers the `started` alert, Mode goes into its text, ToolIds gate permission requests |
| `started` alert at stream Init (`onStart`): `<title> · <St.Mode or job.mode> · <auto-continue / continue / first prompt line cut to 80 + ellipsis><keepOut>` | helper `run-started`, the moment native parsing first sees `St.Init` | Same moment as today. The reader thread keeps draining stdout while the step runs |
| Mid-run tick (PS `onTick`), in this order: heartbeat state save every 60 s; [Update-ChatqPermitRequests](src/permit.ps1); the quick reply poll (5 s while a permission is open, else 30 s, or 10 s hot: [Get-ChatqReplyPollSeconds](src/phone-down.ps1) `-InRun`; `-TimeoutSec 5 -MaxMessages 2 -Quick`); [Test-ChatqAskLanded](src/ask.ps1) `-Quick`; `data/stop` → `byStop`; return cancel-file-exists or `byStop` | heartbeat, cadence, stop and cancel: port M5; the permission tick: gate port M5 + `permit-tick` step (§3.8); the poll: as §3.7 with `quick`; ask-landed: gate port + step | §3.8 shows that each gate opens exactly when the PS function would have done something |
| Permission bridge for the run ([Start-ChatqPermitBridge](src/permit.ps1) process) | keep-PS until M8 | Its own process, launched by `claude` from `mcp.json` |
| After the run: `wasCancelled`, delete the cancel file, runnerPid null, [Close-ChatqPermitRun](src/permit.ps1) (Refused/NoAnswer ids), `Test-ChatqPermitStartFailed` → `Complete-ChatqPermitStartFailure` (`the permission bridge did not start - queued once more without it: <why>`) or `Clear-ChatqPermitFailure`, the run-settings delete, [Get-ChatqClaudeOutcome](src/queue.ps1) / [Get-ChatqCodexOutcome](src/queue.ps1), late-window detection, `Update-ChatqNewChatPath`/`HeldTitle`, `Confirm-ChatqRunCarry`, [Repair-ChatListed](src/live-chats.ps1), [Show-ChatFresh](src/live-chats.ps1) or `Write-ChatReloadRequest` | helper `post-run`, **keep** | Byte-sensitive edits to Claude Code's index, UI work, the outcome rules |
| **The retry policy**: for limited/overloaded/network/auth, [Test-ChatqPromptLanded](src/queue.ps1) (4 MB tail, the last 40 user lines, a 60-char whitespace-collapsed prefix; Codex by contains) decides `retryAs` continue and `autoContinue`; `noProgress` against [Get-ChatqMaxRetries](src/watcher.ps1) gives up; `Step-ChatqAutoStreak`; network retries 1, 2, 5 min ×3 with `retryAt`/`netRetries` and `network drop - retry k/3 at HH:mm`; auth → [Block-ChatqLogin](src/watcher.ps1); overloaded → [Enter-ChatqOutage](src/watcher.ps1); limited: `resetsAt`, then `Get-ChatqLastTurn`, then `Update-ChatqBlock -Force`, then 15 min, resetting `lastAllowed` for `lane` and `lane|*`, alert only if landed; needs-input; done with turns/asks ([Test-ChatqAsks](src/queue.ps1))/youDenied/note; default failed; the tookSay history; the auto streak; save; board; `finally` [Write-ChatRunState](src/chatrm.ps1) `ended` | helper `post-run`, **keep** | The policy is the product's core judgement. Porting it would duplicate it for no memory gain, since it runs once per run. It changes `W` (blocked, outage, lastAllowed, authAlerted), which comes back in the step's `w` |
| A spawn failure | helper `run-ps` (§3.8) | A .NET start failure surfaces as an exception with a script frame. Only PowerShell can produce that line, so the remainder of the run reruns in PowerShell |
| Alerts: started, done, failed, limited, waiting, overloaded | inside the steps above | §1.4 |

### 1.3 Phone replies

| Duty | Fate | Why |
|---|---|---|
| ntfy `GET <server>/<topic>/json?poll=1&since=<lastId, else the state's since, else now-60>`; the gate on `MinSeconds` via `$script:ChatqReplyPolledAt`; timeouts 8 s (loop) and 5 s (in run); `poll failed:` logged at most every 10 min (`$script:ChatqReplyErrAt`) | port M3 | The listening idle is the long idle |
| Line handling: only `event == "message"`; id must match `^[A-Za-z0-9]{1,40}$`, else a `skipped` log line at most every 10 min (`$script:ChatqReplyBadIdAt`); the `topic\|id` tag checked against `$script:ChatqReplyHandled` | port M3 | |
| Triage ([Test-ChatqReplyMessage](src/phone.ps1)): dispatch by prefix after `TrimStart`, ordinal: `chatq3c.` → [Test-ChatqComposeMessage](src/phone-board.ps1); `chatq2p.` → pairing; otherwise [Unprotect-ChatqReplyMessage](src/phone.ps1). Junk is anything that fails before the MAC checks out, or a pairing message that fails its pre-RSA checks; junk is logged per stage by [Write-ChatqReplyJunk](src/phone.ps1) (once per stage per 5 min, with the count of those not logged) | port M3, **MAC only**: chatqd checks parts, prefix, id, encoding, key presence and the MAC in constant time (§2.8). It never decrypts | A MAC that checks out needs the phone's key, so junk and floods never wake PowerShell, and chatqd needs no AES and no RSA |
| A batch holding no candidate: the junk-only save of `lastId` and `lastPolledAt` under `replies.lock`; `lastPolledAt` alone at most every 5 min when nothing was acted on (`$script:ChatqReplySavedAt`) | port M3, through a native port of [Use-ChatqReplyState](src/phone.ps1) + [Save-ChatqReplyState](src/phone.ps1) with its fixed key set and every prune rule (vector `reply-state.json`), built in M1 as [replystate::use_state](native/crates/chatq-core/src/replystate.rs). Where the file holds what the editions read in ways not ported, the answer is `Error::PsOnly`: nothing is written and the change is left to PowerShell (DEFERRED.md "The reply registry's reads left to PowerShell") | So replies.json is written exactly as PS writes it, prune included |
| A batch holding at least one **candidate** (a MAC that checks out under any label, or a pairing message that passes the pre-RSA checks while a pairing is pending): the whole batch, junk lines included and in order, goes to one `reply` step that runs the original poll body over it | helper `reply`, **keep** (§3.7) | That keeps every rule exact: the nonce replay check, the one-lock record block (`lastId`, `lastPolledAt`, spent nonce, `uses+1`, the fails: seen, unreadable, too old, expired, ≥ 20 uses; then `lastReplyAt`), **save before act**, the stop at the first `unsaved`, the refusal push (at most once per 10 min per aid, `refused[aid]`), the `reply` alert, [Invoke-ChatqReply](src/phone.ps1), `MaxMessages` counting genuine messages only |
| Compose and board messages ([Receive-ChatqCompose](src/phone-board.ps1)): per-act age (`$script:ChatqComposeActs[act].Age`: 600 s for a look, 1800 s for a change), hourly limits (`$script:ChatqComposeLimits`, plus `new`), handles in `picks`, the down budget (`Add-ChatqDownSpent`), `hotUntil` +2 min, a refusal acked on the down topic at most once a minute (`composeRefusedAt`) | helper `reply`, **keep** | Comes with acting |
| Pairing `chatq2p.` (RSA-OAEP-SHA256 decrypt, [Unprotect-ChatqPairMessage](src/phone.ps1), [Receive-ChatqPairing](src/phone.ps1)) | helper `reply`, **keep** | Avoids the `rsa` crate's Marvin timing advisory (RUSTSEC-2023-0071); pairing is rare and interactive |
| The board's down messages: raw deflate, inflate capped at 4 MB ([Expand-ChatqBytes](src/phone-down.ps1)) | helper, keep (comes with acting) | Port only if a down path moves native |
| Streaming the topic instead of polling | **not done** | DEFERRED.md "The phone board answers in seconds, not at once" is a decision; the port keeps polling |

### 1.4 Alerts ([Send-ChatqAlert](src/alerts.ps1))

**One rule decides the engine for each alert.** An alert that [Send-ChatqAlert](src/alerts.ps1) would register as answerable (every non-`-NoReply` alert while `Rc.Links` is set, through [New-ChatqReplyAlert](src/phone.ps1) and `Update-ChatqReplyFull`) runs whole in an `alert` step. Its link goes into the push, so registration cannot be split from sending. Only unregistered alerts are native from M6. The decision is made natively from config, vector `alert-route.json`.

| Duty | Fate | Why |
|---|---|---|
| Held summary first unless `-Quick` | with the alert's engine | |
| `alerts.log` line: `<local o>\t<event>\t<text, whitespace runs to one space>\n` | port M6 | |
| Toast (Windows): WinRT under Windows PowerShell's AUMID `{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`, text cut to 300 chars, ToastGeneric XML | port M6. The fallback is a `toast` step running [Show-ChatqToast](src/alerts.ps1), never a new place that builds the Windows PowerShell path (DEFERRED.md "The Windows PowerShell path built in eight places") | |
| Toast (macOS): `osascript display notification` | port M6 | |
| ntfy publish (JSON to the server root, priority 3/4/5, `click` only over https, Bearer token) | port M6 | [Send-ChatqNtfy](src/alerts.ps1) |
| Join (GET URL, 3 tries, 2·n s backoff, 20 s / 8 s timeout, notification id `chatq-<sid12>`) | port M6 | [Send-ChatqJoin](src/alerts.ps1), [Get-ChatqJoinUrl](src/alerts.ps1) |
| Presence gate (`quietMinutes`, idle from [Get-ChatqIdleSeconds](src/alerts.ps1)), phone events filter, present-and-not-Loud skip, quiet hours, hold rules, the footer | port M6 | [Test-ChatqUserPresent](src/alerts.ps1), [Test-ChatqUserAway](src/alerts.ps1), [Test-ChatqHoldAlert](src/phone-extras.ps1) |
| Registration, link, `Update-ChatqReplyFull`, `Open-ChatqReplyWindow` | **helper, keep** (the `alert` step) | Registry writes under `replies.lock`; card sealing |
| After a send: start a watcher if `CHATQ_WATCHER` is not `1` and none is alive | not applicable | chatqd and its steps always have `CHATQ_WATCHER=1` |
| The user's `command` channel (`CHATQ_EVENT/TITLE/TEXT/PRIORITY/JOB/PRESENT/LINK/QUIET`, 30 s or 8 s `-Quick`, skipped when the alert carries links) | **keep-PS** | It *is* a PowerShell script, run as `<host exe> -NoProfile -NonInteractive -EncodedCommand` by [Invoke-ChatqAlertCommand](src/alerts.ps1). The host exe there is `(Get-Process -Id $PID).Path`, which in chatqd is `--ps`. Spawned directly from M6, the same as the PS ProcessStartInfo |
| Linux `notify-send` | drop | No Linux build target. Linux keeps the PS engine (§4.2) |

### 1.5 Not the watcher's, so out of scope

These are left as they are:

- the outbox sender ([Get-ChatqOutboxLaunch](src/phone.ps1));
- [Start-ChatqReplyStanding](src/phone-down.ps1);
- the ghost watch ([Start-ChatGhostWatch](src/chatrm.ps1));
- the overlay and the console;
- the ask hook and the permit bridge (M8 sketches them);
- every user command, including [Request-ChatqWatcher](src/commands.ps1) / `Test-ChatqWatcherRequest` (their 10 s look-again and one respawn stay, and §4.2's fuse uses them).

Deferrals the port keeps, not fixes. Each is checked against DEFERRED.md or FUTURE_WORK.md, and the one-line consequence for chatqd is given:

- "Listening all the time off Windows": macOS restarts listening only with a shell; chatqd adds no OS registration.
- "Start at boot": nothing is registered with the OS.
- "A `claude -p` that is not chatq's".
- "The phone board answers in seconds, not at once": polling stays.
- "Ending a chat's process off Windows": `pre-run` keeps the Windows-only path.
- "CI on macOS and Linux" for the PS suite.
- "A Codex all-clear still spends a turn": the `probe` step keeps the exec probe after the app-server says nothing.
- "The Windows PowerShell path built in eight places": chatqd never builds that path; it uses `--ps` or a step.
- "Usage heads-ups without the overlay": native alerts add no threshold usage alert; only soon/reset come from the watcher.
- "Quiet hours: one window, this PC's clock": the native quiet-hours check uses one window and the local clock.
- "A reply refused as moved on loses its text": unchanged inside the `reply` step.
- "Auto-continue on Linux, and the phone's switch": Linux runs the PS engine anyway.
- "Answering a permission prompt at the PC": the permission tick adds no PC-side answering.
- "A mode switched at the PC while a question waits": kept, in the step and later in the M8 stub.
- "A lighter launcher for the ask hook": closed only by M8's byte-equal test, never by this watcher.
- FUTURE_WORK.md "The Codex app-server floor is a guess": `$script:ChatqCodexAppServerMin = '0.159.0'` stays as is, inside the `probe` step.

---

## 2. Contracts

Paths are relative to the tool root `R` (`$script:ChatRoot`); `D = R/data`. Every runtime file stays in `D`, never `%LOCALAPPDATA%`, `%APPDATA%` or `%TEMP%`. chatqd's own scratch goes in `D/native/` (§4.5). The writer and reader columns name the PS owner. chatqd must behave as that owner does.

### 2.1 File primitives (from [src/queue.ps1](src/queue.ps1))

- **Atomic save** ([Save-ChatqText](src/queue.ps1)):
  1. Write `<path>.tmp` as UTF-8 **without BOM**.
  2. If the target exists, `File.Replace(tmp, path, null)`; Rust uses `ReplaceFileW(path, tmp, NULL, 0, …)` on Windows, with no flags as .NET passes for `ignoreMetadataErrors = false`, and `rename(2)` on Unix. Otherwise `Move`.
  3. Up to 5 tries, sleeping `100·n` ms between them.
- **Existing-only update** ([Update-ChatqText](src/queue.ps1)): Replace only. If the target is gone, delete the tmp and return false. Never recreate a deleted job.
- **Read JSON** ([Read-ChatqJson](src/queue.ps1)): `Get-Content -Encoding UTF8`, 3 tries, 100 ms apart. A leading BOM is tolerated. A parse failure after 3 tries means null. chatqd's is [fsx::read_json](native/crates/chatq-core/src/fsx.rs), which takes the running PowerShell's flavour; the grammar and the tolerances are in §2.2.
- **Lock files** ([Open-ChatqLock](src/queue.ps1)). chatqd takes `replies.lock` (M3 junk-only saves) and `watcher.lock` (§4.3). It never takes `config.lock`: it reads `config.json` with no lock, as [Get-ChatqConfig](src/alerts.ps1) does (the atomic save keeps a reader from seeing half a file), and never writes it, since no command sets the engine key. Steps take the rest as PS does. The full set, for completeness: `config.lock`, `job-numbers.lock`, `replies.lock`, `outbox.lock`, `held.lock`, `usage-alerts.lock`, `auto-continue.lock`, `signal.lock` ([src/core.ps1](src/core.ps1)) and `idle-ended.lock` ([src/host-work.ps1](src/host-work.ps1)). There are also two liveness locks chatqd never touches: `overlay.lock` ([src/overlay-data.ps1](src/overlay-data.ps1)) and `phone-setup.lock` ([src/phone-setup.ps1](src/phone-setup.ps1)).
  - open `OpenOrCreate`, `ReadWrite`, share **None**;
  - retry for 3 s with random 15–60 ms sleeps;
  - hold for the read-change-save, then close.
  - Rust on Windows: `OpenOptions::new().read(true).write(true).create(true).share_mode(0)`; `ERROR_SHARING_VIOLATION` means retry.
  - Rust on Unix: `open(O_CREAT|O_RDWR|O_CLOEXEC)` then `flock(LOCK_EX|LOCK_NB)`, which is what .NET does for `FileShare.None` on Unix; `EWOULDBLOCK` means retry.
- **Handles are never inheritable.** Rust std's default (`bInheritHandle=FALSE`, `O_CLOEXEC`) is required. A run's `claude` must never inherit `watcher.lock`. On Windows the run spawn also passes `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` with exactly the three pipe ends (§2.6).

### 2.2 JSON

- **Writer.** Everything PS writes goes through `ConvertTo-Json -Depth 8` ([Save-ChatqJson](src/queue.ps1)). chatqd writes with `serde_json` and `preserve_order`, pretty-printed. Byte equality with PS output is **not** required; semantic equality is. One exception: `replies.json` keeps [Save-ChatqReplyState](src/phone.ps1)'s fixed key set and prune rules (§1.3).
- **Unknown fields are preserved** in job, state and config objects. They are kept as `serde_json::Value` maps with typed accessors over them. A write never drops a key it does not know.
- **Arrays stay arrays.** A one-element array never collapses to a scalar, which is PS 5.1's own trap. Typed fields that are arrays always serialise as arrays.
- **Integers stay integers.** `pid`, `runnerPid`, `seq`, `attempts`, `endLen` are JSON integers, never `1.0`.
- **Stamps** are strings:
  - UTC is `.ToUniversalTime().ToString('o')`, as in [Get-ChatqStamp](src/queue.ps1). That is `yyyy-MM-ddTHH:mm:ss.fffffffZ`, **7 fractional digits**.
  - Local is `(Get-Date).ToString('o')`, e.g. `2026-10-15T09:12:03.1234567+09:00`. Used in log lines and `run-state.at`.
  - **chrono has no `%.7f`.** chatq-core `time.rs` formats by hand ([time::stamp_utc](native/crates/chatq-core/src/time.rs), [time::stamp_in](native/crates/chatq-core/src/time.rs)): `%Y-%m-%dT%H:%M:%S`, then `.` and `subsec_nanos / 100` zero-padded to 7 digits, then `Z` or the `±HH:MM` offset. Unit tests pin the 7 digits and the zero padding (`.0000000`); `time::tests::offset_form_at_a_dst_change` pins the offset form either side of a DST change, through [Zone::Change](native/crates/chatq-core/src/time.rs). The host zone's own changes are the live check `local-stamps` (§6.1).
- **Reading stamps**, as [ConvertTo-ChatqDate](src/queue.ps1) does (InvariantCulture, RoundtripKind, then ToLocalTime), is [time::parse_stamp_in](native/crates/chatq-core/src/time.rs). It accepts:
  - 7-digit `o` with `Z` or an offset;
  - fewer fractional digits;
  - no fraction;
  - pwsh 7's re-serialised DateTime. pwsh 7's `ConvertFrom-Json` turns ISO strings into `DateTime`, and a later `ConvertTo-Json` writes them back with up to 7 digits and with `Z` or an offset by Kind;
  - Windows PowerShell 5.1's `"\/Date(<ms>)\/"`, should a DateTime ever be written unconverted.
  - Anything else means what ConvertFrom-Json and then `[datetime]::Parse` make of it. `stamps.json` pins the shapes (hour 24 and offsets up to 99:99 on pwsh 7, the space form, years of 3 to 8 digits, and more), and `parse_stamp_in`'s doc lists what is not ported (DEFERRED.md "Dates past the shapes the vectors pin").
  - **A stamp with no zone differs by flavour.** On 5.1 it stays a string, `Parse` gives Kind Unspecified, and `ToLocalTime` treats that as UTC. On pwsh 7 `ConvertFrom-Json` has already made it a DateTime of Kind Unspecified, which [ConvertTo-ChatqDate](src/queue.ps1) returns as is: local wall-clock time. chatqd follows its `--ps` flavour. PS itself never writes one; the vector `stamps.json` keys this case by flavour.
  - On pwsh 7 a zoneless stamp is wall-clock time. Where a DST change skips or repeats it, .NET reads it at the zone's standard offset ([time::resolve_offset](native/crates/chatq-core/src/time.rs), which [Zone::instant_of](native/crates/chatq-core/src/time.rs) uses; the `stamps.json` dst cases), not at the earlier instant.
  - PowerShell compares DateTimes by ticks and ignores Kind. Within a DST change's hour, PS's comparison of a pwsh 7 zoneless stamp with `Get-Date` can differ from chatqd's comparison of instants by the DST delta. PS never writes such a stamp, so this is noted, not modelled.
  - A stamp field is read from the parsed value, whose escapes are gone, so `parse_stamp_in` reads every `/Date` as escaped, as 5.1 writes it. Nothing writes the unescaped form. The file read itself tells the two apart under 5.1 (**Dates**, below).
- **Never emit** two keys differing only by case, or an empty key. PS 5.1's `ConvertFrom-Json` throws on both.
- **Escapes.** 5.1 escapes `<>'&` as `\u003c…`. Both grammars below read that.
- **One grammar per edition.** Every JSON text chatqd reads as PowerShell reads it, a data file or a run's stream line (§2.9), goes through one reader per PowerShell edition, `json::ps_read` in [json.rs](native/crates/chatq-core/src/json.rs): that edition's own `ConvertFrom-Json`, not `serde_json`'s grammar.
  - **5.1** (JavaScriptSerializer, `json::Desk`) takes single quotes; bare names of letters, digits and `. - _ +`; a leading or trailing sign; `NaN`; raw control characters in a string; a spaced Unicode escape. It takes no comment and no trailing comma. Nesting past 102 values is refused, a number or string counting as one. A scalar `__type` is dropped; a list or object `__type` is refused. A name given twice keeps its first place and takes its last value.
  - **pwsh 7** (Newtonsoft, `json::Newt`) takes `//` and `/* */` comments, though not between a name and its colon, and a bare `//` or an open `/*` at the end throws; trailing commas; empty list slots; `undefined`; `NaN` and `Infinity`; octal and hex; bare names of letters, digits, `_` and `$`. An integer is an Int64, then a BigInteger, then a double. Nesting past 1024 containers is refused. A name given twice moves to the end with its last value.
  - **Both** refuse, at any depth, an empty name, two names that differ only by case as that .NET folds them (`json::fold_eq`), and PSObject's own names (`psobject`, `psbase`, `psadapted`, `psextended`, `pstypenames`): the read gives `$null`, as both throw. A surrogate escape (U+D800 to U+DFFF) that is not half of a pair reads as U+FFFD, as both `ConvertFrom-Json` do. 5.1 writes one when a title is cut mid-pair.
  - **Dates.** Every string value goes through [time::json_date](native/crates/chatq-core/src/time.rs), the crate's one reader of JSON dates, which `parse_stamp_in` and replystate.rs use too. 5.1 makes a DateTime only of `"\/Date(-?digits[letter|±4 digits])\/"` spelled so in the file: a single-quoted or unescaped one stays text, and a 20-digit body is read, as `long.Parse` takes leading zeros. pwsh 7 makes one of Newtonsoft's `/Date(ms[±hh[mm]])/`, its ms read to 19 digits (20 stay text), and of an ISO string of 19 to 40 UTF-16 units with `T` at index 10 (hour 24 is the next day), single-quoted or not; its unescaped `/Date` offset-minutes quirk is read as if escaped. A date out of DateTime's range makes the whole read throw, as it does in both PowerShells. The value keeps the string either way.
  - **The stack guard.** A read runs capped at 32 levels on the caller's thread ([json::on_deep_stack](native/crates/chatq-core/src/json.rs)). A deeper one is read again, uncapped, on a scoped thread with an 8 MB stack, so the 102 and 1024 limits hold on any caller's stack. A panic there is resumed on the caller.
- **The file read** is [json::parse_tolerant_in](native/crates/chatq-core/src/json.rs)`(bytes, flavour)`, which gives a [json::Tolerant](native/crates/chatq-core/src/json.rs) `{value, repaired, lossy}`:
  1. The bytes are decoded as that .NET decodes them ([utf8::read_text](native/crates/chatq-core/src/utf8.rs)): a BOM followed, an invalid sequence U+FFFD. The vector `json-compat.json` pins the U+FFFD count per invalid sequence on both PS flavours.
  2. Text that is empty or white space only gives None: Read-ChatqJson's `$null`, with no throw. A pwsh 7 file of comments alone gives JSON null.
  3. The edition's grammar runs under the stack guard, and the value comes back in `serde_json` form, keys in order. The top level is not unrolled here; [json::ps_return](native/crates/chatq-core/src/json.rs) does that where the caller's `return` would.
  - **`repaired`**: what Read-ChatqJson read differs from the file as written. That is a byte that did not decode, a byte dropped at the end (5.1), or a lone surrogate escape. A U+FFFD the file itself holds is no repair.
  - **`lossy`**: the value holds a number JSON cannot. A `NaN`, `Infinity` or `-Infinity` (and pwsh 7's `1e400`) is held as its `[string]` text, which `if`, `[string]` and `[int]` treat as PS treats the double. A pwsh 7 BigInteger past a double's range is held as its digits. Written back, either would be a string.
  - A file that is `repaired` or `lossy` is **never rewritten by chatqd**. A write chatqd would make to it goes through a `job-write` step ([Save-ChatqJob](src/queue.ps1) `-Existing`), so the .NET value keeps what PS read, a lone surrogate included. So does a job file that holds a list rather than one job object, which Save-ChatqJob writes back as the one job. One line goes to `chatqd.log` per file.
  - A string a job file spells `"\/Date(...)\/"`, as 5.1's `ConvertTo-Json` writes a DateTime, is written back so by chatqd ([jobs::fail_job](native/crates/chatq-core/src/jobs.rs), [jobs::clear_defer](native/crates/chatq-core/src/jobs.rs)): it is the one spelling 5.1 reads as a date, and `serde_json` would drop the escapes.
  - Paths inside JSON are strings and follow the same rule. File names chatqd itself lists (`D/queue/*.json`) are chatq-made ASCII ids; anything else is skipped as [Get-ChatqJobs](src/queue.ps1) would skip it.
- **The flavour each read takes.** A data file is read as the PowerShell chatqd stands in for reads it. `--ps` names the flavour ([Flavour::from_exe](native/crates/chatq-core/src/time.rs)), and [fsx::read_json](native/crates/chatq-core/src/fsx.rs), [config::read_config](native/crates/chatq-core/src/config.rs) and [jobs::read_jobs](native/crates/chatq-core/src/jobs.rs) take it, for `state.json`, `auto-continue.json`, `config.json`, the queue's jobs and the reply window's look at `replies.json` ([gates::reply_open](native/crates/chatq-core/src/gates.rs)). So under pwsh 7 a `config.json` with comments and trailing commas reads as the PS watcher reads it; under 5.1 it reads as empty, as Get-ChatqConfig gives. `read_config` unrolls a top-level list as Get-ChatqConfig hands it on: `ps_return`, then once more for its own `return $c`. The exceptions:
  - the launch records in `D/native/` (pending, last, verified, fuse) are always read as 5.1 reads them ([launch::RECORDS](native/crates/chatq-core/src/launch.rs)), whichever PowerShell or chatqd decides, so a decision never turns on who makes it (DEFERRED.md "data/native records read as 5.1 reads them");
  - the seams file (`CHATQ_NATIVE_SEAMS`, §6.5) is read as pwsh 7 reads it;
  - `replies.json` ([replystate::read](native/crates/chatq-core/src/replystate.rs)) refuses a UTF-16 or UTF-32 file itself, then reads by the shared grammar. A `repaired` or `lossy` file is [replystate::Error::PsOnly](native/crates/chatq-core/src/replystate.rs), and nothing is written (§1.3; DEFERRED.md "The reply registry's reads left to PowerShell");
  - the reply poll's ntfy lines ([wire::poll_batch](native/crates/chatq-core/src/wire.rs)) are read by `serde_json`, lone surrogate escapes made U+FFFD first, not by the shared grammar (DEFERRED.md "ntfy's lines read as strict JSON").
- **One `[string]`.** [json::ps_string](native/crates/chatq-core/src/json.rs) renders a value as PowerShell's `[string]` does: an object as `@{k=v; ...}`, a double in G15 (`1E+20`), a list as its items joined by spaces. [json::to_ps_string](native/crates/chatq-core/src/json.rs) is that for a value of the file read, by 5.1's rules. The editions differ only on a negative zero (5.1 `0`, pwsh 7 `-0`), which it does not follow (DEFERRED.md "Numbers as a JSON read holds them"). A property lookup ([json::get](native/crates/chatq-core/src/json.rs)) tries the exact name, then one that differs only by ASCII case, which is what `OrdinalIgnoreCase` finds for the ASCII names chatq asks for.
- **Known differences from PowerShell**, each pinned by a test where one can be:
  - pwsh 7's `new Name(...)` constructors: pwsh 7 reads `new Date(ms)` as a date and drops a property holding any other; `ps_read` throws, so the file reads as `$null` (DEFERRED.md "pwsh 7's JSON constructors"; `json::tests::a_constructor_is_refused_a_known_divergence`).
  - A 5.1 decimal (`1.50`) is a double in the file read, so its scale is lost and its `[string]` is `1.5`; an integer past a u64 is the nearest double (DEFERRED.md "Numbers as a JSON read holds them"). The stream read keeps the scale (§2.9).
  - The culture-aware `-eq` and `@{}` compares are approximated: [json::ieq](native/crates/chatq-core/src/json.rs) by Rust's upper case past ASCII, 5.1's ToolIds keys by [stream::culture_fold_eq](native/crates/chatq-core/src/stream.rs) (DEFERRED.md "PowerShell's culture compares, approximated").
  - A list where chatq writes an object: PowerShell's `.name` member-enumerates it; `json::get` finds nothing there (DEFERRED.md "A list where chatq writes an object").
  - pwsh 7 turns any string field that is exactly an ISO stamp into a `[datetime]`, which display code prints as `MM/dd/yyyy HH:mm:ss`. chatqd keeps the string, as 5.1 does, so its board prints such a title as 5.1 does. Accepted drift (DEFERRED.md "Dates past the shapes the vectors pin").
  - Depth limits and the name pairs the editions fold differently are pinned by json.rs unit tests (`nesting_as_deep_as_each_convertfrom_json_reads`, `names_fold_as_each_dotnet_folds`), from probe output. Vectors cannot carry them: each edition reads the vector files back under its own limits and folds.

### 2.3 Logs

- [Add-ChatqLogLine](src/queue.ps1) for `watcher.log`, `jobs.log`, `replies.log`, `outbox.log`, `permit.log`, `ask.log`:
  - in `D/logs/`;
  - each line is `<local o><two spaces><text>\n`: LF, UTF-8 without BOM, appended. The text is written raw: a CR or LF inside it is not collapsed, and a last line with no LF gets the next line joined to it;
  - before appending, if the file is over 1 MB (strictly more than 1,048,576 bytes), move it to `<name>.1`, overwriting.
  - chatqd uses the same function for `watcher.log`, and from M3 for `replies.log`. [Write-ChatqReplyLog](src/phone.ps1) collapses each run of CR and LF to one space, then writes `phone: <text>` to `watcher.log` and `<text>` to `replies.log`; chatqd does both for its junk lines.
  - Concurrent appenders never write at the same time by construction: chatqd is blocked while a step runs. The one exception is the run's `.jsonl`, written by chatqd's reader thread, which no step writes. Each append opens the file `FILE_APPEND_DATA`, writes once and closes.
- `D/logs/alerts.log`: `<local o>\t<event>\t<text>\n`, as in [Send-ChatqAlert](src/alerts.ps1). The event is raw, each run of white space in the text becomes one space, and the file never rolls.
- `D/logs/<jobId>.jsonl`: the raw CLI stream, exactly as [Invoke-ChatqProcess](src/queue.ps1) writes it:
  - opened **after** the child starts, for **append** (never truncated: attempts follow one another in the one file), UTF-8 without BOM, share **read** (`StreamWriter`'s `FileShare.Read`), so the extension's live tail can read it;
  - each stdout line as decoded (§2.6), followed by **`Environment.NewLine`: CRLF on Windows, LF on macOS**;
  - **flushed after every line** (`StreamWriter.Flush`: to the OS, not an fsync);
  - an empty line is written as an empty line;
  - lines over 1,048,576 UTF-16 code units are written in full and not parsed (§2.6).
  - The M5 vector compares these bytes with a PS-run of the same fake CLI.
- `D/logs/chatqd.log` (new): chatqd-only diagnostics, same line format and roll.

### 2.4 Watcher files

| File | Format | Writer | Readers |
|---|---|---|---|
| `D/watcher.lock` | Empty. **Liveness = held**: some process has it open with share None (Windows) or `flock(LOCK_EX)` (Unix) | the watcher, for its whole life | [Test-ChatqLockHeld](src/alerts.ps1) via [Test-ChatqWatcherAlive](src/alerts.ps1) (missing → false; `Open(Open, ReadWrite, None)` succeeds → false; throws → true); extension `watcherUp` in [extension.js](extension/extension.js) (`io.lockHeld` on win32, opening `r+` with EBUSY meaning held) |
| `D/watcher.pid` | ASCII decimal pid, then `Set-Content`'s newline (`\r\n` on Windows, `\n` on Unix). Informational, plus the fuse's crash signal (§4.2) | watcher | humans, tests, the fuse |
| `D/state.json` | `{pid, version, startedAt, heartbeat, current, next, blocked:{lane:{until,type,source[,at]}}, outage:{lane:{since,next,lastProbe,status,attempts,alerted,reminded,autoJob}}, authAlerted:[lane], handoff, listening}`. The top-level field order is [Save-ChatqWatchState](src/watcher.ps1)'s; lanes and the fields of a lane's entry are in hashtable order in PS, so their order is no contract. Stamps UTC `o`. An `autoJob` of `[]` restores as null ([WatchState::restore_in](native/crates/chatq-core/src/state.rs)) | watcher | [Get-ChatqState](src/alerts.ps1), [Get-ChatqBlocks](src/alerts.ps1) (trusts it only when the watcher is alive and not listening), [Restore-ChatqWatchState](src/watcher.ps1) (only when `handoff`), extension `queueBlocks`, and **on macOS the extension's liveness test: `state.pid` alive**. `pid` must be the lock holder's pid, never a step's (§3.6) |
| `D/stop` | Existence | `chatqrun -Stop` | watcher: delete, then exit; mid-run it also cancels the run (`byStop`, §3.8) |
| `D/restart` | Existence | `chatinstall`, `install.ps1` | watcher (not foreground): delete, then handoff |
| `D/wake` | ASCII `poke` \| `now` \| `seen` and a newline; **mtime** is the signal | [Send-ChatqWake](src/watcher.ps1) | watcher; `now` honoured only when `UtcNow - LastWriteTimeUtc < 5 min`. The watcher writes `seen` after taking a `now` |
| `D/queue/<id>.json` | Job object (many fields). chatqd itself writes only two things, both Update-only (a file removed meanwhile stays removed): `deferUntil` set to null by the `-Now` wake (only on a job whose `deferUntil` is set, as `if ($j.deferUntil)` writes; [jobs::clear_defer](native/crates/chatq-core/src/jobs.rs)), and the pick-failure fields below. A file read `repaired` or `lossy` (§2.2) is never written by chatqd: the same change goes through a `job-write` step. Everything else is written by steps | shells, overlay, extension, watcher | everyone |
| `D/queue/<id>.cancel` | Existence | `chatqrm`/cancel | watcher, mid-run and in repair |
| `D/queue.md` | Board text, lines ending in `Environment.NewLine` | [Write-ChatqBoard](src/alerts.ps1) | humans, extension link |
| `D/run-state` | JSON ([Write-ChatRunState](src/chatrm.ps1)), `runnerPid` = the lock holder's pid (§3.6) | watcher (steps, keep) | extension handover, `runIsLive` |
| `D/run-settings/<jobId>.json` | `{"ultracode":true}`, exists only during a run | `pre-run` writes, `post-run` deletes | `claude --settings` |
| `D/config.json` + `config.lock` | Config, read-only for chatqd, with no lock (§2.1) | `chatnotify`, setup, etc. | everyone |
| `D/replies.json` + `replies.lock` | Reply registry and window | steps for everything; **chatqd from M3 for the junk-only saves of `lastId`/`lastPolledAt`**, through its port of [Use-ChatqReplyState](src/phone.ps1)/[Save-ChatqReplyState](src/phone.ps1) | chatqd reads it for the window, `hotUntil`, `lastId`/`since` and key presence |
| `D/permit/<jobId>/*.req.json`, `*.sent.json`, `mcp.json`, `settings.json` | As [src/permit.ps1](src/permit.ps1) writes them | bridge, steps | chatqd from M5 lists `*.req.json` and reads `rid`, `answer`, `withdrawn` and the mtime for its gate (§3.8) |
| `D/held.jsonl`, `D/held-*.sending`, `usage-alerts.json`, `auto-continue.json`, `auto/`, `ask/`, `outbox/` | As their owners write them | PS owners | chatqd reads `held.jsonl` existence and `held-*.sending` mtimes (M2), `usage-alerts.json` keys (the soon gate) and `auto-continue.json` (the auto gate); the rest only through steps |
| `D/native/…` | §4.5 | chatqd and steps | chatqd, steps, the launcher |

**The pick-failure write** (`jobs::fail_job`). A `pick` step that ends without a good answer (§3.6 "Failure") is failed by chatqd as the loop's own catch in [Invoke-ChatqWatchLoop](src/watcher.ps1) fails a job, through [Complete-ChatqJob](src/watcher.ps1) and [Set-ChatqJobState](src/queue.ps1). `<reason>` is one of §3.6's four: `did not start`, `did not load (exit 3)`, `exited <code> with no answer`, `failed: <error>`. `<seq>` and `<title>` are `[string]` of the job's `seq` and `title` ([json::to_ps_string](native/crates/chatq-core/src/json.rs)), empty when absent. In `watcher.log` (item 1) `<seq>` is the job as chatqd listed it for the pick, as the loop logs `$pick.seq`, so the line is written even when the job is gone; in `jobs.log` and the alert (items 4 and 5) both come from chatqd's re-read (item 2), as the loop's `$j`. `·` is `$script:ChatqDot`, U+00B7.

1. Always: `watcher.log` gets `#<seq> error: helper step <reason>` ([Write-ChatqWatchLog](src/watcher.ps1)'s form).
2. The job is read again by id. Only if it is there and its `state` is `queued` or `running` (case-blind, as `-in` compares) is anything written. Otherwise nothing more happens: no write, no `jobs.log` line, no alert.
3. The write, Update-only (§8 "A pick failure is written Update-only, and its alert waits for the write"), in this order (a field the job lacks is added at the end, as `Set-ChatqProp` adds it):
   - `result` = `{"kind":"failed","reason":"chatq error: helper step <reason>"}`;
   - `endedAt` = UTC `o` now ([Get-ChatqStamp](src/queue.ps1));
   - `endLen` = the length in bytes of the file the job's `path` names, as a JSON integer, or null when `path` is empty or names no file;
   - `runnerPid` = null;
   - `state` = `failed`;
   - `history` = the old list plus `{"at":"<UTC o>","state":"failed","why":"chatq error"}`. A null `history` gives `[null, {…}]`, since PS's `@($Job.history)` holds one `$null`; a scalar one is a list of one. A job with **no** `history` property is not written at all, so it gets no `jobs.log` line and no alert (PS still alerts; §8 "A pick failure is written Update-only, and its alert waits for the write"): Set-ChatqJobState assigns `$Job.history` without Set-ChatqProp, which throws on a property a ConvertFrom-Json object lacks, and the loop's `catch {}` swallows it before the save. A `job-write` `complete` on such a job fails the same way.
4. Only if the file was written: `jobs.log` gets `#<seq> failed - chatq error · <title>` ([Write-ChatqJobLog](src/queue.ps1)'s form). A title that is empty leaves the line ending in `· `.
5. Only if the file was written: the `failed` alert goes through an `alert` step, with text `<title> · chatq error: helper step <reason>` and priority 2 (§3.6 "Failure").

If the re-read file is `repaired` or `lossy`, steps 3 and 4 are done by a `job-write` step with `complete` (§3.6 ops), and its `saved` result stands for "was written".

**Job order** ([Get-ChatqJobs](src/queue.ps1)), sort keys in order:

1. `first` true → 0; `kind` `continue` or `rule` `restart` → 1; else 2 (ascending).
2. `first` date, descending.
3. `createdAt` date, ascending.
4. `[int]seq`, ascending. A `seq` that `[int]` cannot convert ranks as `$null`: below 0, above negatives. pwsh 7 reads a blank `seq` as 0 ([jobs::ps_int](native/crates/chatq-core/src/jobs.rs)).

The sort is **not stable**. `Sort-Object` without `-Stable` leaves jobs whose four keys tie in an order of its .NET's own: 5.1's depth-limited quicksort, which swaps even two equal jobs, and pwsh 7's introsort. Its input is `Get-ChildItem`'s order, which also differs by edition, though not for chatq's GUID job file names ([jobs::job_files](native/crates/chatq-core/src/jobs.rs) lists as 5.1 does; DEFERRED.md "PowerShell's culture compares, approximated"). [jobs::order_jobs](native/crates/chatq-core/src/jobs.rs) does each edition's sort, `jobs-order.json` pins the ties per edition, and chatqd follows the flavour it stands in for.

**Lane** ([Get-ChatqLane](src/watcher.ps1)): `provider` or `provider|home`, split at the first `|`. Display names ([Format-ChatqLane](src/watcher.ps1), [Format-ChatqProvider](src/watcher.ps1)) use `Get-Culture`'s `ToTitleCase` on the provider part, which chatq-core ports per flavour ([Culture::title_case](native/crates/chatq-core/src/culture.rs)). `claude` and `codex` title-case the same in every culture. Other text does not: tr and az cultures case `i` as `İ` and `I` as `ı`, pwsh 7 alone turns a word-initial `ij` into `IJ` under nl-* cultures, and an all-capitals word stays as it is. `culture.json` holds this under `tr-TR` and `nl-NL`; `jobs-order.json` holds [Get-ChatqLane](src/watcher.ps1) ([jobs::lane](native/crates/chatq-core/src/jobs.rs)).

### 2.5 Environment

| Var | Contract |
|---|---|
| `CHATQ_WATCHER=1` | Set in the watcher's own environment and so inherited by everything it starts. [Send-ChatqAlert](src/alerts.ps1) reads it to avoid starting a second watcher, and so do the loader's auto-start block, [Start-ChatGhostWatch](src/chatrm.ps1), [src/discoverability.ps1](src/discoverability.ps1), [src/commands.ps1](src/commands.ps1) and [src/phone-board.ps1](src/phone-board.ps1). chatqd sets it at startup, so every step and run inherits it |
| `CHATQ_CLAUDE`, `CHATQ_CODEX` | Carried from the starting shell into the launch ([Get-ChatqWatcherLaunch](src/watcher.ps1)); [Find-ChatqExe](src/queue.ps1) honours them inside `pre-run` and `probe` steps, which inherit them from chatqd |
| `PSExecutionPolicyPreference` | Removed from the watcher's environment before anything runs, so children do not inherit `Bypass`. chatqd removes it at startup; `src/native-step.ps1` removes the one its own `-ExecutionPolicy Bypass` sets |
| `CHATQ_ROLE` | Loader-only; dropped once read. chatqd's steps do not set it (§3.6) |
| Run env | Built by `pre-run` and carried in the plan as a delta (§3.8): `CLAUDE_CONFIG_DIR = job.home` for Claude, `CODEX_HOME = job.home` for Codex; a null or empty home **removes** the variable; for Claude only, [$script:ChatqRunEnv](src/queue.ps1) entries (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, `BASH_MAX_TIMEOUT_MS=3600000`, `BASH_DEFAULT_TIMEOUT_MS=1800000`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=3600000`) only where absent, and `MCP_TOOL_TIMEOUT` when a permission bridge runs, so a Codex run gets `CODEX_HOME` alone; [$script:ChatqEnvDrop](src/queue.ps1) names removed. [runenv::run_delta](native/crates/chatq-core/src/runenv.rs) reproduces [Invoke-ChatqRun](src/queue.ps1)'s delta, which is what `pre-run` hands over, and `env.json` pins it. chatqd applies the delta to its own environment, which equals the PS watcher's because both inherit the launcher's |
| `CHATQ_OVERLAY`, `CLAUDECODE` | Not set by chatqd. The loader's auto-start already skips under `CHATQ_WATCHER` |
| New: `CHATQ_ENGINE` | `ps` \| `native`, overriding config for one launch and its descendants (§4.2) |
| New: `CHATQ_CHATQD` | Full path to a chatqd binary, overriding the `bin/` lookup (developers, tests) |
| New: `CHATQ_NATIVE_SEAMS` | Path of a test seams file (§6.5). Every seam chatqd honours is logged to `chatqd.log` at start. The path is handed to every step and to a PS watcher chatqd starts |

### 2.6 Process launch (a run's CLI, from M5)

- **Argument line.** The plan carries the command line string [ConvertTo-ChatqArgLine](src/queue.ps1) built in `pre-run`, after [Get-ChatqCmdArgRefusal](src/queue.ps1) and the cmd title scrub. These are two rules of [src/queue.ps1](src/queue.ps1) with two sets: the title scrub turns each of `"%!&|<>^` into a space, collapses runs of white space and trims the ends; the `.cmd` quoting set is white space and `"&|<>^()`. chatqd passes the line unchanged. `argline.rs` is still ported, because chatqd builds its own command lines for steps and for the PS watcher (§2.7, §3.6). The vector file holds both functions' outputs for an adversarial corpus.
- **Windows spawn.** Call `CreateProcessW(NULL, "\"<exe>\" <argline>", …, bInheritHandles=TRUE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT, env, cwd)` directly through `windows-rs`. This is exactly what .NET does with `UseShellExecute=false` and `CreateNoWindow=true` ([New-ChatqProcessStartInfo](src/queue.ps1)).
  - **Not** `std::process::Command`: since Rust 1.77 its batch-file handling for CVE-2024-24576 escapes and refuses differently from .NET. The command line must be the PS-built string, byte for byte.
  - `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` names exactly the child's three pipe ends, so no other inheritable handle can leak.
  - The environment block is sorted the way .NET sorts it, which depends on the edition: by UTF-16 unit with the OS's case table on 5.1, by code point with .NET's own table on pwsh 7. So [runenv::block](native/crates/chatq-core/src/runenv.rs), [runenv::cmp_names](native/crates/chatq-core/src/runenv.rs) and [runenv::same_name](native/crates/chatq-core/src/runenv.rs) take a flavour. Vector `env.json` holds the block order. These are Windows rules; macOS keys and orders the block otherwise (DEFERRED.md "A run's environment off Windows").
- **Unix spawn.** `std::process::Command` with explicit args, from the plan's argv list; there are no `.cmd` targets.
- **stdin.** The plan's stdin file (the prompt as UTF-8 without BOM, written by `pre-run`) is written to the child's stdin and then closed. A writer thread does this, so a prompt larger than the pipe buffer cannot deadlock. Write errors are ignored, as [Invoke-ChatqProcess](src/queue.ps1) ignores them. The file is deleted once written.
- **stdout.**
  - It is decoded as UTF-8 with replacement, and a leading BOM is handled as .NET's `StreamReader` handles it (`detectEncodingFromByteOrderMarks`). chatqd waits for 4 bytes before it detects; .NET detects on its first read, which differs only when that read is shorter.
  - It is split as `StreamReader.ReadLine` splits: `\n`, `\r\n` **and a lone `\r`**. A last line without a terminator still counts.
  - Each line is written to the `.jsonl` log (§2.3) **before** it is parsed. A line over 1,048,576 UTF-16 code units (counted after decoding, as `$Line.Length` counts) is logged and not parsed.
  - The vector `jsonl.json` holds raw bytes (CRLF, lone CR, invalid UTF-8, BOM, a 1 MB+ line) and the log bytes and line list PS produced, per PS flavour.
- **stderr.** Read to the end concurrently, as `ReadToEndAsync` does, with no cap in content. chatqd spools it to `D/native/run-<jobId>.err` instead of memory, so a flood cannot grow chatqd. `post-run` reads it with the same decoding. If the drain has not finished 5 s after the exit wait, StdErr is `''`, as today.
- **Ticks and limits** (as [Invoke-ChatqProcess](src/queue.ps1)'s `$check`):
  - The tick runs when no line has come for 5 s, and after a line once 5 s have passed since the last tick, so a chattering stream cannot hide it.
  - Each check runs the tick first (a true result stops with `cancelled`), then the deadline (`timeout`).
  - Run deadline: the plan's timeout (default 14400 s). The probe deadline (180 s) lives in the `probe` step.
  - On a stop: the tree kill, then the exit wait.
  - After stdout ends or a stop: `WaitForExit(15000)`; ExitCode is the process's, or `-1` if it has not exited.
  - Result: `{ExitCode, StdErr, Stopped, Pid}`, with `Stopped` ∈ `null`, `cancelled`, `timeout`, exactly the strings PS uses.
- **Tree kill** ([Stop-ChatqTree](src/queue.ps1)):
  - Windows: `taskkill.exe /PID <pid> /T /F`. PS runs it by bare name through PATH; chatqd runs `%SystemRoot%\System32\taskkill.exe` by absolute path, a deliberate hardening (§8).
  - Unix: the same set as .NET's `Kill(true)` then `Kill()`: the pid and every descendant found at the time of the call, sent SIGKILL. Descendants come from `proc_listchildpids` on macOS.

### 2.7 The launch command chatqd must reproduce

When chatqd starts the **PowerShell** watcher (a handoff, a respawn the decision gives to PS, or a fallback), it builds exactly what [Get-ChatqWatcherLaunch](src/watcher.ps1) builds:

```
<psExe> -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <base64(UTF-16LE(cmd))>
cmd = $env:CHATQ_WATCHER='1'; [$env:CHATQ_CLAUDE='..'; $env:CHATQ_CODEX='..';] try { . '<script>' } catch { try { [void][IO.Directory]::CreateDirectory('<logdir>'); [IO.File]::AppendAllText('<log>', (Get-Date).ToString('o') + '  the watcher did not load: ' + $_.Exception.Message + [char]10) } catch {}; exit 1 }; Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue; Invoke-ChatqWatchLoop
```

- Single quotes inside the embedded strings are escaped as `CodeGeneration.EscapeSingleQuotedStringContent` does: each of `'` and the curly quotes U+2018, U+2019, U+201A and U+201B is doubled, since PowerShell's parser takes all five as a single quote. `CHATQ_CLAUDE`/`CHATQ_CODEX` are embedded when set in chatqd's environment, which is the launcher's.
- `<log>` is `Join-Path`'s result, so on Windows each `/` in it is a backslash; `<logdir>`, passed to `CreateDirectory`, is the raw `$script:ChatqLogDir` ([launch::ps_watcher_command](native/crates/chatq-core/src/launch.rs), [launch::join_path](native/crates/chatq-core/src/launch.rs)).
- `<psExe>` is `--ps`, the launcher's `(Get-Process -Id $PID).Path`. `<script>` is `--script`, the launcher's `$script:ChatqScriptPath` (the loader's `$script:ChatScriptPath`).
- cwd: `$HOME`. PS applies `[WildcardPattern]::Escape` only for `Start-Process`'s parameter; the real directory is `$HOME`.
- Windows: a new console, hidden (`CREATE_NEW_CONSOLE` with `STARTF_USESHOWWINDOW`, `SW_HIDE`), not `CREATE_NO_WINDOW`. That matches `Start-Process -WindowStyle Hidden` for a console host.
- macOS: `nohup <psExe> …` with stdout to **`D/logs/watcher.out`** and stderr to **`D/logs/watcher.err`** (`$script:ChatqLogDir`), as [Start-ChatqWatcherProcess](src/watcher.ps1) does.
- When `CHATQ_NATIVE_SEAMS` is set, the same seams reach the PS watcher (§6.5).

The vector `watcher-launch.json` compares chatqd's encoded command with `Get-ChatqWatcherLaunch`'s for the same inputs.

### 2.8 Crypto and secrets (wire format in [src/phone.ps1](src/phone.ps1) and [src/phone-down.ps1](src/phone-down.ps1), page in [docs/reply.html](docs/reply.html))

chatqd only **verifies** MACs (inbound triage) and derives the confirmation code. It never decrypts, seals, inflates or signs. Those stay in steps.

**Key derivation** ([Get-ChatqReplyKeys](src/phone.ps1), [Get-ChatqLabelKeys](src/phone-down.ps1)), with the phone's key `D` (32 bytes):

```
k    = HMAC-SHA256(D, UTF8(label + id))
enc  = HMAC-SHA256(k, "enc");  mac = HMAC-SHA256(k, "mac")
msg  = prefix "." id "." b64url(iv) "." b64url(AES-256-CBC-PKCS7(enc, iv, data)) "." b64url(HMAC-SHA256(mac, UTF8(first four parts joined by ".")))
code(D) = BE-u32(HMAC-SHA256(D, "chatq-confirm")[0..4]) mod 1_000_000, shown "123 456"
```

**Labels and prefixes**, as [Open-ChatqSealed](src/phone-down.ps1)'s callers use them:

| Prefix | Label | Direction | chatqd |
|---|---|---|---|
| `chatq1` | `chatq-alert:` + aid | phone → PC, a reply to an alert ([Unprotect-ChatqReplyMessage](src/phone.ps1)); payload `v` 1 or 2 | MAC triage |
| `chatq3c` | `chatq-phone:` + cid | phone → PC, compose and board ([Unprotect-ChatqComposeMessage](src/phone-down.ps1)); payload `v` must be 3 | MAC triage |
| `chatq3d` | `chatq-down:` + did | PC → phone, deflated | never parsed |
| (down topic) | `chatq-down-topic` | PC → phone topic name | never parsed |
| `chatq2p` | none (RSA-OAEP-SHA256) | phone → PC, a pairing answer: 3 parts | pre-RSA checks only |

Any other label in that table belongs to a down path and is not read by the inbound poll. The vector `wire.json` holds PS-sealed and page-sealed messages for every inbound label, so the derivation is tested, not retyped.

**Triage order**, mirroring [Test-ChatqReplyMessage](src/phone.ps1) exactly, including its stage names and error texts:

1. `TrimStart` then ordinal `StartsWith('chatq3c.')` → sealed check with prefix `chatq3c`, `NotText` `not a chatq message from the phone`.
2. `StartsWith('chatq2p.')`:
   - if `Rc.PairId` is set and the pairing key cannot be opened ([Get-ChatqPairKey](src/phone.ps1): config `reply.pairing.id` equal, ordinal, and `pairing.key` opened by DPAPI) → junk, stage `pairing`, `the pairing key cannot be read here`;
   - else the pre-RSA checks of [Unprotect-ChatqPairMessage](src/phone.ps1): 3 parts after `Trim`, prefix `chatq2p`, id `^[a-z2-7]{10}$` (`not a pairing message`); `PairId` set and equal (`for no pairing in progress`; PS's `-cne` there is linguistic, and chatqd's exact compare is the same answer while both are ten characters of `[a-z2-7]`, which only a hand-edited `config.json` could break); b64url ciphertext of 64–1024 bytes (`bad encoding`). Any failure → junk, stage `pairing`, that text;
   - passing all → **candidate**.
3. Otherwise sealed check with prefix `chatq1`, `NotText` `not a chatq reply`.

**The sealed check** ([Open-ChatqSealed](src/phone-down.ps1)):

- `Trim`, split on `.`: 5 parts, prefix equal, id `^[a-z2-7]{10}$` (else `NotText`, stage `format`). The prefix test is PS's `-cne`, which is linguistic and differs by edition; chatqd reproduces it with tables scanned from each edition, in [wire/collation.rs](native/crates/chatq-core/src/wire/collation.rs) (DEFERRED.md "Unicode tables scanned on one PC"). The dispatch's `StartsWith` (triage steps 1-3) is ordinal;
- iv 16 bytes, ct non-empty and a multiple of 16, MAC 32 bytes (else `bad encoding`);
- master present and 32 bytes (else `no phone paired`);
- stage `mac`; MAC compared in constant time (`subtle`) (else `the MAC does not match`).
- A message that passes is a **candidate**. Stage `decrypt` and beyond happen only in the `reply` step, and PS does not count them as junk either.
- In the id pattern here and in the ntfy id's `^[A-Za-z0-9]{1,40}$` (§1.3), .NET's `$` also matches before one final LF; [wire.rs](native/crates/chatq-core/src/wire.rs) does the same.

**b64url** ([ConvertFrom-ChatqB64Url](src/phone.ps1)):

- charset `^[A-Za-z0-9_-]*$`, no padding;
- `len % 4 == 1` → reject;
- padded, then decoded with .NET `FromBase64String`, which **accepts non-zero trailing bits**. chatqd uses `base64` 0.22 with `decode_allow_trailing_bits(true)` and an indifferent padding mode. A vector pins this, so `…Q`/`…R` endings decode alike.

**Encode** ([ConvertTo-ChatqB64Url](src/phone.ps1)): the standard alphabet mapped `+`→`-`, `/`→`_`, then `=` trimmed. Used only by vectors.

**DPAPI** ([Protect-ChatqSecret](src/alerts.ps1) / [Unprotect-ChatqSecret](src/alerts.ps1)):

- a protected value is `{value: <hex>, protected: true}`;
- the hex is `ConvertFrom-SecureString`'s output: the DPAPI blob in hex, CurrentUser scope, no entropy, UTF-16LE plaintext;
- chatqd calls `CryptUnprotectData` and decodes UTF-16LE ([secret::unprotect](native/crates/chatq-core/src/secret.rs));
- a failure means null, never a crash;
- off Windows the value is plain text with `protected: false`. A `protected: true` value there is read as pwsh's Unix SecureString helper reads it: the hex's bytes are the UTF-16LE text;
- chatqd never writes secrets in M0–M7, and never holds a decoded key longer than one triage pass. The decoded text is a `Zeroizing<String>` with its capacity reserved up front, so no reallocation leaves a copy behind, and `CryptUnprotectData`'s buffer is wiped before `LocalFree`. The hex (the ciphertext) and the caller's JSON value are not zeroed.
- `chatqd vector dpapi` (§6.1) prints any of this user's DPAPI secrets from the shipped exe. It crosses no boundary: any process of the user can call `CryptUnprotectData`.

**Random.** Not needed: chatqd seals nothing.

### 2.9 Classifiers (each valid in Rust's `regex`: no lookaround, no backreference)

Only two patterns run natively: inside the stream-state parse, on Claude's `<synthetic>` assistant turns ([Update-ChatqClaudeState](src/queue.ps1)). Outcome classification ([Get-ChatqClaudeOutcome](src/queue.ps1), [Get-ChatqCodexOutcome](src/queue.ps1)) and limit-time parsing ([ConvertFrom-ChatqLimitText](src/queue.ps1), [ConvertTo-ChatqResetDate](src/queue.ps1)) run in `post-run`, `probe` and `block` steps, for good. So .NET's `DateTime.TryParse` leniency is never re-implemented (§8 risk 3).

| Name ([src/queue.ps1](src/queue.ps1)) | Pattern | Native use |
|---|---|---|
| `$script:ChatqLimitRx` | `(?i)hit your (session \|usage \|weekly \|opus \|sonnet )?limit\|usage limit reached\|limit (will )?reset` | `SyntheticLimit` |
| `$script:ChatqOverloadRx` | `(?i)API Error:\s*5\d\d\|\boverloaded(_error)?\b` | `Overloaded` |
| `$script:ChatqCodexOverloadRx` | `(?i)at capacity\|high demand\|Flex capacity unavailable\|(unexpected status\|last status:?)\s*5\d\d\|\boverloaded\b\|server_error` | none (step) |
| `$script:ChatqNetworkRx` | `(?i)ECONNRESET\|ETIMEDOUT\|ECONNREFUSED\|ENOTFOUND\|EAI_AGAIN\|socket hang up\|Connection error\|fetch failed\|network error\|stream disconnected\|error sending request\|Premature close\|connection reset` | none (step) |
| `$script:ChatqAuthRx` | `(?i)OAuth token (has )?expired\|invalid (api key\|x-api-key\|bearer token)\|authentication_error\|not logged in\|please (run )?/login\|401 Unauthorized\|403 Forbidden` | none (step) |
| `$script:ChatqCodexLimitRx` | `"rate_limits"\s*:\s*\{` | none (step) |

**Rule.** Patterns are not retyped. `native/crates/chatq-core/tests/rx_sync.rs` parses `src/queue.ps1` for the two native assignments and asserts equality with the compiled-in strings ([stream::LIMIT_RX](native/crates/chatq-core/src/stream.rs), [stream::OVERLOAD_RX](native/crates/chatq-core/src/stream.rs)). It expects each pattern assigned exactly once, as a single-quoted string on its own line. A PS edit without the Rust edit fails CI.

**.NET vs Rust regex differences.** The two engines' classes are not the same: .NET's `\b` counts each UTF-16 unit on its own and its `(?i)` takes `İ` for `i` and the Kelvin sign for `k`. So chatqd matches against an ASCII stand-in of the text (`stream::stand_in`): each character replaced by one with the classes .NET gives it (white space, a decimal digit, a word character, or neither). Neither pattern has `.`, a backreference or a lookaround, so whether one matches depends on nothing else. PowerShell `-match` is case-insensitive by default, and both patterns carry `(?i)` already. The `stream-state.json` corpus guards it.

**Pre-filter.** [Update-ChatqClaudeState](src/queue.ps1) parses a line only if it starts with `{"type":"assistant"` or `{"type":"system"`, or contains `"type":"result"` or `"type":"rate_limit_event"`. Its `StartsWith` is culture-aware under en-US, not ordinal: a soft hyphen in the line does not count, and a NUL does not count on pwsh 7 (`stream::starts_with`). chatqd uses the same test, so the same lines reach the parser.

**The two editions are not at parity.** A line is read by the shared grammar of §2.2 (`stream::parse`, with pwsh 7's unwrap of a top-level list of none or one), so the editions accept different lines and build different numbers from the same one: 5.1 reads `1.50` as a decimal that keeps its scale, `010` as ten and `+5` at all; pwsh 7 reads `010` as octal, and `0x10`, comments and trailing commas. `ToolIds` keys collide differently too: 5.1's `@{}` folds by the culture (approximated, `stream::culture_fold_eq`, with soft hyphen and NUL not counting), pwsh 7's by `OrdinalIgnoreCase` (`json::fold_eq`). So a run's St is per edition, and chatqd runs the flavour of the PowerShell it stands in for. A lone surrogate escape reads as U+FFFD in both, so St never holds one. Not ported, and kept out of the vector: 5.1's `"\/Date(...)\/"` and pwsh 7's ISO strings, which become DateTime there and stay strings here (one out of range throws in both); culture-ignorable characters other than soft hyphen and NUL (DEFERRED.md "PowerShell's culture compares, approximated").

### 2.10 Timing constants (all ported as named constants with the PS symbol in a doc comment)

- Wait step 2 s, at most 30 s per wait, capped at `pollEvery` while listening ([Wait-ChatqUntil](src/watcher.ps1)).
- Lock acquire: 5 tries, 200 ms apart.
- Auto scan: **at start**, then every 5 min. Stray sweep: **at start**, then every 6 h. Both timers start at `MinValue`.
- Block rescan 10 min per lane ([Update-ChatqBlock](src/watcher.ps1)).
- Probe reuse 3 min per `lane|model` ([Confirm-ChatqAllowed](src/watcher.ps1)).
- Outage backoff 1, 2, 5, 10, 15 min; status page every 60 s; 15 min cap; Codex uses backoff only; reminder after 6 h ([Enter-ChatqOutage](src/watcher.ps1), [Test-ChatqOutageOver](src/watcher.ps1), [Send-ChatqOutageReminder](src/watcher.ps1)).
- Probe-fail backoff `5·min(n,6)` min, alert on the 3rd.
- Login block 15 min.
- Limit with no time: 15 min.
- Due time = limit + 60 s.
- Default wait 15 min.
- Keep-awake only for waits ≤ 6 h. As the loop stands, a wait is never longer than 15 min, so the test is always true; it only guards a longer wait to come.
- Board/state at least every 30 s while listening. A pass that picked a job writes the state and the board and does not wait at all, and it does not restart the 30 s board timer (`timers.json`).
- Reply poll: 6 s hot, 15 s open, 20 s otherwise ([Get-ChatqReplyPollSeconds](src/phone-down.ps1)). With the reply window shut, the watch loop sets 15 s ([timers::CLOSED_POLL_SECONDS](native/crates/chatq-core/src/timers.rs)), but nothing reads it: the poll and the wake-up cap both run only with the window open. In a run 30 s, 10 s hot, 5 s while a permission is open. Request timeout 8 s, or 5 s in a run. `MaxMessages` 10, or 2 in a run.
- Reply log throttles: `poll failed:` 10 min, bad id 10 min, junk per stage 5 min, `lastPolledAt` save 5 min.
- Act ages (`$script:ChatqReplyActAge`): status/ping/read 600 s, default 1800 s, and `min(hours·3600+600, act age)`. Compose looks 600 s, changes 1800 s. 20 uses per alert. Refusal push once per 10 min per aid. Compose refusal ack once a minute. `hotUntil` +2 min.
- Ask landed: 20 s after the relay ([Test-ChatqAskLanded](src/ask.ps1)).
- Permission: a request without a matching stream `tool_use` waits up to 10 s; 20 pushes per hour; deadline at most `permit.waitMinutes` + 30 s ([Update-ChatqPermitRequests](src/permit.ps1)).
- In-run heartbeat state save every 60 s.
- Process: tick 5 s; exit wait 15 s; stderr wait 5 s; default run timeout 14400 s.
- `now` freshness 5 min.
- `maxRetries` default 5 ([Get-ChatqMaxRetries](src/watcher.ps1)); network retries 1, 2, 5 min, at most 3.
- [Start-ChatqWatcher](src/watcher.ps1)'s 1.5 s re-look and 40 × 250 ms wait, and [Request-ChatqWatcher](src/commands.ps1)'s 10 s window, stay on the PS side, unchanged.

### 2.11 Culture (new)

PowerShell renders some log and board text in `Get-Culture`, so chatqd must too:

- `ToString('HH:mm')` and `ToString('HH:mm:ss')` use the culture's **time separator**. This covers [Enter-ChatqOutage](src/watcher.ps1)'s `next check HH:mm:ss`, [Confirm-ChatqAllowed](src/watcher.ps1)'s `still limited until HH:mm`, the network-retry and limited lines and history texts in [Invoke-ChatqJob](src/watcher.ps1), [Get-ChatqReplyListenText](src/phone-down.ps1), the board's `updated HH:mm:ss` and status-line `since HH:mm`, and [Write-ChatqReplyJunk](src/phone.ps1)'s `since HH:mm`.
- `'{0:N0}'` in [Write-ChatqBoard](src/alerts.ps1) uses the culture's **group separator and group sizes** (hi-IN groups 3 then 2).
- Lane and provider **display names** use the culture's `ToTitleCase` (§2.4's **Lane**): the board, the overloaded and failed alerts, the usage texts of [phone-extras.ps1](src/phone-extras.ps1) and [commands.ps1](src/commands.ps1)'s overload note. [phone-extras.ps1](src/phone-extras.ps1) lowers a provider with the culture's `ToLower` first.
- [Format-ChatqClockTime](src/phone-extras.ps1), [Format-ChatOverlayWhen](src/overlay-data.ps1) and `ddd` are InvariantCulture and need nothing.
- .NET formats digits as ASCII in every culture.

**Contract.** The launcher passes `--culture <b64url(JSON)>` with `{name, timeSep, groupSep, groupSizes}` read from `[Globalization.CultureInfo]::CurrentCulture`. chatqd uses it for its whole life and passes it unchanged to its native respawns. That is what the PS watcher does too: it reads its culture once, and .NET caches it per process. The vector `culture.json` holds en-US, ko-KR, de-DE, fi-FI, hi-IN, tr-TR and nl-NL renderings from PS of every string above, each culture's own `--culture` argument included: the Rust runner learns each culture from that argument alone.

---

## 3. Architecture

### 3.1 Workspace layout

```
native/
  Cargo.toml              workspace; [workspace.package] version = ChatVersion
  Cargo.lock              committed
  rust-toolchain.toml     channel = "1.99.0"; components rustfmt, clippy; profile minimal; NO targets
                          list (CI runs `rustup target add` for the Apple targets, so a local
                          build never downloads anything it does not need)
  .cargo/config.toml      [target.x86_64-pc-windows-msvc] rustflags = ["-C","target-feature=+crt-static"]
  deny.toml               cargo-deny (3.4): advisories, licences, bans, sources
  vectors/                the contract vectors (6.1)
  crates/
    chatq-core/           lib: every contract in section 2, no I/O policy
      src/lib.rs          #![deny(unsafe_code)], the module list
      src/paths.rs        R and D, every file name in 2.4 and 4.5 as a const with its PS symbol, the
                          step files and src/native-step.ps1 (3.6)
      src/fsx.rs          atomic save/update (Update-ChatqText), read-with-retry, Open-ChatqLock,
                          watcher lock
      src/json.rs         the one JSON grammar per edition, the file read, [string], lookups (2.2)
      src/utf8.rs         UTF-8 decoding with replacement, as each .NET decodes (2.2, 2.6)
      src/jsonl.rs        a run's stdout: StreamReader's line split, the .jsonl log bytes (2.3, 2.6)
      src/time.rs         stamps (hand-made 7-digit formatter), the one date reader (ConvertTo-ChatqDate
                          and the JSON dates of 2.2), zones
      src/culture.rs      the --culture block, HH:mm with the separator, N0 grouping
      src/log.rs          Add-ChatqLogLine, alerts.log line, Write-ChatqReplyLog
      src/jobs.rs         Get-ChatqJobs read+sort, the -Now deferUntil write, the pick-failure write
                          (2.4)
      src/state.rs        Save/Restore-ChatqWatchState, W's fields and caches, the w codec and
                          handoff.json (3.6, 4.4)
      src/config.rs       read config.json (no lock, never written)
      src/gates.rs        Get-ChatqDueTime, Update-ChatqBlock's 10 min rule, Test-ChatqHeldWaiting,
                          the Send-ChatqUsageSoon gate, Test-ChatqAutoWanted, the alert route (1.4),
                          the held and soon pre-gates (3.6)
      src/timers.rs       the loop's timers (2.10) as a pure schedule over a pass's clock
      src/idle.rs         Get-ChatqIdleSeconds's reading of ioreg (macOS)
      src/stream.rs       Update-ChatqClaudeState / Update-ChatqCodexState, the two regexes (2.9)
      src/wire.rs         triage and MAC check (2.8), code(D), the junk-only poll batch (3.7)
      src/wire/collation.rs  what the sealed check's -cne lets by, per edition (2.8)
      src/replystate.rs   Use-/Save-ChatqReplyState (fixed key set, prune rules)
      src/board.rs        Write-ChatqBoard and its helpers (M2, not-listening path)
      src/secret.rs       DPAPI (cfg windows), plain (cfg unix)
      src/argline.rs      ConvertTo-ChatqArgLine, Get-ChatqCmdArgRefusal
      src/runenv.rs       a run's environment: the drop list, the run-env defaults, the plan delta,
                          the block's order (2.5, 2.6)
      src/launch.rs       engine decision and fuse (4.2), PS watcher command (2.7), loader version read
      tests/              one *_vectors.rs runner per vector file (6.1), rx_sync.rs, common/
    chatqd/               bin: the multicall exe
      build.rs            asserts version == loader's ChatVersion; refuses an MSVC release build
                          without +crt-static
      src/main.rs         argv dispatch: watch | version | vector (6.1's live checks) | (M8) ask-hook | permit
      src/vector.rs       vector dpapi <hex> | vector local-stamps (6.1)
      src/seams.rs        CHATQ_NATIVE_SEAMS (6.5)
      src/watch/mod.rs    `chatqd watch`: its arguments, start-up and exit around the loop, the state save
      src/watch/loop.rs   Invoke-ChatqWatchLoop (M2): its control flow and gates, through a Host trait
      src/watch/step.rs   PowerShell helper steps: In, the launch, the wait, Out (3.6)
      src/watch/timers_replay.rs  test only: timers.json through loop.rs on a fake Host, and the
                          loop's failure paths and soon pre-gate on the same Host
      src/watch/wait.rs   Wait-ChatqUntil, flag files
      src/watch/awake.rs  Set-ChatqKeepAwake
      src/watch/spawn.rs  the watcher started after a handoff or a respawn (4.2, 4.4)
      src/sys/mod.rs      every OS call chatqd makes, and so every unsafe block
      src/sys/win.rs      CreateProcessW, SetThreadExecutionState, the process probes, PeekMessageW,
                          a step's spawn-and-wait, own start time (GetProcessTimes)
      src/sys/mac.rs      caffeinate, nohup, kill(pid, 0), proc_pidinfo; Windows can lint it, only
                          native-macos CI builds and runs it
      tests/watch.rs      the built chatqd against throwaway roots, every launch through the spawn seam,
                          every step against a stub native-step.ps1 under a real PowerShell
```

Planned for later milestones, not yet in the tree:

```
    chatqd/src/watch/reply.rs  poll, triage, junk path (3.7, M3)
    chatqd/src/watch/lane.rs   Confirm-ChatqAllowed's state machine, outage, status page (M4)
    chatqd/src/watch/run.rs    the run plan, Invoke-ChatqProcess, the mid-run tick (3.8, M5)
    chatqd/src/watch/alert.rs  Send-ChatqAlert's unregistered path (M6)
    chatqd/src/http.rs         ureq Agent per burst, timeouts, proxy resolution, seams (M3)
    chatqd/src/ipc/            pipe / socket server (M8)
    sys/win.rs, sys/mac.rs     taskkill and the child tree, GetLastInputInfo and ioreg idle, toast
                               (WinRT) and osascript, proxy (WinHTTP, system-configuration)
    chatqd/build.rs            Windows version resource and manifest (4.8)
    crates/fake-cli/           test-only bin (publish = false): plays claude/codex stream fixtures (M5)
```

There is no `stage.ps1`: a build is copied into `R/bin/<ChatVersion>/<target>/` by hand, or named by `CHATQ_CHATQD` (DEFERRED.md "A script that stages a chatqd build").

Edition 2024. `#![deny(unsafe_code)]` in `chatq-core`, with `#[allow(unsafe_code)]` only on `secret.rs` (DPAPI) and on one `fsx::win` submodule holding the `ReplaceFileW` call. `forbid` cannot be used: it refuses every inner `allow`, and `fsx.rs` needs `ReplaceFileW` (§2.1). On Unix, std's `File::try_lock` is `flock(LOCK_EX|LOCK_NB)` and needs no unsafe code; on Windows, `OpenOptionsExt::share_mode(0)` is safe too. `#![deny(unsafe_op_in_unsafe_fn)]` in `chatqd`, with all `unsafe` confined to `sys/`.

Two cargo files are found from the **current directory**, not from `--manifest-path`:

- `rust-toolchain.toml`: a cargo run from the repo root ignores it and uses the installed `stable`. Started inside `native/`, rustup looks for a toolchain named `1.99.0`, which is not the installed `stable` even at the same version, and downloads it if it has none by that name.
- `.cargo/config.toml`: a build from the root misses `+crt-static`. `chatqd/build.rs` refuses an MSVC release build without it, so the wrong exe cannot be copied into `bin/` by accident; debug builds (`test`, `clippy`) may link either way.

So the two places build differently, and each is right for its own case:

- **CI** runs every step inside `native/`, after `rustup toolchain install`, so it builds with the pinned 1.99.0 and `+crt-static` (§6.4).
- **On this PC** cargo runs from the repo root on the installed `stable`, with no download. A release build there names the manifest and the config by path: `cargo build --release --manifest-path native/Cargo.toml --config native/.cargo/config.toml` (TESTING.md S55).

### 3.2 Threads, not tokio

The work is one child process at a time, one HTTP request at a time and a 2 s poll. No concurrency is worth a runtime.

- **Main thread.** The loop. It owns `watcher.lock` and **calls `SetThreadExecutionState`**. That flag is per thread and is dropped when the calling thread exits, so it must be the long-lived thread.
- **During a run (M5).** Three short-lived threads, each with an explicit 64 KiB stack (`std::thread::Builder::stack_size`):
  - stdout reader: decode, split, write the `.jsonl` line, then `mpsc::Sender<Line>`;
  - stderr spool to file;
  - stdin writer.

  The main thread does `recv_timeout`, parses lines and runs the tick (§2.6). While the main thread waits on a step, the reader keeps logging and queues lines. They exit with the child.
- **During a helper step.** The main thread waits on the child with a 2 s `WaitForSingleObject`/`waitpid(WNOHANG)` loop, checking `stop` meanwhile only to log it; the step itself reacts to `stop` as PS would. Steps talk through files.
- **A deep JSON read.** A JSON text nested past 32 levels is read on a scoped thread with an 8 MB stack, joined before the read returns (§2.2, [json::on_deep_stack](native/crates/chatq-core/src/json.rs)). A shallower read stays on the caller's thread.
- **HTTP.** Blocking `ureq` on the main thread, with per-request timeouts as each PS call site sets them (§2.10).
- **Toast (M6).** A short-lived worker thread that initialises COM (MTA), shows the toast and uninitialises. No COM state stays on the main thread.
- **M8 IPC.** One accept thread (64 KiB stack) and one thread per connected stub (at most 5 ask hooks + 1 permit bridge, the same cap as [Start-ChatqAskHook](src/ask.ps1)), passing events to the main loop through `mpsc`.

**Why not tokio.**

- The multi-thread runtime starts one worker per core, each with a 2 MiB reserve, and its scheduler allocates up front.
- `current_thread` would be small, but every FFI call here blocks: DPAPI, WinRT, `ReplaceFileW`, `LockFile`, `CreateProcessW`. Each would need `spawn_blocking` and that pool's threads.
- Async gives this program nothing but colour.

### 3.3 Memory target and how it is met

**Target, re-based.** The first draft asserted 6 MB with TLS. That rested on an unmeasured claim that SChannel's cost sits in shared pages, which was withdrawn. Targets are now per state and are recorded as measured.

| State | Windows private bytes (`PrivateMemorySize64`) | macOS `footprint` |
|---|---|---|
| M0 waiting, no TLS ever used | ≤ 4 MB | ≤ 8 MB |
| M3 listening, 60 s after the 10th poll | **≤ 8 MB**, stretch 6 MB | ≤ 12 MB |
| M6 after a toast | ≤ 8 MB | ≤ 12 MB |
| During a run, chatqd alone | ≤ 16 MB plus queued lines | ≤ 20 MB |

Today's figure, measured over a day on this PC (2026-10-19/20): a running PowerShell watcher is 150 to 225 MB private from its first minute, 174.5 on average while it runs (179 MB working set), 158.5 on 0.10.17 and 0.10.18. §0's 104 MB is the loader's own measurement, not a running watcher's. A watcher that lives under about 40 minutes is never trimmed, so its working set sits some 20 MB above private; one that lives a day is trimmed to about 55. With `reply.hours` 0.5 it ran 58% of the day: 103 MB private averaged over it. The M0 row holds: chatqd waiting under the `hold` seam measured 1.1 to 1.8 MB private, 5.2 to 7.1 working set, in 8 test samples. The M3 row holds: the release chatqd listening on ntfy.sh for an hour (2026-10-22, TESTING.md S59) held 2.58 MB private 60 s after its 10th poll, under the 6 MB stretch, 2.77 on average over 60 minute samples and 3.49 at most, the highs single-minute spikes over a baseline of 2.6 to 2.8. Each milestone's Tier 1 check records the real numbers in TESTING.md, and a miss is a finding, not a silent re-target.

**How it is met.**

- No GC'd runtime, no WebView, no async runtime, system allocator (no mimalloc/jemalloc arenas).
- `+crt-static` on MSVC: no `vcruntime140.dll` to load or ship.
- Release profile: `opt-level = "s"`, `lto = "fat"`, `codegen-units = 1`, `strip = "symbols"`, `panic = "unwind"`. Unwind is kept so a panic can run the panic hook and the handoff (§4.1). Expected exe size 2–4 MB once TLS and WinRT land; the M0 exe measured 0.6 MB.
- Two regexes only, compiled lazily (`LazyLock`) on the first Claude run.
- Files are read, parsed, dropped. Nothing caches a transcript; transcript scans are steps.
- HTTP: **a fresh `ureq::Agent` per poll burst, dropped after it**, so the connection, the TLS session and their buffers are freed between polls. A handshake every 15–20 s is cheap next to holding them. SChannel's process-wide credential cache is released by `FreeCredentialsHandle` when the agent drops. Its residual is inside M3's measured 2.58 MB (above).
- Thread stacks are explicit and small; the main thread reserve is 1 MiB, mostly uncommitted.
- Measured in CI as a soft check (≤ 16 MB, since CI is noisy) and on this PC as the hard one (Tier 1).

### 3.4 Crates (few, maintained, versions pinned by `Cargo.lock`)

| Crate | Use | Notes |
|---|---|---|
| `serde`, `serde_json` (`preserve_order`) | JSON | indexmap comes with it |
| `chrono` (`default-features = false`, `clock`, `std`) | local offset, calendar | Chosen over `time`, whose local-offset lookup refuses on multi-threaded Unix. Formatting is hand-made (§2.2) |
| `regex` | the two stream patterns | Default features (Unicode case folding needed) |
| `ureq` 3 + `native-tls` | HTTPS to ntfy, Join, status.claude.com | OS trust store: SChannel on Windows, Security.framework on macOS. Corporate MITM roots work as they do for .NET |
| `hmac`, `sha2`, `subtle` | MAC verification, code(D) | RustCrypto. No `aes`/`cbc`: chatqd decrypts nothing |
| `base64` 0.22 | b64url | `decode_allow_trailing_bits(true)` (§2.8) |
| `windows` (pinned minor) | Win32 + WinRT | Features listed in §3.5 only |
| `libc` | `flock`, `kill`, `proc_pidinfo`, `getpeereid` | |
| `system-configuration` | macOS system proxy | Same crate reqwest uses |
| `zeroize` | key buffers | |

Not used:

- `rsa` (pairing stays in the step, §1.3), `aes`/`cbc`, `getrandom`;
- `tokio`, `reqwest`;
- `anyhow`/`thiserror` (one small error enum);
- `tempfile`: tests make their dirs under `native/target/test-data/`, never `%TEMP%`;
- `miniz_oxide`: down messages stay in steps.

`cargo deny check` runs in CI ([native/deny.toml](native/deny.toml)), over the graph of the three release targets:

- **Advisories:** the defaults, so any advisory against any crate fails the build, unmaintained ones included.
- **Licences:** MIT, Apache-2.0, BSD-3-Clause, Unicode-3.0 and Zlib (foldhash's, under hashbrown) are allowed, and nothing else. The workspace's own crates (`publish = false`) carry none and are ignored.
- **Bans:** wildcard versions are denied, except the workspace's own path dependencies.
- **Sources:** crates.io only; an unknown registry or git source is denied.

### 3.5 Platform surfaces

- **Windows (`windows` features).**
  - `Win32_Storage_FileSystem`: ReplaceFileW, share modes.
  - `Win32_System_Threading`: CreateProcessW, `InitializeProcThreadAttributeList`/`UpdateProcThreadAttribute` (handle list), wait, `GetProcessTimes` (start time for the step parent check).
  - `Win32_System_Power`: SetThreadExecutionState(`ES_CONTINUOUS|ES_SYSTEM_REQUIRED` = `0x80000001`, release with `0x80000000`).
  - `Win32_UI_Input_KeyboardAndMouse`: GetLastInputInfo, for presence.
  - `Win32_Security_Cryptography`: CryptUnprotectData.
  - `Win32_Networking_WinHttp`: WinHttpGetIEProxyConfigForCurrentUser, WinHttpGetProxyForUrl for PAC/WPAD.
  - `Win32_System_Pipes`, `Win32_Security` (M8).
  - `UI_Notifications`, `Data_Xml_Dom`, `Win32_System_Com`: toast on a worker thread.
  - `Win32_UI_WindowsAndMessaging`: one `PeekMessageW` at startup, §4.1.
  - `Win32_System_Console`: AttachConsole for `--foreground`.
- **macOS.**
  - Keep-awake: `caffeinate -i -w <chatqd pid>`, exactly as [Set-ChatqKeepAwake](src/watcher.ps1). It ends by itself when chatqd dies.
  - Idle time: **`ioreg -c IOHIDSystem`** (no `-d`), the first line containing `HIDIdleTime`, `=\s*(\d+)` divided by 1e9, exactly as [Get-ChatqIdleSeconds](src/alerts.ps1). Built as [idle::idle_seconds](native/crates/chatq-core/src/idle.rs); `idle.json` pins the parse on captured `ioreg` output.
    - The line test is `-match`, so case-blind: ASCII letters in either case, and I with a dot above (U+0130) as i. The first line that matches is the only one tried, even when it holds no number (a `HIDIdleTimeUnits` line ahead of `HIDIdleTime` gives none).
    - `\d` matches other scripts' digits in the BMP, but `[double]` reads only ASCII ones, so such a digit in the number gives none. A digit past the BMP is two surrogates to .NET, which `\d` does not take, so the number ends before it. Digits past a double's range give none on 5.1 and +infinity on pwsh 7.
  - Notifications: `osascript`, with the same quoting as [Show-ChatqToast](src/alerts.ps1).
  - Process start time: `proc_pidinfo(PROC_PIDTBSDINFO)` `pbi_start_tvsec`/`usec`, for §3.6's parent check.
  - Descendants for the tree kill: `proc_listchildpids`, walked before any kill.

### 3.6 PowerShell helper steps (the strangler seam)

A helper step is one PowerShell process that loads the loader as the watcher does (the default 23 parts, with `CHATQ_WATCHER=1` inherited from chatqd) and runs **one** op through existing functions, then exits.

**Launch.** No `-EncodedCommand`: §4.8's AV concern settles open question 8. The entry is a small shipped file, `src/native-step.ps1`:

```
<psExe> -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<R>\src\native-step.ps1" -In "<D>\native\step-<n>.in.json" -Out "<D>\native\step-<n>.out.json" -Watcher <chatqd pid> -WatcherStart <chatqd start, UTC ticks> [-Seams "<path>"]
```

- `-ExecutionPolicy Bypass` is required, because `-File` honours policy. The command line is built by `argline.rs` (MSVCRT quoting).
- **`<n>`** counts launch attempts in this chatqd's life, from 1. A launch that fails still uses up its number. chatqd's start sweeps `step-*.json`, so a number is never reused against a leftover file.
- **`-Watcher`** is chatqd's pid. **`-WatcherStart`** is chatqd's own start time as .NET UTC ticks (100 ns since 0001-01-01), as `(Get-Process -Id <pid>).StartTime.ToUniversalTime().Ticks` reads it (`sys::own_start_ticks`):
  - Windows: the creation FILETIME from `GetProcessTimes`, plus `504911232000000000`;
  - macOS: `proc_pidinfo`'s start `tv_sec`/`tv_usec`, as `621355968000000000 + tv_sec·10^7 + tv_usec·10`.
- **`-Seams`** is passed only when `CHATQ_NATIVE_SEAMS` is set, with its value.
- **No timeout.** A `pick` may run for hours. chatqd waits in 2 s slices. A `stop` file seen meanwhile is logged once (`stop seen while step <n> (<op>) runs`) and left for the loop top, as the PS watcher sees it only between jobs.
- **Environment.** Inherited from chatqd unchanged, `CHATQ_WATCHER=1` included. chatqd adds nothing and removes nothing. The script removes `env:PSExecutionPolicyPreference` itself.
- The script dot-sources the loader inside `try { } catch { exit 3 }`, removes `env:PSExecutionPolicyPreference`, applies the seams (§6.5), sets the step seams (below, "State ownership and pids"), then calls `Invoke-ChatqNativeStep -In <In> -Out <Out>`.
- **Window.** Exactly the PS watcher's environment: a new console, hidden (`CREATE_NEW_CONSOLE`, `STARTF_USESHOWWINDOW`, `SW_HIDE`), cwd `$HOME`. `CREATE_NO_WINDOW` is **not** used for steps (§8 "Review items"): code a step runs touches the console. Examples are the 5.1 `[Console]::InputEncoding` swap in [Start-ChatqProcess](src/queue.ps1) and `$Host.UI.RawUI` in [Get-ChatqWidth](src/alerts.ps1), and they must see what they see today. Runs that chatqd spawns itself use `CREATE_NO_WINDOW`, as .NET does (§2.6).
- `src/native-step.ps1` joins the payload lists of [install.ps1](install.ps1), `chatinstall` and [extension/build.js](extension/build.js). It is not a loader part.

**`Invoke-ChatqNativeStep`** is new, in [src/watcher.ps1](src/watcher.ps1). It reads `In`:

```
{ "v":1, "op":"<name>", "watcherPid":n, "startedAt":"<o>", "alertJob":"#<seq>"|null,
  "w":{ native-owned W fields, "caches":{ shared caches } }, "args":{…} }
```

- `watcherPid` equals `-Watcher`. `startedAt` equals `w.startedAt`, chatqd's start stamp.
- `In.startedAt` and every string in `args` are read under the `w` encoding's **Strings** rule (below), so a pwsh 7 step holds `ChatqWatcherStartedAt` as the text chatqd sent, not as the `[datetime]` its `ConvertFrom-Json` makes of it.
- `alertJob` becomes `$script:ChatqAlertJob` for the step's life, which [Send-ChatqAlert](src/alerts.ps1) hands on as `CHATQ_JOB`. It is `#<seq>` for `pick` and for a failed pick's `alert`, and null for every other op, as the loop sets it only around its pick.

**The exchange, in order.**

1. chatqd writes `In` atomically (`fsx` as [Save-ChatqText](src/queue.ps1) writes: UTF-8, no BOM, written aside and swapped in), then launches the step.
2. `Invoke-ChatqNativeStep` reads `In` with [Read-ChatqJson](src/queue.ps1). A missing file, `v` other than 1, an op it does not know, or (in step 3) a `w` that does not decode under the schema below gives `Out` `ok:false` with error `bad step input`, and nothing else is done: no op, and no `carry.clixml` export, so the carry is left as it was.
3. It checks the parent ("Parent death", below), then decodes `w` into a fresh [New-ChatqWatchState](src/watcher.ps1) and the `$script:` caches (`ConvertFrom-ChatqStepW`), then imports `carry.clixml` when it exists. `$W.CutCache` is `@{}` when the carry has none.
4. It runs the op inside `try`. A throw gives `ok:false` with `error` = `<Exception.Message> @ <first line of ScriptStackTrace>`, the loop's own form.
5. It exports `carry.clixml` whether the op threw or not, encodes `W` and the caches (`ConvertTo-ChatqStepW`), and writes `Out` with [Save-ChatqText](src/queue.ps1) and `ConvertTo-Json -Depth 12`:

   ```
   { "v":1, "ok":true, "error":null, "w":{…}, "result":{…} }
   { "v":1, "ok":false, "error":"<text>", "w":null, "result":null }
   ```

   An encode that throws (a field the schema cannot carry, below) becomes `ok:false` with that error. Then the step exits 0.
6. chatqd reads `Out` with [fsx::read_json](native/crates/chatq-core/src/fsx.rs) in its `--ps` flavour. It deletes `In` and `Out` after every step, whatever the outcome, a launch that failed included. A good answer has `v` 1, `ok` a bool, and with `ok:true` a `w` object holding every key of the schema below that decodes under it, and a `result` object holding every field its op's row names; with `ok:false` an `error` string.
7. On `ok:true` chatqd replaces its whole `W`, caches included, with `Out.w`, then acts on `result`. On anything else, "Failure" below applies.

**What crosses, and how.** Every `$script:` variable and `$W` key a step's code reads or writes is in exactly one class. The audit test (below) enforces this.

| Class | Members | Carrier |
|---|---|---|
| **Native-owned W** | `blocked`, `lastAllowed`, `probeFails`, `scannedAt`, `outage`, `authAlerted`, `current`, `next`, `handoff`, `listening`, `startedAt` | `w` JSON in and out; chatqd's copy is authoritative between steps |
| **Shared caches** (chatqd reads, schedules on or writes them) | `ChatqReplyHandled`, `ChatqReplySeen`, `ChatqAskSent`, `ChatqReplyJunkLog`, `ChatqReplyPolledAt`, `ChatqReplyErrAt`, `ChatqReplyBadIdAt`, `ChatqReplySavedAt`, `ChatqUsageSent`, `ChatqSummaryTriedAt` | `w.caches` in and out. Shapes in the cache table below |
| **PS-only caches** (nothing native reads them) | `CutCache` (`$W`), `ChatqBoardCutCache`, `ChatqCliVersions`, `ChatqAskAliveCache`, `ChatqBoardCache`, `ChatqPermitAsked`, `ChatqAutoCache`, and every other process-lifetime cache the audit finds | `D/native/carry.clixml`: `Import-Clixml` at step start, `Export-Clixml` at the end. Its content is PS-private: chatqd never reads it. Deleted by chatqd at its start, so its lifetime is chatqd's, as a cache's lifetime is the PS watcher's; kept at a handoff for the PS watcher (§4.4) |
| **Recomputed** | values a function rebuilds each call; `ChatqSendingSummary`, which is `$false` in every fresh step, as it is between calls in the PS watcher; `ChatqLastAlertError` | none |
| **Constant** | regexes, tables, paths | none |

The audit also **round-trips every carried variable**. The type after import must equal the type before. A `List[datetime]` that comes back an `ArrayList`, or a hashtable that comes back a `PSObject`, fails the test and must declare a converter in `Invoke-ChatqNativeStep`.

**The `w` encoding.** One schema for `In.w`, `Out.w` and `handoff.json`'s `w` (§4.4). `ConvertTo-ChatqStepW` and `ConvertFrom-ChatqStepW` in [src/watcher.ps1](src/watcher.ps1) and `state::to_w`/`from_w` in chatq-core are its two ends. `w` holds exactly the eleven native-owned keys and `caches`, nothing else; `$W.CutCache` goes to the carry, not here.

- **Every map is a list of pairs**, `[{"k":"<key>","v":<value>}, …]`, never a JSON object. Keys can be empty (the lane of a job with no `provider` is `""`, and [Update-ChatqBlock](src/watcher.ps1) stamps `scannedAt['']`), and `Answers` keys can differ only by case. 5.1's `ConvertFrom-Json` throws on either as an object name (§2.2).
  - PS emits a list for zero and one pair as well. chatqd refuses anything else as a bad answer.
  - Pair order is kept as received by both ends. It matters only in `Answers`, which is ordered.
  - Keys compare as a PS hashtable compares them, case-blind ([json::ieq](native/crates/chatq-core/src/json.rs)), except in `Answers`, which is ordinal. When chatqd sets a key, it replaces the value of the pair whose key matches, else appends a pair. When it drops a key, it removes that pair.
- **Entry objects carry `"_type"`**: `"psobject"` or `"hashtable"`. The decoder builds that type (`[pscustomobject]` or `@{}`) and the encoder writes the type it finds. chatqd keeps the tag it received. The only entries chatqd makes are the ones it restores from `state.json` at its start, and it builds those exactly as [Restore-ChatqWatchState](src/watcher.ps1) does: `blocked` as `psobject`, `outage` as `hashtable`. Field names inside an entry compare case-blind, as both a `[pscustomobject]`'s properties and a `@{}`'s keys do; each end keeps the spelling it received.
- **Present and absent.** A property present with a null value travels as null. A property absent from an entry stays absent; `blocked`'s `At` (added by `Add-Member` only where known) and `outage`'s `Reminded` and `AutoJob` are often absent.
- **Dates** (the fields the tables mark Date) travel as UTC `o` strings or null. The encoder writes `.ToUniversalTime().ToString('o')`; the decoder reads with [ConvertTo-ChatqDate](src/queue.ps1), so a Date comes back Kind Local, as every writer below stores it, and `(Get-Date) - $e.At`, `-lt` and `.ToString('HH:mm')` give what they gave.
- **int** fields are JSON integers, decoded `[int]`. **bool** fields are JSON booleans.
- **Strings.** pwsh 7's `ConvertFrom-Json` makes a `[datetime]` of a string shaped like an ISO stamp (§2.2). The decoder turns one found where the schema says string back into text: `.ToUniversalTime().ToString('o')` for Kind Utc, `.ToString('o')` otherwise. That is exact for `next` and `startedAt`, which are UTC `o`; for free text shaped like a stamp (a title, an answer) it is §2.2's accepted pwsh 7 drift.
- **A named field holding another scalar** than its type (a string in an int field, say) travels as that scalar, and the decoder keeps it as is: a type's conversion (Date, int) applies only to a value of that type's JSON form. A DateTime is a Date wherever it is found in a Date field. chatqd carries such an entry unchanged but reads it as no entry when a Date it needs is not one (`blocked`'s `Until`; `outage`'s `Since`, `LastProbe` and `NextCheck`), as it reads a null entry ([state::from_w](native/crates/chatq-core/src/state.rs)).
- **A field the tables do not name** travels as the JSON scalar it is (string, number, bool, null), unchanged. A DateTime, list or object there makes `ConvertTo-ChatqStepW` throw `bad step state: <key>.<field>`, so a new field fails the step fixtures instead of travelling half-typed.

`w`'s native-owned keys, each traced to the code that writes it:

| Key | Value | Entry | Written by (PS) | chatqd |
|---|---|---|---|---|
| `blocked` | map lane → null, or `{Until: Date, Type: string\|null, Source: string\|null, At: Date (may be absent)}` | `psobject` | [Update-ChatqBlock](src/watcher.ps1): the scan's entry as [Get-ChatqClaudeBlock](src/queue.ps1) (`Source` `transcript`), [Read-ChatqUsageCache](src/queue.ps1) (`usage cache`) and [Get-ChatqCodexBlock](src/queue.ps1) (`rollout`) build it, dropped when `lastAllowed[lane]` is set and the entry has no `At` or an earlier one, else kept when its `Until` is later than the lane's. [Confirm-ChatqAllowed](src/watcher.ps1): allowed → null; limited → `{Until, Type, Source='probe'}` plus `At`; probe failed → `{Until=now+5·min(n,6) min, Type='probe failed', Source=<probe error>}`. [Block-ChatqLogin](src/watcher.ps1): `{Until=now+15 min, Type='login needed', Source=<what the CLI said>}`. [Invoke-ChatqJob](src/watcher.ps1) on a limit: `{Until, Type, Source='run'}` plus `At`. [Restore-ChatqWatchState](src/watcher.ps1): `{Until, Type, Source}`, only for an `until` still ahead, plus `At` when `at` was saved | reads `Until`, `Type`, `At` for the due time and the soon gate; restores it from `state.json`; the `-Now` wake makes it empty |
| `outage` | map lane → null, or `{Since: Date, Attempts: int, Status: string\|null, Alerted: bool, Reminded: bool, LastProbe: Date, NextCheck: Date, AutoJob: string\|null}` | `hashtable` | [Enter-ChatqOutage](src/watcher.ps1) (made without `Reminded` and `AutoJob`, then `AutoJob` null and `Attempts` counted up); [Send-ChatqOutageReminder](src/watcher.ps1) sets `Reminded`; [Enter-ChatqAutoOutage](src/auto-continue.ps1) makes a whole entry with `AutoJob` a job id, and [Clear-ChatqAutoOutage](src/auto-continue.ps1) sets the lane's entry null; [Confirm-ChatqAllowed](src/watcher.ps1) → null when the lane is back; [Restore-ChatqWatchState](src/watcher.ps1) (`LastProbe` defaults to `Since`, `NextCheck` to now, `AutoJob` `[string]`, so `""` for none) | reads it for the due time; restores it; the wake makes it empty |
| `lastAllowed` | map key → Date or null. Keys are `<lane>` and `<lane>\|<model>` ([Get-ChatqRunModel](src/queue.ps1)) | | [Confirm-ChatqAllowed](src/watcher.ps1): both keys now when allowed (a fresh `<lane>\|<model>` is reused for 3 min), the lane's null when limited; [Block-ChatqLogin](src/watcher.ps1) the lane's null; [Invoke-ChatqJob](src/watcher.ps1) resets the `<lane>\|*` keys on a limit | the wake makes it empty |
| `probeFails` | map lane → int or null | | [Confirm-ChatqAllowed](src/watcher.ps1): counted on a failed probe, 0 when allowed | carries it |
| `scannedAt` | map lane → Date or null | | [Update-ChatqBlock](src/watcher.ps1) stamps now after a scan | reads it for the 10 min rule; stamps now for each queued job's lane at the wake, as the loop does, and for a failed `block` step ("Failure") |
| `authAlerted` | map lane → bool or null | | [Block-ChatqLogin](src/watcher.ps1) true; [Confirm-ChatqAllowed](src/watcher.ps1) false when allowed; [Restore-ChatqWatchState](src/watcher.ps1) true | restores it (`state.json` lists the true lanes) |
| `current` | string (a job id) or null | | [Invoke-ChatqJob](src/watcher.ps1) sets it and clears it; the pick catch clears it | sends null; `state.json` |
| `next` | string, UTC `o`, or null. A string, not a Date | | the loop: `$nextAt.ToUniversalTime().ToString('o')` | sets it as the loop does |
| `startedAt` | string, UTC `o` | | the loop, once: [Get-ChatqStamp](src/queue.ps1) | its own start stamp; never changed by a step |
| `handoff`, `listening` | bool | | the loop | `handoff` false in every `In` (set only on the way out); `listening` as the loop keeps it, true while only listening (from M3) |

`w.caches` holds all ten keys, always:

| Key | Value | chatqd |
|---|---|---|
| `ChatqReplyHandled`, `ChatqReplySeen` ([src/phone.ps1](src/phone.ps1), [src/phone-board.ps1](src/phone-board.ps1)) | map tag or nonce → `true` | carries them |
| `ChatqAskSent` ([Invoke-ChatqAskReply](src/ask.ps1)) | map rid → `hashtable` `{Rid: string, At: Date, ToolUseId: string, Answers, Transcript: string, SessionId: string, Title: string}` (each string may be null). `Answers` is a map question → answer text, decoded as `New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)`, as [ConvertTo-ChatqAskAnswers](src/ask.ps1) builds it, or null | reads every `At` for the ask-landed gate; drops entries for a failed `ask-landed` step |
| `ChatqReplyJunkLog` ([src/phone.ps1](src/phone.ps1)) | map stage → `hashtable` `{At: Date, Count: int}` | carries it |
| `ChatqReplyPolledAt`, `ChatqReplyErrAt`, `ChatqReplyBadIdAt`, `ChatqReplySavedAt` ([src/phone.ps1](src/phone.ps1)) | Date or null | carries them (M3 reads them) |
| `ChatqUsageSent` ([Send-ChatqUsageSoon](src/phone-extras.ps1)) | map soon key → `true` | reads the keys for the soon gate; adds keys the gate finds already sent |
| `ChatqSummaryTriedAt` ([Send-ChatqHeldSummary](src/phone-extras.ps1)) | Date or null | reads it for the held gate; sets now for a failed `held` step |

At chatqd's start every map is an empty list and every Date null, which decodes to what the parts declare at load (`@{}` and `$null`).

**Ops, each a thin wrapper over existing code.** `args` and `result` are JSON objects. A result field is always present.

| op | args | result | Body | When chatqd runs it |
|---|---|---|---|---|
| `repair` | `{}` | `{}` | [Repair-ChatqInterrupted](src/watcher.ps1), then `$W.CutCache = @{}` | once, at start, after the restore, when [gates::repair_due](native/crates/chatq-core/src/gates.rs) |
| `pick` (M2–M4) | `{jobId}` | `{gone: bool}` | [Find-ChatqJob](src/queue.ps1) `jobId -Exact`. No job, or a `state` other than `queued` (case-blind, as `-ne 'queued'` compares): `{gone:true}`, and nothing else is done (no log line, no probe, no `W` change). Else `Invoke-ChatqPick $W $job`: the loop's own `try { if (Confirm-ChatqAllowed $W $pick) { Invoke-ChatqJob $W $pick } } catch { #<seq> error: <msg> @ <frame>; fail; alert }`, moved verbatim into a function the PS loop also calls; `{gone:false}` | the loop's pick: the first queued job, in [Get-ChatqJobs](src/queue.ps1) order, with no due time, past any its own id does not find (§1.1). chatqd turns keep-awake on first; afterwards, gone or not, it saves state, writes the board and starts the next pass, as the loop does after its pick |
| `block` | `{jobIds: [id]}`; M2 sends exactly one | `{}` | for each id, [Find-ChatqJob](src/queue.ps1) `-Exact`; a job found goes to [Update-ChatqBlock](src/watcher.ps1) `$W $job`, a job not found is skipped | in the loop's walk over the queued jobs, just before a job's due check (never for a job passed over as its id does not find it, §1.1), when [gates::rescan_due](native/crates/chatq-core/src/gates.rs) holds for its lane's `scannedAt` |
| `probe` (M4+) | §7 M4 | | `Get-ChatqLaneProbe`: the process half of Confirm-ChatqAllowed, refactored out of it unchanged (Codex: [Get-ChatqCodexLiveLimit](src/queue.ps1), then the exec probe; Claude: the `-p` probe; `-NoModel` retry; the limited fallback to Get-ChatqClaude/CodexBlock) | the native gate needs a probe |
| `usage-reset` (M4–M5) | §7 M4 | | Send-ChatqUsageReset | the native gate says allowed after limited |
| `auto-outage` (M4+) | §7 M4 | | Enter-ChatqAutoOutage / Clear-ChatqAutoOutage | an outage transition |
| `auto` | `{}` | `{}` | `$null = Invoke-ChatqWatchAutoScan $W` | the 5 min timer fired (it is advanced whether a step runs or not, first pass included) and [gates::auto_wanted](native/crates/chatq-core/src/gates.rs) |
| `stray` | `{}` | `{removed: n}` | `$swept = @(try { Clear-ChatqStrayFiles } catch { })`, then, when n > 0, the loop's `watcher.log` line `removed <n> stray file(s) and folder(s) from data/queue` | the 6 h timer fired (advanced either way, first pass included) and [gates::stray_maybe](native/crates/chatq-core/src/gates.rs) |
| `soon` | `{}` | `{soonAt: UTC o \| null}` | `$queued = @(Get-ChatqJobs \| Where-Object { $_.state -eq 'queued' })`, then `$soonAt = Send-ChatqUsageSoon $W $queued` | a pass with no pick, when the soon pre-gate (below) leaves a due key. chatqd's wait is the earliest of its own `nextAt`, the gate's `next` and `soonAt` |
| `held` | `{}` | `{sent: bool}` | [Send-ChatqHeldSummary](src/phone-extras.ps1) | the held pre-gate (below) |
| `reply` (M3) | `{text, maxMessages, quick, timeoutSec}`, or `{fetch: true, maxMessages, quick, timeoutSec}`; M3 sends 10, false, 8 | `{acted: n}` | [Invoke-ChatqReplyPoll](src/phone.ps1) `-Force -MaxMessages <maxMessages> -Quick:<quick> -TimeoutSec <timeoutSec>`, with `-Text <text>` when `text` is given: the body runs on chatqd's batch from the point its own fetch would return. With `fetch` it fetches for itself. `-Force` skips the `MinSeconds` check against the `ChatqReplyPolledAt` chatqd has just set, and the second window check chatqd has made. After an Ok step chatqd keeps its own `ChatqReplyPolledAt` over the step's later stamp. `acted` is the poll's return | a batch holds a candidate (§3.7 step 5); with `fetch`, `replies.json` read `PsOnly` where chatqd reads `since` (DEFERRED.md "The reply registry's reads left to PowerShell"); with `text`, the same at a junk-only save, of `lastId` or of `lastPolledAt` alone (§3.7 step 4) |
| `ask-landed` | `{quick: false}` | `{}` | [Test-ChatqAskLanded](src/ask.ps1), `-Quick` when `quick` | `ChatqAskSent` is not empty and its oldest `At` is at least 20 s old ([timers::ask_landed_due](native/crates/chatq-core/src/timers.rs)), as the function skips younger entries itself |
| `board` (M3) | `{}` | `{}` | [Write-ChatqBoard](src/alerts.ps1). With `listening` saved, [Get-ChatqBlocks](src/alerts.ps1) scans the transcripts rather than reading `state.json`, which the native board cannot | the listening-only branch's board write, on entering it or after a poll that acted (§1.1) |
| `alert` | `{event, text, priority, jobId, loud, quick, noReply, usageKind}`: `jobId` and `usageKind` string or null, the rest as [Send-ChatqAlert](src/alerts.ps1)'s parameters of those names | `{sent: bool}` | `$job` = Find-ChatqJob `jobId -Exact` when `jobId` is set, else null; then `Send-ChatqAlert $event $text $priority -Loud:$loud -Job $job -Quick:$quick -NoReply:$noReply -UsageKind $usageKind`; `sent` = `[bool]` of its return | M2: only a failed pick's alert. Later: an alert that would register (§1.4), or any alert before M6 |
| `toast` (M6) | §7 M6 | | Show-ChatqToast | the WinRT toast failed |
| `job-write` | `{jobId, set: {field: value, …}}` or `{jobId, complete: {state, why, result}}` | `{saved: bool}` | Find-ChatqJob `jobId -Exact`; none → `saved:false`. `set`: `Set-ChatqProp` per field in the order given, then `Save-ChatqJob -Existing`. `complete`: only when the job's `state` is `queued` or `running`, `Complete-ChatqJob $job $state $result $why -Existing`; else `saved:false` | a write chatqd would make to a file read `repaired` or `lossy` (§2.2): in M2 the wake's `{deferUntil: null}` and a pick failure's `complete` (§2.4) |
| M5: `pre-run`, `run-started`, `permit-tick`, `post-run`, `run-ps` | §3.8 | §3.8 | §3.8 | §3.8 |

**Pre-gates.** chatqd runs a step only where the PS function would do something. Each gate is the function's own early return, ported:

- **held**: `gates::held_summary_due`. [Test-ChatqHeldWaiting](src/phone-extras.ps1) ([gates::held_waiting](native/crates/chatq-core/src/gates.rs)); and not inside quiet hours now ([Get-ChatqQuietHours](src/phone-extras.ps1) and [Test-ChatqQuietNow](src/phone-extras.ps1) on the config, local time; a bad clock or from equal to to reads as off; a window may run past midnight); and `ChatqSummaryTriedAt` null or at least 5 min old. These are [Send-ChatqHeldSummary](src/phone-extras.ps1)'s returns before its claim. `ChatqSendingSummary` is always false between steps.
- **soon**: [gates::usage_soon](native/crates/chatq-core/src/gates.rs) over `W.blocked`, the queued jobs and the `ChatqUsageSent` keys. Its `next` joins `nextAt`. Each due key already in `data/usage-alerts.json` (`gates::soon_already_sent`, case-blind) is added to `ChatqUsageSent` natively, as [Send-ChatqUsageSoon](src/phone-extras.ps1) records a key that [Use-ChatqUsageAlertState](src/phone-extras.ps1) finds there. "Already in" is what [Get-ChatqUsageAlertState](src/phone-extras.ps1) keeps: a top-level name whose value [ConvertTo-ChatqDate](src/queue.ps1) parses. A missing, empty, unreadable or unparsable file holds no keys. chatqd reads it with no lock, in its `--ps` flavour, since it only reads. Any other due key means a `soon` step.
- **stray**: [gates::stray_maybe](native/crates/chatq-core/src/gates.rs): with no file or folder that could be stray, the sweep would find nothing.
- **auto**: [gates::auto_wanted](native/crates/chatq-core/src/gates.rs): [Invoke-ChatqWatchAutoScan](src/auto-continue.ps1) returns 0 at once otherwise.
- **ask-landed**, **block** and **repair**: as the table says.

They run in the loop's order (§1.1), on chatqd's real clock (§8 "M2 contract notes").

**State ownership and pids.**

- [Save-ChatqWatchState](src/watcher.ps1) gains a seam: `pid` and `startedAt` come from `$script:ChatqWatcherPid` and `$script:ChatqWatcherStartedAt` when set. The step sets them from `In`, so `state.json` always names chatqd's pid. The macOS extension's liveness depends on this.
- **One pid per run.** A new `Get-ChatqRunnerPid` returns `$script:ChatqRunnerPid` when set, else `$PID`. The step sets it to chatqd's pid. It replaces `$PID` where `runnerPid` is written ([Invoke-ChatqJob](src/watcher.ps1); `runnerPid` in [Write-ChatRunState](src/chatrm.ps1)) and in [Repair-ChatqInterrupted](src/watcher.ps1)'s `runnerPid -eq $PID` skip.
  - From M2, the job's `runnerPid`, `run-state.runnerPid`, `watcher.pid` and `state.pid` all name the lock holder.
  - The extension's `runIsLive`/`runningJobFor` and the repair agree with the lock.
  - If the step dies while chatqd lives, chatqd fails the job (Failure, below), so no job stays `running` behind a live pid.
- **The step seams**, all declared `$null` in [src/queue.ps1](src/queue.ps1)'s seam block: [Invoke-ChatqNativeStep](src/watcher.ps1) sets `ChatqWatcherPid` = `In.watcherPid`, `ChatqWatcherStartedAt` = `In.startedAt` and `ChatqRunnerPid` = `In.watcherPid` as it reads `In`, and `src/native-step.ps1` sets `ChatqStepParent` = the parent test below, built from `-Watcher` and `-WatcherStart`. In the PS watcher all four stay `$null`, so every site keeps today's `$PID`.
- **`$PID` audit.** The audit test lists every `$PID` in the functions a step reaches. Each must be classed as *watcher identity* (through the seams above), or *own process*, which is correct as the step's pid. An unclassed `$PID` fails the test. The sites today:

| Site | What it names | Class | From M2 |
|---|---|---|---|
| [Save-ChatqWatchState](src/watcher.ps1) | `state.json` `pid` (and `startedAt`) | watcher identity | `ChatqWatcherPid` / `ChatqWatcherStartedAt` when set |
| [Repair-ChatqInterrupted](src/watcher.ps1) | the `runnerPid -eq $PID` skip | watcher identity | `Get-ChatqRunnerPid` |
| [Invoke-ChatqJob](src/watcher.ps1) | the job's `runnerPid` | watcher identity | `Get-ChatqRunnerPid` |
| [Write-ChatRunState](src/chatrm.ps1) | `run-state` `runnerPid` | watcher identity | `Get-ChatqRunnerPid` |
| [Write-ChatqPermitLog](src/permit.ps1) | the `[<pid>]` tag of a `permit.log` line | watcher identity | `Get-ChatqRunnerPid` |
| [Write-ChatqAskLog](src/ask.ps1) | the `[<pid>]` tag of an `ask.log` line | watcher identity | `Get-ChatqRunnerPid` (the hook process sets no seam, so it keeps its own pid) |
| [Invoke-ChatqAlertCommand](src/alerts.ps1), [Get-ChatqPermitLaunch](src/permit.ps1), [Get-ChatqOutboxLaunch](src/phone.ps1), [Get-ChatqAskHookCommand](src/ask.ps1), [Get-ChatqWatcherLaunch](src/watcher.ps1), [Get-ChatOverlayLaunch](src/overlay.ps1) | `(Get-Process -Id $PID).Path`: the PowerShell to launch with, which equals `--ps` | own process | unchanged |
| [Receive-ChatOverlayCommands](src/overlay-data.ps1) | the `"$p.$PID"` name a file is taken under | own process | unchanged |
| [Invoke-ChatOverlayCycle](src/overlay-data.ps1) | `overlay.json` `pid`: the overlay host running the cycle | own process | unchanged |
| [Start-ChatqAskHook](src/ask.ps1) | `hookPid`: the hook process | own process | unchanged |
| [Get-ChatqRunnerPid](src/queue.ps1) | its `$PID` fallback when `ChatqRunnerPid` is unset | watcher identity | new in M2: the seam when set |
| [Invoke-ChatqProcess](src/queue.ps1) | the parent check's `Stop-Process -Id $PID` | own process | new in M2: the step ends itself |

Not reached from any op, so outside the audit's list; if the reach analysis ever finds one, it fails: [Invoke-ChatqWatchLoop](src/watcher.ps1) (`watcher.pid` and its `watcher <pid> started`/`stopped` lines, which chatqd writes itself), [Set-ChatqKeepAwake](src/watcher.ps1) (`caffeinate -w`, `systemd-inhibit … --pid`; chatqd keeps itself awake), the overlay hosts' pid files and lines in [src/overlay-windows.ps1](src/overlay-windows.ps1) and [src/overlay-mac.ps1](src/overlay-mac.ps1), and [src/ask-hook.ps1](src/ask-hook.ps1), which is not a loader part.

**Parent death.**

- A step checks its parent at every op boundary and in every [Invoke-ChatqProcess](src/queue.ps1) `$check` (runs and probes), through the seam `$script:ChatqStepParent`.
- The parent is alive only if a process with pid `-Watcher` exists **and** its start time equals `-WatcherStart` within 1 s: `[math]::Abs((Get-Process -Id $Watcher).StartTime.ToUniversalTime().Ticks - $WatcherStart) -le 10000000`. .NET reads `StartTime` from `GetProcessTimes` on Windows and `proc_pidinfo` on macOS, the same sources chatqd uses for its own value (Launch, above). No such process, or a start time that cannot be read, counts as dead.
- If the parent is dead or the pid was reused, the step ends itself at once with `Stop-Process -Id $PID -Force`. No `finally`, no cleanup.
- That leaves exactly what a killed PS watcher leaves today: the CLI orphaned and running, the job `running` with a dead `runnerPid`, and the next watcher's repair marking it `interrupted - the watcher stopped mid-run; chatqrun <seq> sends it again`.
- chatqd does not kill a step on its own exit. On Windows the step is not in a kill-on-close job object, deliberately, so the orphaning semantics match.

**Failure.** Every step ends in exactly one outcome, tried in this order:

| Outcome | When | `<reason>` |
|---|---|---|
| did not start | the launch itself failed: `In` could not be written, chatqd's own start time could not be read, or `CreateProcessW` or `spawn` returned an error ([step::run](native/crates/chatqd/src/watch/step.rs)) | `did not start` |
| Ok | `Out` is a good answer with `ok:true`, whatever the exit code | none |
| failed | `Out` is a good answer with `ok:false` | `failed: <error>` |
| did not load | no good answer, exit code 3 | `did not load (exit 3)` |
| no answer | no good answer, any other exit code | `exited <code> with no answer` |

`<code>` is the exit code as a signed decimal: Windows' `GetExitCodeProcess` value as an `i32` (so `-1073741510` for a closed console), and on macOS the code, or 128 plus the signal number for a process a signal ended.

`chatqd.log` gets, per step:

- `step <n> <op> exited <code> after <ms> ms` for every step that started, `<ms>` from launch to exit;
- `step <n> <op>: helper step did not start (<OS error text>)` for a launch that failed;
- `step <n> <op>: helper step <reason>` for every other outcome but Ok;
- `stop seen while step <n> (<op>) runs`, at most once per step.

When the outcome is not Ok:

- `W` is left as it was before the step, caches included, with `current` null. `Out.w` is never taken in part.
- **`pick`** (and from M5 `pre-run` and `post-run`): PS's own catch did not run, so chatqd does the nearest thing, the pick-failure write of §2.4: the `watcher.log` line, the job failed if it is still `queued` or `running`, and only if that write happened the `failed` alert, through a fresh `alert` step with args `{event:'failed', text:'<title> · chatq error: helper step <reason>', priority:2, jobId:<id>, loud:false, quick:false, noReply:false, usageKind:null}` and `alertJob` `#<seq>`. If that step is not Ok either, `chatqd.log` gets `the failed alert for #<seq> did not go: helper step <reason>` (that step's reason). Then chatqd goes on as after any pick: save state, board, next pass.
- **A failed step whose gate still holds records its attempt** (your decision 3 of 2026-10-18), so the next pass does not run it again at once. chatqd checks the op's pre-gate again right after the step; `W` is as before, so only the files can have moved it (a `held` step that sent its summary and then died has left no `held.jsonl`). While the gate holds, chatqd records what the PS function records when it tries and fails:
  - `block`: `scannedAt[<lane>]` = now for the lane of each job named, as [Update-ChatqBlock](src/watcher.ps1) stamps after its scan;
  - `held`: `ChatqSummaryTriedAt` = now, as [Send-ChatqHeldSummary](src/phone-extras.ps1) sets on a failed push;
  - `ask-landed`: every `ChatqAskSent` entry whose `At` was at least 20 s old at the step's launch is dropped, as [Test-ChatqAskLanded](src/ask.ps1) drops each one before it looks.
- Nothing is recorded for the rest:
  - `auto` and `stray`: their timers moved at launch, as the loop moves them before the call;
  - `soon`: [Send-ChatqUsageSoon](src/phone-extras.ps1) never throws, and when its lock or save fails it records nothing either, so the next pass tries again in both engines (§8 "M2 contract notes");
  - `repair`: run once, as the PS watcher runs it once;
  - `alert` and `job-write`: the line in `chatqd.log` is all. A wake's `deferUntil` that a `job-write` failed to clear stays set, as a failed `Save-ChatqJob -Existing` leaves it in PS.
- **`reply` and `board`** (M3; the policy accepted 2026-10-20): the next step of the same op is held back 1 min, doubling to 10, and an Ok one ends the hold. `watcher.log` gets `phone replies wait: a reply step failed - tried again in a minute or more` (or `the board waits: a board step failed - tried again in a minute or more`) at most every 10 min. A failed `reply` step's batch is kept, as `lastId` has not moved, and is fetched again. The hold is on the step, not the poll: chatqd still polls at its cadence and still logs and saves junk-only batches meanwhile (§8 "Deliberate differences"). Neither is a fuse strike. In `Poller` ([watch/reply.rs](native/crates/chatqd/src/watch/reply.rs)).
- The loop continues. The `watcher.log` line of a failed pick is the one line chatqd writes that PS never wrote; today's equivalent is the PS watcher itself dying, which writes nothing (§8 "Deliberate differences").

**Audit test (Tier 0).** A self-test check parses every function a step op reaches. It uses the same reach analysis the self-test already runs for `$chatRoles` in [tests/sections/find-delete.ps1](tests/sections/find-delete.ps1). It lists:

- each `$script:` variable assigned or read there;
- each `$W.<key>`;
- each `$PID`.

Each must be classed as above, and each carried variable must round-trip. A new one fails the test.

**Cost.** About 0.4 s and a transient 100 MB per step.

- From M2: once at start; per job; per candidate batch; every 5 min for auto-continue, only while it is wanted; every 6 h for stray files; at most every 10 min per waiting lane for block scans; per alert.
- From M5 add per permission request, plus one at its close.
- The idle between them costs chatqd's own few MB. Measured at M2 (§8 risk 5).

### 3.7 The reply split (M3)

One poll, natively, mirroring [Invoke-ChatqReplyPoll](src/phone.ps1):

1. **Gate.** Replies on with a topic, and the window open ([Test-ChatqReplyOpen](src/phone.ps1), ported), unless the call is the in-run quick poll, which uses the same gate. Skip if `now - ChatqReplyPolledAt < MinSeconds`.
2. **Fetch.** URL as §1.3, timeout per §2.10, no `Authorization` header (as [Get-ChatqReplyFeed](src/phone.ps1), which sends none), the system proxy. Set `ChatqReplyPolledAt`. On failure, log `poll failed: <why>` at most every 10 min and stop.
3. **Read lines.** Parse each line as JSON; keep only `event == "message"`. Check the id shape (skipped-id log per 10 min) and the `topic|id` Handled tag. Triage each per §2.8.
4. **No candidate in the batch:**
   - log junk per [Write-ChatqReplyJunk](src/phone.ps1)'s rule, counting into `ChatqReplyJunkLog`;
   - when the batch had junk or an already handled id, do the junk-only save (`lastId` = the last such id, `lastPolledAt`) under `replies.lock` through `replystate.rs`. Only once that save is written are the junk tags marked Handled and `ChatqReplySavedAt` set; a failed save logs `could not save where polling got to: <why>` and leaves both, so the same lines are triaged again next time;
   - otherwise save `lastPolledAt` alone if `ChatqReplySavedAt` is 5 min old. Here `ChatqReplySavedAt` moves before the write, and a failure is not logged;
   - the result is "acted on 0".

   Built in M1 as [wire::poll_batch](native/crates/chatq-core/src/wire.rs), which gives the log lines and a [wire::Save](native/crates/chatq-core/src/wire.rs) for the caller to write; after a written `Save::LastId` the caller calls [PollCaches::saved](native/crates/chatq-core/src/wire.rs). It reads ntfy's lines with `serde_json`, lone surrogates mended first, not with §2.2's grammar (DEFERRED.md "ntfy's lines read as strict JSON").
5. **At least one candidate.** Write the batch's raw lines, in fetch order, into the `reply` step's `In`, with `maxMessages`, `quick` and `timeoutSec`. The step runs the poll body from "read lines" on, through a seam that replaces the fetch with the given lines. That covers the junk lines, the candidates, `MaxMessages` counting genuine messages only, [Receive-ChatqReply](src/phone.ps1), [Receive-ChatqCompose](src/phone-board.ps1) and [Receive-ChatqPairing](src/phone.ps1) with save-before-act, the break at `unsaved`, the refusal pushes and the acts. It returns the acted-on count and the shared caches.
6. **After the step**, chatqd re-reads `replies.json` (`lastId`, `hotUntil`, `openUntil`) and never advances `lastId` itself. A message left behind by `unsaved` or `MaxMessages` is fetched again next time, as today.

**Why this cut is exact.** For a batch with no candidate, the PS body runs only the native steps listed in 4. Every PS branch beyond them needs `Reply`, `Pair` or `Compose` set, which only a candidate sets. For a batch with a candidate, PowerShell runs the whole body over the same lines. The vector `reply-triage.json` holds, for a corpus per label (good, tampered, wrong id, bad encoding, `len%4==1`, trailing bits, no key, pairing pending or not), the stage, the error text and the exact `replies.log` line PS writes. The fake-ntfy test runs mixed batches through both engines.

**Flood bound.** A batch is one step, whatever its size, and a poll happens at most every 6 s. So a flood of pairing-shaped messages during a pairing window costs at most one step per poll.

### 3.8 The run split (M5)

**M5a, in PowerShell first, with no behaviour change.** [Invoke-ChatqJob](src/watcher.ps1) and [Invoke-ChatqRun](src/queue.ps1) are cut into four functions. The PS watcher itself then calls them in sequence:

- `Start-ChatqJobRun` returns `{go:false}` or a **plan**:
  - everything in §1.2's "before the run" row;
  - CLI discovery and the version gate (a refusal ends here, as today, with today's texts);
  - the argv and the built command line;
  - the env delta; cwd; the stdin file; the `.jsonl` path; the timeout;
  - the permission `Run` (`RunId`, `Dir`, `WaitMinutes`, `TimeoutMs`) when one starts;
  - the run-settings path to delete later;
  - `keepOut`/`what` for the started alert;
  - `provider`.
- `Invoke-ChatqJobProcess` takes the plan, runs [Invoke-ChatqProcess](src/queue.ps1) with today's `OnLine`/`OnTick`, and returns `{St, Proc, ByStop}`.
- `Send-ChatqRunStarted` is today's `onStart` body.
- `Complete-ChatqJobRun` takes plan + `{St, Proc, ByStop}` and does everything after the process: §1.2's "after the run" and retry-policy rows, through the `finally`.

The existing suite proves M5a: PS behaviour is unchanged.

**M5b, chatqd's run.**

1. `pre-run` step → plan, or `go:false` (the loop goes on).
2. chatqd records the `.jsonl` length (the replay offset, below), spawns per §2.6, and runs the tick.
3. **Lines.** Each line is parsed by `stream.rs` into St. The first time `St.Init` is true and `Started` false, set `Started` and run the `run-started` step with `{mode: St.Mode or job.mode}`.
4. **Tick**, in PS's `onTick` order:
   1. Heartbeat: [Save-ChatqWatchState](src/watcher.ps1) if 60 s have passed.
   2. Permission gate, when the plan has a `Run`. It reproduces [Update-ChatqPermitRequests](src/permit.ps1)'s triggers. A `permit-tick` step runs the real function, with `Run.Seen`, `Run.Open`, `Run.St.ToolIds` and the job, only if one of these holds:
      - a `*.req.json` in `Run.Dir` parses, and its rid is not in `Seen` or is in `Seen` with `Done` false, unless it is inside its 10 s window with its `toolUseId` still unseen and no new `tool_use` id since the last step;
      - an `Open` rid's `req.json` has changed mtime or shows `answer`/`withdrawn`;
      - `now` is past an `Open` entry's `Until`.
      - On every other tick the PS function reads, finds nothing to do and returns `Open.Count > 0`, which chatqd knows. A `req.json` that does not parse yet is skipped by both.
      - `asking` = `Open` non-empty.
   3. Reply poll per §3.7 with `MinSeconds` 5 if asking, else 10 if hot, else 30; timeout 5 s; `maxMessages` 2; `quick`.
   4. If the oldest `ChatqAskSent.At` is 20 s old, an `ask-landed` step with `-Quick`.
   5. `D/stop` exists → `byStop = true`.
   6. Stop with `cancelled` if the cancel file exists or `byStop`; then the deadline.
5. **Exit:** §2.6's exit and stderr waits.
6. `post-run` step with `{plan, St, Proc{ExitCode, Stopped, Pid, stderrPath, stderrDone}, ByStop}`. It rebuilds St and calls `Complete-ChatqJobRun`.
   - **Rebuilding St.** St travels as [St::to_json](native/crates/chatq-core/src/stream.rs) makes it (built in M1): `New-ChatqRunState`'s 23 keys, in its order and by its names. Booleans, counts, strings and lists travel as JSON values. `Started` is the flag step 3 sets; the line readers never set it. `ToolIds` travels as an object, its keys in ordinal UTF-16 order. Object-valued fields (`Result`, `Rate`, `Limit`) travel as **the raw stream line they came from**, or null, and the step re-parses it with `ConvertFrom-Json`, taking `.rate_limit_info` where PS did. A `Rate` travels whenever it was set, even to a value PS holds false. The object graph is then the one PS would have held.
   - What does not survive: `Session`, `Model`, `Mode`, `Version`, `Thread` and Claude's `LastText` travel as the JSON they were read as, so a number's .NET type and a decimal's trailing zeros are lost, and an integer past 2^64 too.
   - **Replay check.** In Tier 0, `post-run` also replays the `.jsonl` from the recorded offset through the real `Update-ChatqClaudeState` and asserts the two St agree.
7. **Spawn failure** (`CreateProcessW`/exec error): chatqd runs a `run-ps` step with the plan. It calls `Invoke-ChatqJobProcess` and `Complete-ChatqJobRun` inside `Invoke-ChatqPick`'s catch, so .NET's own exception produces the identical `#<seq> error: … @ <frame>` line. If .NET succeeds where `CreateProcessW` failed, the run simply happens in PowerShell.

The permission bridge is launched by `claude` from `mcp.json`, which `pre-run` wrote. It is unaffected by who spawned `claude`.

---

## 4. Lifecycle and cutover

### 4.1 Who starts it

There is one seam. Everything that starts a watcher reaches [Start-ChatqWatcherProcess](src/watcher.ps1) → [Get-ChatqWatcherLaunch](src/watcher.ps1):

- a shell's auto-start block in [Charlie-and-the-chat-factory.ps1](Charlie-and-the-chat-factory.ps1), for queued jobs and an open reply window. It is skipped under `CHATQ_WATCHER`, `CHATQ_OVERLAY` or `CLAUDECODE`, or in a non-interactive session;
- [Start-ChatqWatcher](src/watcher.ps1), behind `chatq`, `chatqrun`, the overlay and the extension's PowerShell calls. It returns `Test-ChatqWatcherAlive` after 40 × 250 ms; with an empty queue a watcher that already left is not a failure;
- [Request-ChatqWatcher](src/commands.ps1) / `Test-ChatqWatcherRequest`, with their 10 s look-again and one respawn;
- [Send-ChatqAlert](src/alerts.ps1) after an answerable alert;
- [Start-ChatqReplyStanding](src/phone-down.ps1);
- the watcher's own respawns, on restart and on emptied-while-a-window-opened. In chatqd these are native (§4.2).

`Get-ChatqWatcherLaunch` returns `{Exe, Args, Command}` for either engine. `$script:ChatqSpawn` stays the test seam and receives the chosen launch.

**The native launch.**

```
Exe  = R/bin/<ChatVersion>/<target>/chatqd(.exe)     or $env:CHATQ_CHATQD
Args = watch --root "<R>" --script "<ChatqScriptPath>" --ps "<(Get-Process -Id $PID).Path>" --culture <b64url json>
Env  = the caller's (CHATQ_CLAUDE / CHATQ_CODEX / CHATQ_NATIVE_SEAMS included)
Cwd  = $HOME
```

- Windows: `Start-Process -WindowStyle Hidden -WorkingDirectory ([WildcardPattern]::Escape($HOME)) -PassThru`.
- macOS: `nohup … > D/logs/watcher.out 2> D/logs/watcher.err`, the same as today.
- Before either, the fuse's preflight and pending record (§4.2).

`--ps` records the PowerShell flavour of the starter. Steps, a PS handoff and the alert `command` all use it, so the flavour is what today's watcher would have been.

**chatqd's start.**

1. It is built with `#![windows_subsystem = "windows"]`, so no console is ever created or flashed.
2. It calls `PeekMessageW` once at startup. A GUI-subsystem process launched with feedback otherwise shows the "app starting" cursor for 5 s.
3. `--foreground` calls `AttachConsole(ATTACH_PARENT_PROCESS)` for its debug output.
4. It sets `CHATQ_WATCHER=1` and removes `PSExecutionPolicyPreference` from its own environment before anything else.
5. It loads seams (§6.5).
6. Lock (§4.3). If busy after 5 tries: ack by deleting its own `pending.json` (§4.2), leave `last.json` alone, and exit 0.
7. Holding the lock: delete `D/native/carry.clixml` and step leftovers (only now: before the lock they may be a running watcher's), ack `holding`, then §1.1's start-up order. At exit, after the final `last.json`, it acks once more (§4.2's pending race).
8. A panic hook writes `chatqd panicked: <msg>` to `chatqd.log`. A panic inside the loop is caught (`catch_unwind`), records a `panic` fuse strike, runs the normal `finally` and does the panic handoff (§4.4). A panic before the lock is only logged; its launch's `pending.json` stays and becomes the "no ack" strike.

### 4.2 Engine switch, fallback and fuse

- **Config.** `config.json` key `watcher` = `"native"` \| `"ps"` \| absent. Absent means `native` whenever the binary is there (decided 2026-10-15: no user-facing switch). Until M7 ships the binary, only a dev build has one, so users keep the PS watcher with no setting at all.
  - No command sets it. `watcher: "ps"` is a hand-edited escape hatch, read with no lock like every key [Get-ChatqConfig](src/alerts.ps1) reads. A version change clears the fuse; so does deleting `D/native/fuse.json` by hand.
  - The self-test checks that every config writer preserves an unknown key, so `watcher` survives `chatnotify` and setup round-trips.
- **Override.** `CHATQ_ENGINE=ps|native` wins over config, for one launch and its descendants.
- **Decision**, the same in PS (a new `Get-ChatqWatcherEngine` in [src/watcher.ps1](src/watcher.ps1)) and Rust (`launch.rs`), held equal by `launch.json`. Native only if all of these hold:
  1. engine resolves to `native`;
  2. the OS is Windows or macOS;
  3. the binary exists at the versioned path (or `CHATQ_CHATQD`), **is executable** (on macOS the owner exec bit, from `Get-Item`'s `UnixMode`), and has passed **preflight** for its identity (below);
  4. no fuse is blown.

  Otherwise PS. Linux always runs PS.
- **Preflight.**
  - The first time a binary identity (full path, size, mtime) is about to be launched, the launcher runs `chatqd version --root <R>` synchronously, with a 5 s timeout. It must exit 0 and print exactly `chatqd <ChatVersion> <target>`, where `<ChatVersion>` is the launcher's own.
  - chatqd is a GUI-subsystem exe, so PowerShell's `& chatqd.exe version …` neither waits for it nor captures its stdout, and leaves `$LASTEXITCODE` unset (measured in Windows PowerShell 5.1). The PS preflight starts it as a `System.Diagnostics.Process` from [New-ChatqProcessStartInfo](src/queue.ps1) (no shell, no window, pipes redirected), closes stdin, then `WaitForExit(5000)` (a one-line answer fits the pipe buffer, so waiting before reading cannot deadlock; `ReadToEnd` first would defeat the timeout), kills it on a timeout, and reads `ExitCode` and stdout. Never `&` or `Start-Process` without redirection.
  - `chatqd version` prints its **compiled** version, never the one it reads, so the launcher's comparison catches a mismatch. It also reads the loader under `--root` (the `readVersion` regex) and exits 2 with `chatqd <compiled> <target>: the scripts are <loader version>` when the two differ, or 3 when the loader cannot be read.
  - `<target>` is the `bin/` folder name of §4.5, not the compiled triple: `x86_64-pc-windows-msvc` on Windows, and `universal-apple-darwin` from both Apple slices, though each slice is built for its own triple.
  - That catches the most common failures before anything waits on them: a missing exec bit, a signature killed at exec on Apple Silicon, a wrong architecture, an AV block, a missing DLL, a version mismatch.
  - A pass is cached in `D/native/verified.json`. A failure is a strike, and this launch goes to PS.
  - The identity's path is the full path as `Get-Item`'s `FullName` gives it (GetFullPathNameW: absolute, `/` and `..` resolved; Rust [Identity.of](crates/chatq-core/src/launch.rs): `std::path::absolute`, and off Windows, where that keeps `..`, `..` dropped by text as .NET's GetFullPath does, symlinks left alone), compared case-blind as `-eq` does. A new pass replaces any entry for the same path, so the file holds one entry per path.
- **Fuse.** `D/native/fuse.json` holds `{version, strikes:[{at, why, pid}], alerted}`. A strike is recorded when:
  1. preflight fails;
  2. `Start-Process` throws for the native exe (strike, and this launch goes to PS). chatqd's own launch counts a failed `CreateProcessW`, or a `ResumeThread` that fails (the child is then terminated), as `start failed`, and deletes the `pending.json` it wrote for that child, so one failure is one strike;
  3. a **pending launch has no ack**: every native launch writes `D/native/pending.json` `{pid, version, at}`. Any later decision call, from any launcher (shell auto-start, [Request-ChatqWatcher](src/commands.ps1)'s look-again, `Send-ChatqAlert`, `Start-ChatqWatcher`, chatqd's own respawn), that finds it older than 15 s and its pid no longer a live chatqd records the strike and clears it (the ack is the file's deletion, below);
  4. a **crash**: `last.json` says `{engine:"native", state:"holding", pid:P}`, P is dead, `watcher.lock` is free, and `watcher.pid` still exists (a clean `finally` deletes it). The strike is recorded once per P, by any decision call;
  5. chatqd panicked inside its loop (§4.1 item 8).

  Only a record of the decision's own version strikes. A stale `pending.json` or `last.json` of another version is cleared (pending) or ignored (last), since a version change clears the fuse anyway.

  chatqd writes `last.json` atomically: `holding` once it has the lock, then `empty`, `stopped` or `handed-over` at exit. Those exits are acks, never strikes, so "exit 0 because empty" is no longer mistaken for success or failure.
  - **Only the lock holder writes `last.json`.** A chatqd that finds the lock busy acks by deleting `pending.json` when its `pid` is its own, and leaves `last.json` alone. Were it to write `busy` there, it would overwrite the running chatqd's `holding`, and that one's later crash would never be a strike. A chatqd that gets the lock deletes its own `pending.json` right after writing `holding`, so one later crash is one strike, not two. So "pending with no ack" means `pending.json` is still there.
  - **The pending race.** `pending.json` must exist before the child can ack. chatqd's Windows launch guarantees it: `CreateProcessW` with `CREATE_SUSPENDED`, write `pending.json`, then `ResumeThread`. A launcher that learns the pid only after the child runs (PS `Start-Process -PassThru`, and macOS `nohup`) can write it after the child already acked, which would later read as a false "no ack" strike. chatqd narrows that by acking again at exit, after its final `last.json`. The PS launcher closes the rest: right after writing `pending.json`, if `last.json` already names the child's pid, or the child has already exited with code 0 (every ack path exits 0), it deletes `pending.json` itself. A child that exited non-zero keeps it, for the "no ack" strike.
  - **3 strikes within 24 h for the same version** → the decision says PS until the version changes, or until `D/native/fuse.json` is deleted. One line goes to `chatqd.log`, plus a one-time `failed` alert: `the native watcher failed 3 times - the PowerShell watcher runs instead`. `fuse.json` gains `alerted: true` once it is sent. Only a PowerShell decision call sends it; chatqd has no `alert` step before M2, so a fuse chatqd blows is alerted by the next PS decision call that sees `alerted` unset.
  - **Every strike also launches the PS watcher at once**, from the decision call that found it, if no watcher is alive. So a broken binary leaves no gap longer than the next decision call. That launch is the decision call's own launch, made with §2.7's command: a call that finds a strike does not also launch chatqd. chatqd's respawn is such a call too. [Request-ChatqWatcher](src/commands.ps1)'s 10 s look-again bounds that for commands.
  - Killing chatqd by hand counts as a crash strike (§8 risk 13).
- **Respawn and update.** chatqd's own respawns (restart, emptied-with-window, handoff) **never reuse chatqd's compiled version**:
  - it re-reads `$script:ChatVersion` from `--script` on disk, with the same regex as [extension/setup.js](extension/setup.js) `readVersion`;
  - it reads config, `CHATQ_ENGINE` and the fuse;
  - it runs `launch.rs`'s decision, then spawns either `R/bin/<new version>/<target>/chatqd` (after preflight) or the PS watcher (§2.7).
  - If the new binary is not there, the answer is PS with the new scripts, so an update never strands an old binary and never leaves no watcher.
  - If the loader cannot be read, the answer is PS.
- **Rollback.** Removing `bin/` or setting `watcher: "ps"` restores today's behaviour exactly. The PS watcher stays in the payload, tested, for at least two minor versions after M7's default flip.

### 4.3 Single instance and liveness

- chatqd takes the same `D/watcher.lock` with the same mode (§2.1), with 5 tries 200 ms apart. That is required because the handing-over watcher releases only as it exits, and probers hold the lock for an instant.
  - Windows: `share_mode(0)`, held as an open handle for life.
  - macOS: `flock(LOCK_EX|LOCK_NB)` on an `O_CLOEXEC` fd. The lock is advisory there, and the extension checks `state.pid` instead, which §3.6 keeps pointing at chatqd.
- Every prober keeps working unchanged:
  - [Test-ChatqLockHeld](src/alerts.ps1): open fails → held;
  - the extension's `io.lockHeld` on win32;
  - on macOS, `state.pid` alive;
  - inside a step, [Test-ChatqWatcherAlive](src/alerts.ps1) probes the lock chatqd holds and answers true, so the board's `watcher running` and `Send-ChatqAlert`'s start check behave as in today's watcher.
- A PS watcher and chatqd exclude each other through the one lock. Neither knows which engine holds it, and neither needs to; `last.json` is for the fuse only.
- `watcher.pid`, `state.json.pid`, every `runnerPid` and `run-state.runnerPid` = chatqd's pid.

### 4.4 Handoff in both directions

- **chatqd → PS.** Used in M0–M2 for any duty the milestone does not yet cover in-process, on panic, and from M3 when the system refuses the poll its connect (§8 "Deliberate differences"):
  1. Set `W.handoff = true`.
  2. Run the normal `finally`: keep-awake off, delete pid, save state, release lock, log `watcher <pid> stopped`. Ack `handed-over`.
  3. Then spawn the PS watcher with §2.7's command.
  4. Log one line to `chatqd.log`: `handing over to the PowerShell watcher: <reason>`.

  The PS watcher logs `carrying on from the watcher before it`, as on a restart today.
- **What a handoff carries** (from M2; your decision 6 of 2026-10-18). A handoff mid-life, from M3 a panic or the system refusing the poll its connect (§8 "Deliberate differences"; the reply window opening was the other until M2), carries chatqd's whole `W` and its caches to the PS watcher, so it does not repeat a probe, a scan, an ask check or a soon alert chatqd already made.
  - **Writer.** chatqd, on `Exit::Handoff` only (from M3 a panic, or a refused connect), before step 2's state save: `D/native/handoff.json` = `{"v":1, "watcherPid":<chatqd pid>, "w":{…}}`, `w` in §3.6's encoding with `handoff` true. Written atomically, like `In`. `carry.clixml` is left in place.
  - **Not on a restart.** `Exit::Restart` (the `restart` file, an engine switch) writes no `handoff.json`, so the next watcher, of either engine, restores from `state.json` alone, as a PS watcher after a PS restart does.
  - **Reader.** [Restore-ChatqWatchState](src/watcher.ps1), only when `state.handoff` is true and `D/native/handoff.json` exists. It is taken only if `v` is 1 and `watcherPid` equals `state.pid`. It is decoded with `ConvertFrom-ChatqStepW` into a fresh W and fresh caches first, so a file that does not decode is ignored whole. Then:
    - taken: `blocked`, `lastAllowed`, `probeFails`, `scannedAt`, `outage` and `authAlerted` come from it, in place of the `state.json` restore; the ten caches are set; `carry.clixml` is imported, as a step imports it. `current`, `next`, `startedAt`, `handoff` and `listening` are not taken: they are the new watcher's own;
    - not taken: the `state.json` restore runs as today.
  - Either way, once it has looked at a `handoff.json`, it deletes `handoff.json` and `carry.clixml`.
  - chatqd's start sweeps `handoff.json` with the step files and the carry (§4.5), so a file no PS watcher took never outlives the next chatqd.
  - The auto and stray timers are not carried: the PS watcher runs both on its first pass, as after any restart (§8 "Deliberate differences").
- **PS → chatqd.** Only through `restart` (engine switch, install) and the normal respawns, which go through the decision. There is no ping-pong: from M3 on, chatqd handles everything through steps and never hands back by itself except on panic, or when the system refuses it the poll's connect.

### 4.5 data/ layout additions

```
R/bin/<version>/<target>/chatqd(.exe)    shipped payload, beside src/ (not runtime data)
R/src/native-step.ps1                    shipped step entry (3.6)
D/native/step-<n>.in.json|.out.json      step exchange; deleted after each step; leftovers swept at start
D/native/carry.clixml                    PS-only caches across steps (3.6); deleted at chatqd start, kept at a handoff
D/native/handoff.json                    {v, watcherPid, w}: W and caches for the PS watcher at a handoff (4.4);
                                         deleted by its reader and at chatqd start
D/native/run-<jobId>.stdin|.err          a run's prompt and stderr spool (2.6); deleted by post-run
D/native/pending.json                    the last native launch not yet acked: {pid, version, at} (4.2)
D/native/last.json                       the lock holder's record: {pid, version, engine, state, at} (4.2)
D/native/verified.json                   preflight passes, one per full path: {passed:[{path, size, mtime, at}]},
                                         mtime as LastWriteTimeUtc 'o', at = UTC 'o' (4.2)
D/native/fuse.json                       {version, strikes:[{at, why, pid}], alerted} (4.2)
D/logs/chatqd.log (+ .1)                 chatqd diagnostics
D/logs/watcher.out|.err                  macOS nohup output, unchanged
D/chatqd.sock                            macOS IPC (M8)
```

`<target>` is `x86_64-pc-windows-msvc` or `universal-apple-darwin`. The binary goes under `R/bin`, not `D`: it is versioned product code like `src/`, and `D` keeps only state, which survives reinstalls. chatqd always gets `--root R`, so its data folder is the tool's own `D`, whatever its exe's folder.

### 4.6 Versioning

- `native/Cargo.toml` `[workspace.package] version` must equal `$script:ChatVersion`:
  - `chatqd/build.rs` reads the loader with the same regex as [extension/setup.js](extension/setup.js) `readVersion` (`^\$script:ChatVersion = '(\d+)\.(\d+)\.(\d+)'`, latin1) and fails the build on a mismatch;
  - [extension/build.js](extension/build.js) gains the same refusal for the staged binary (`chatqd version` output).
- chatqd writes `version` in `state.json` from its compiled version, so the field means what it means today.
- **The versioned path is the main version check.** The PS launcher only ever selects `bin/$ChatVersion/`, so new scripts never run with an old binary. Preflight confirms it once per binary (§4.2). chatqd's respawns re-read the loader, so they never carry an old version forward.
- A version bump touches the loader, `extension/package.json` and `native/Cargo.toml` together, in the one versioned commit.

### 4.7 Distribution

**Recommendation: prebuilt binaries.** Rejected: building on install. It needs a Rust toolchain plus MSVC Build Tools (gigabytes) on every user's PC, and this PC's rustup was just blocked by a firewall.

- **The dry run, built in M0.** [.github/workflows/release.yml](.github/workflows/release.yml) runs only by hand (`workflow_dispatch`) and attaches nothing:
  1. job `test` runs the whole of [test.yml](.github/workflows/test.yml), whose `native-windows` and `native-macos` legs make the two builds (§6.4). The `lipo`, the re-sign after it, `codesign --verify --strict --verbose=2`, a run of each slice and the `.tar.gz` with mode 0755 inside all happen there, on the Mac;
  2. job `assets` (ubuntu-latest) downloads the artifacts named `chatqd-*`, takes the version from `native/Cargo.toml`, and makes `chatqd-<v>-x86_64-pc-windows-msvc.zip` and `chatqd-<v>-universal-apple-darwin.tar.gz`. It checks that the tar holds `chatqd` as `-rwxr-xr-x`, writes `SHA256SUMS`, and uploads all three as the artifact `chatqd-release`.

  It signs nothing, has no tag trigger, adds no provenance and makes no GitHub release. The real release workflow below adds those, once install.ps1 fetches the assets.
- **Release workflow** (the dry run grown into the real one, on tag `v<ChatVersion>`; not yet built):
  - build `x86_64-pc-windows-msvc`, `aarch64-apple-darwin`, `x86_64-apple-darwin`;
  - `lipo -create` the two Apple builds into one universal binary;
  - **re-sign after `lipo`**, since `lipo` invalidates the linker's ad-hoc signature and Apple Silicon kills an invalid arm64 binary at exec: `codesign --force --sign - chatqd` (ad-hoc), or with a Developer ID and `--options runtime` plus notarization if chosen (§8 question 4). Then `codesign --verify --strict --verbose=2` must pass;
  - Authenticode-sign the Windows exe (§4.8);
  - attach the assets `chatqd-<ChatVersion>-x86_64-pc-windows-msvc.zip`, `chatqd-<ChatVersion>-universal-apple-darwin.tar.gz` (mode 0755 inside) and `SHA256SUMS`;
  - add build provenance (`actions/attest-build-provenance`).
- **[install.ps1](install.ps1)**, ordered so a matching binary is in place before scripts that would select it:
  1. Expand `main.zip` into `D/download/` (where it already stages) and read `ChatVersion` from the downloaded loader.
  2. Download the matching asset into `D/download/`. Verify it against `SHA256SUMS` and, on Windows, the Authenticode signature (`Get-AuthenticodeSignature` Valid and the expected subject).
  3. Expand to `R/bin/<ChatVersion>/<target>/`. On macOS use `/usr/bin/tar -xzf`, which keeps the mode, then `chmod 755` regardless.
  4. **Then** copy the scripts, **then** write `D/restart` as today.
  5. Any failure in 2–3 is not fatal: say `native watcher unavailable - the PowerShell watcher runs`, and the decision picks PS.
  6. CDN lag (main.zip newer than the tagged release) gives the same result: no asset yet, so PS.
- **`chatinstall`.** Copies `bin/` from its source **before** the loader, `chmod 755` on Unix, then prunes `R/bin/<other versions>`, best-effort. A folder whose exe is running fails to delete and is retried on the next install. In-use replacement never arises, because a new version is a new folder.
- **Extension** ([extension/build.js](extension/build.js), [extension/setup.js](extension/setup.js)):
  - `build.js` stages `payload/bin/<ChatVersion>/<target>/` from CI artifacts and refuses a version mismatch;
  - `setup.js` `copyPayload` copies `bin/` before the loader, using its existing `.new` + rename `put()`, then **`fs.chmodSync(…, 0o755)`** on non-Windows. A VSIX does not reliably keep Unix modes;
  - packaging: platform-specific VSIX (`vsce package --target win32-x64` / `darwin-arm64` / `darwin-x64`), each carrying its own binary, if published to the Marketplace. Otherwise one VSIX carrying the Windows exe and the universal Mac binary (about 6 MB more). Open question in §8.
  - **Built for the native panel in `0.11.1`** (chatqd is not shipped yet): one VSIX for every platform, carrying `chatq-overlay.exe` and its `THIRD-PARTY-NOTICES.html` (DEFERRED.md "Platform-specific VSIXes"). test.yml's `native-windows` leg builds the exe, writes the notices with `cargo about generate` ([native/overlay/about.toml](native/overlay/about.toml), [native/overlay/about.hbs](native/overlay/about.hbs); cargo-about pinned at 0.9.2) and uploads both as one artifact. [stageBin](extension/build.js) stages them at `payload/bin/<ChatVersion>/x86_64-pc-windows-msvc/` from the file `CHATQ_OVERLAY_EXE` names, refusing a file that is not an x64 PE and an exe whose `--version` is not `chatq-overlay <ChatVersion>`; with `CHATQ_REQUIRE_BIN=1` (test.yml's package step, publish.yml on a tag) a missing exe or notices fail the build, without it they warn. The overlay crate's version is the loader's ([native/overlay/build.rs](native/overlay/build.rs) asserts it). [copyBin](extension/setup.js) copies `bin/` first, on Windows only, each file best-effort - a locked exe is logged and the scripts still land - and [pruneBin](extension/setup.js) then renames each other `bin/<x.y.z>` aside and deletes it, keeping one in use and any name not a version. No chmod: the Mac binary is not shipped. publish.yml attaches the exe and notices zipped, with `SHA256SUMS`, beside the VSIX. Unsigned: DEFERRED.md "Signing chatq-overlay.exe".
- **Developer checkout.** From the repo root, `cargo build --release --manifest-path native/Cargo.toml --config native/.cargo/config.toml` (host target only, the installed stable, no downloads; §3.1). Then either `CHATQ_CHATQD=<path>`, or a copy by hand of the exe into `R/bin/<ChatVersion>/<target>/` (TESTING.md S55). No script stages a build: DEFERRED.md "A script that stages a chatqd build".

### 4.8 Code signing and AV

- **Today** the release dry run (§4.7) is unsigned: no Authenticode, no version resource, no manifest, and on macOS only the ad-hoc re-sign after `lipo`. Everything below is for the real release.
- **Windows: Authenticode** every release binary. Recommended: Azure Trusted Signing (low monthly cost, EV-like reputation), or SignPath's free OSS programme.
  - Timestamp the signature.
  - Embed a version resource (CompanyName, ProductName "Charlie and the chat factory", FileDescription "chatq watcher", versions = ChatVersion) and an `asInvoker` manifest.
  - No packers (no UPX). Deterministic builds (`--remap-path-prefix`, a locked toolchain).
- **Heuristics risk.** This is a new exe that runs hidden, spawns hidden PowerShell, reads DPAPI and posts to ntfy.sh. Machine-learning AV detections are likely before reputation builds.
  - Mitigations:
    - signing and the version resource;
    - **steps use `-File src/native-step.ps1`, never `-EncodedCommand`** (decided, §3.6);
    - submitting each release to the Microsoft WDSI false-positive portal;
    - preflight and the fuse with an immediate PS fallback, so an AV quarantine degrades to today's behaviour instead of breaking.
  - The PS watcher launch chatqd builds (§2.7) keeps today's `-EncodedCommand`, because it must be byte-identical to what `Get-ChatqWatcherLaunch` builds. It happens only on handoff and fallback.
- **SmartScreen** does not apply: chatqd is started by `CreateProcess`, never from Explorer with Mark-of-the-Web. `Invoke-WebRequest` adds no Zone.Identifier.
- **AppLocker/WDAC** environments that block user-writable executables make chatqd fail to start. Preflight turns that into PS on the first launch.
- **macOS.** The universal binary is re-signed after `lipo` (§4.7). Files fetched by `install.ps1` (pwsh `Invoke-WebRequest`) or extracted by VS Code carry no quarantine attribute, so Gatekeeper does not assess them; the code signature is still enforced at exec, which is why the re-sign is mandatory. A Developer ID and notarization are recommended but optional (Apple Developer cost): open question.

---

## 5. IPC (M8: the compiled ask-hook and permit stubs)

### 5.1 Principle

**Files stay the source of truth. IPC is only an accelerator.** Every IPC message is a hint ("look now") or a status; none carries authority or a secret. A stub that cannot connect behaves exactly as a stub without IPC: it polls the files on the PS cadence. A watcher of either engine with no IPC loses nothing but latency. From M8 the permission gate of §3.8 can also take a `look now` hint from the permit stub, instead of waiting for the next 5 s tick.

### 5.2 Transport

**Windows: named pipe.**

- Name: `\\.\pipe\chatqd-<user SID>-<hex16(SHA-256(lowercase full path of D))>`, so two installs never share one.
- Created with `FILE_FLAG_FIRST_PIPE_INSTANCE` (anti-squat), `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_REJECT_REMOTE_CLIENTS` and a protected DACL `D:P(A;;GA;;;<user SID>)`: owner only.
- The server checks the client: `GetNamedPipeClientProcessId` → token user SID must equal its own.
- The client checks the server: `GetNamedPipeServerProcessId` must equal `watcher.pid`, and the server's `QueryFullProcessImageNameW` must equal the expected `R/bin/<ver>/…/chatqd.exe`.

**macOS: Unix socket at `D/chatqd.sock`.**

- Created under `umask 077` (mode 0600). A stale file is unlinked only by the lock holder at start.
- The server checks peers with `getpeereid` (uid must match).
- The client checks `LOCAL_PEERPID` == `state.json.pid` and `getpeereid` == own uid.
- `sun_path` is 104 bytes. If the path is longer, there is no IPC (logged once to `chatqd.log`), with no fallback to `/tmp`, by the data/ rule.

### 5.3 Framing and schema

- Frame: u32 little-endian length + UTF-8 JSON, at most 64 KiB, one object per frame.
- Every message has `v: 1` and `t`. Unknown `t` is ignored. A `v` mismatch closes the connection, and the client falls back to polling.

```
client → {"v":1,"t":"hello","role":"ask-hook"|"permit","pid":n,"ver":"<ChatVersion>"}
server → {"v":1,"t":"welcome","pid":n,"ver":"<ChatVersion>"}      (ver differs → client polls)
client → {"v":1,"t":"watch","kind":"ask"|"permit","id":"<rid or request id>"}
client → {"v":1,"t":"wrote","kind":"permit","id":"<rid>"}          (a req.json changed: look now)
server → {"v":1,"t":"ready","kind":"ask"|"permit","id":"…"}         (the answer file was written)
server → {"v":1,"t":"closing"}                                      (watcher exiting; client polls)
either → {"v":1,"t":"ping"} / {"v":1,"t":"pong"}                    (30 s keep-alive)
```

### 5.4 Trust boundary

- **Same user.** Trusted exactly as much as today: any such process can already write `D/`. IPC adds no capability beyond "wake up and read the file".
- **Other users and remote hosts.** Refused at the transport (DACL, `REJECT_REMOTE_CLIENTS`, peer uid).
- **The phone.** Only through MAC-checked sealed messages. The **acting process verifies the MAC itself**: a stub reads the sealed message from the answer file and verifies it with the phone key D. It never takes the watcher's or the pipe's word that a message was genuine. A compromised or impersonating watcher can therefore at most deny or delay, never forge an answer.
- **Mode cap.** [Test-ChatqAskGates](src/ask.ps1) is re-implemented in the stub as is, including the deferred limit "A mode switched at the PC while a question waits".

### 5.5 Stubs (outline; their own SPEC follows M7)

- `chatqd ask-hook` replaces the hook launch [Get-ChatqAskHookCommand](src/ask.ps1) emits.
  - Its request file and the **byte-equal digest and splice** must stay identical to the PS hook (DEFERRED.md "A lighter launcher for the ask hook").
  - The self-test runs both against the same fixtures and diffs the outputs, which is that deferral's own "to close" condition.
- `chatqd permit` replaces the MCP bridge [Get-ChatqPermitLaunch](src/permit.ps1) starts. It speaks MCP over stdio, keeps `MCP_TOOL_TIMEOUT` semantics (S35), and keeps [Get-ChatqPermitDigest](src/permit.ps1) (`b64url(SHA-256("chatq-permit\n" + rid + "\n" + tool + "\n" + inputRaw)[0..16])`).

### 5.6 Liveness predicate (a required PS change before any stub ships)

[Test-ChatqAskHookAlive](src/ask.ps1) requires a process matching `ProcessName '^(powershell|pwsh)$'` whose CIM command line contains `ask-hook.ps1`. For a native stub, it must also accept image name `chatqd` with a command line containing ` ask-hook `. The start-time window rule (within 2 min before the request, 5 s after) stays.

Better: the stub holds `D/ask/<rid>.lock` with share None for its life. Liveness is then `Test-ChatqLockHeld`, as for the watcher, with no CIM.

**Recommendation:** ship both. The lock is primary, and the process match is kept for PS hooks still in flight during the upgrade.

**Parent-name audit (before M5, not M8).** A Tier 0 check greps `src/` for process-name and parent-chain logic and asserts the list below. It fails on any new match, so a new name-keyed check cannot slip past the chatqd parent.

- [Test-ChatqAskHookAlive](src/ask.ps1): `powershell|pwsh`, the hook, not the watcher.
- [Get-ChatOverlayProcessChain](src/live-chats.ps1), [Get-ChatEntryHost](src/live-chats.ps1), [Test-ChatVsCodeOwned](src/live-chats.ps1), [Get-ChatParentProcess](src/live-chats.ps1): `Code( - Insiders)?`, `explorer`, start times.
- [Test-ChatqClaudeProcess](src/watcher.ps1): `claude|node`.

None keys on the watcher's own image. The chains walk up from a chat's CLI to VS Code or Explorer. A chatqd-spawned `claude -p` reaches `chatqd` and then whatever started chatqd, exactly where today it reaches `powershell` and then the same ancestor. The check therefore also runs `Test-ChatVsCodeOwned` and `Get-ChatEntryHost` against a fake chain with a `chatqd` link, and asserts today's answer.

---

## 6. Test strategy

### 6.1 Contract vectors (shared by both engines)

Location: `native/vectors/*.json`. A file is `{about, cases}`. A case is `{name, by?, input, expect}`, or `{name, by?, input, expectByEdition: {Desktop, Core}}` where Windows PowerShell 5.1 and pwsh 7 answer differently; chatqd follows its `--ps` flavour. `by` names the one PowerShell that can make an input (bytes its own `ConvertTo-Json` wrote); both still answer it.

**Generation.** Each file has a generator, `tests/vectors/<name>.ps1`, and nobody edits a file by hand; `launch.json`, the engine decision's table, is the one exception. `tests/vectors.ps1` loads the tool into a sandbox as the self-test does, with stand-ins for the clock, the zone and the culture, runs every generator through the engine in `tests/vectors/common.ps1` (whose header lists the rules a generator keeps), and compares each file with what the PS functions answer now. `-Write` writes them instead: a file takes one `-Write` under each PowerShell, which merges the two answers. The self-test section `tests/sections/native.ps1` runs it in check mode and **fails when PS output differs from the checked-in file**. So a PS change forces a vector update, and the Rust runners (`native/crates/chatq-core/tests/*_vectors.rs`, reading the same files through `tests/common/mod.rs`) then fail until Rust matches.

There are 20 files. Nineteen are made by PowerShell, each by `tests/vectors/<name>.ps1`; `launch.json` is the hand-written one. Each has its runner `chatq-core/tests/<name>_vectors.rs` (dashes as underscores).

| File | Pins |
|---|---|
| `stamps.json` | Two kinds of case. `stamp`: [Get-ChatqStamp](src/queue.ps1)'s and [Add-ChatqLogLine](src/queue.ps1)'s stamps of an instant in a zone, `{utc, local}` ([time::stamp_utc](native/crates/chatq-core/src/time.rs), [time::stamp_in](native/crates/chatq-core/src/time.rs)). `date`: [ConvertTo-ChatqDate](src/queue.ps1) of the `at` of a JSON file as [Read-ChatqJson](src/queue.ps1) reads it, as the UTC `o` of the instant, or null ([time::date_of_in](native/crates/chatq-core/src/time.rs)); every shape in §2.2, the dst cases included |
| `culture.json` | §2.11 strings under en-US, ko-KR, de-DE, fi-FI, hi-IN, tr-TR and nl-NL: the `--culture` argument [Get-ChatqWatcherLaunch](src/watcher.ps1) `-Native` builds, `HH:mm`, `HH:mm:ss`, `N0`, and [Format-ChatqLane](src/watcher.ps1) / [Format-ChatqProvider](src/watcher.ps1). tr-TR and nl-NL hold the lane title-casing cases (nl-NL's IJ, which only pwsh 7 title-cases as one letter) |
| `stream-state.json` | [Update-ChatqClaudeState](src/queue.ps1) / [Update-ChatqCodexState](src/queue.ps1) over fixture streams (real lines, scrubbed: init with and without `chatqpermit`, permission_denied, api_retry, rate_limit_event allowed/rejected, `<synthetic>` limit and overload, tool_use ids, result, the 1 MB+ line) → St in §3.8's transport; each answer rebuilt from that JSON in PS and compared with the real St |
| `jsonl.json` | §2.6 decoding, splitting and log bytes, per flavour. The log is stored as Windows writes it, CRLF after each line; a line past 256 code units is stored as `{units, sha256}`, a log past 512 bytes as `{length, sha256}` |
| `argline.json` | [ConvertTo-ChatqArgLine](src/queue.ps1) and [Get-ChatqCmdArgRefusal](src/queue.ps1), for an exe vs a `.cmd`/`.bat` target, on an adversarial corpus: quotes, trailing backslashes, `%`, `!`, `^`, `&`, spaces, empty, Unicode, lone surrogates, CVE-2024-24576 payloads; and the titles: `--name` for a fresh chat and the cmd title scrub (§2.6) |
| `env.json` | `$script:ChatqEnvDrop`, `$script:ChatqRunEnv`, the env a run gets from a given parent env and plan delta ([runenv::run_delta](native/crates/chatq-core/src/runenv.rs)), the block's sort order per edition |
| `launch.json` | Engine decision inputs (config, env, binary present/executable/verified, fuse states, pending/last records, OS) → engine and strikes. Hand-written: it is the table §4.2 decides by, run by both launchers |
| `watcher-launch.json` | [Get-ChatqWatcherLaunch](src/watcher.ps1)'s PowerShell branch, `{psExe, script, logDir, claude, codex}` → `{exe, args, command}`, the log path as Windows PowerShell's `Join-Path` makes it (§2.7) |
| `jobs-order.json` | [Get-ChatqJobs](src/queue.ps1) order for fixture queues, ties as each edition's unstable sort leaves them (§2.4); [Get-ChatqLane](src/watcher.ps1) |
| `due.json` | [Get-ChatqDueTime](src/watcher.ps1), [Update-ChatqBlock](src/watcher.ps1)'s skip rules |
| `gates.json` | [Test-ChatqHeldWaiting](src/phone-extras.ps1), the held pre-gate ([Send-ChatqHeldSummary](src/phone-extras.ps1)'s quiet hours and 5-minute retry wait, [gates::held_summary_due](native/crates/chatq-core/src/gates.rs)), [Test-ChatqAutoWanted](src/auto-continue.ps1), the [Send-ChatqUsageSoon](src/phone-extras.ps1) gate (fires or not, wake time, and the keys already in `usage-alerts.json`, [gates::soon_already_sent](native/crates/chatq-core/src/gates.rs)), the alert route (§1.4), [Test-ChatqReplyOpen](src/phone.ps1), [Get-ChatqReplyPollSeconds](src/phone-down.ps1), [Get-ChatqReplyListenText](src/phone-down.ps1) |
| `timers.json` | Fixed-clock pass sequences → which timers fire: auto and stray on pass 1 then 5 min/6 h, block per lane per 10 min, heartbeat 60 s, ask-landed at 20 s, the 30 s board/state rule, keep-awake, the run, each wait's length. This replaces, for chatqd, the source-text check of the auto scan in [tests/sections/auto-continue.ps1](tests/sections/auto-continue.ps1), which stays for the PS loop |
| `state.json` | [Save-ChatqWatchState](src/watcher.ps1) → [Restore-ChatqWatchState](src/watcher.ps1) round trips, both directions between engines |
| `reply-state.json` | [Use-ChatqReplyState](src/phone.ps1) and [Save-ChatqReplyState](src/phone.ps1): a file, the junk-only change or `lastPolledAt` alone, now and `reply.hours` → the file written (key set, every prune), or the throw and whether the file was left; and the files chatqd refuses to write back (§2.2) |
| `reply-triage.json` | §3.7: per message, stage, error text, candidate or junk, and the log lines with throttle state |
| `wire.json` | Keys and MACs for every inbound label, sealed by PS **and by the page's own code** ([tests/wire-vectors.js](tests/wire-vectors.js) emits them under node, which the generator needs); tampered MAC, wrong id, `len%4==1`, non-canonical trailing bits; `code(D)` |
| `json-compat.json` | Files as [Read-ChatqJson](src/queue.ps1) reads them under each edition, as bytes or text: files written by 5.1 and by pwsh 7 (escapes, one-element arrays, dates, depth, BOM, **lone surrogate escapes, invalid UTF-8**), the grammar each edition accepts beyond strict JSON, and text as [json::to_pretty](native/crates/chatq-core/src/json.rs) writes it → `{value, repaired}` (§2.2) |
| `board.json` | [Write-ChatqBoard](src/alerts.ps1)'s `queue.md` for fixture queues and states (not listening), under several cultures and zones. The answer is the file's lines, compared joined at [paths::NEWLINE](native/crates/chatq-core/src/paths.rs), so CRLF is checked on Windows; a JSON file, not golden `.md` files, which `.gitattributes` would normalise |
| `log.json` | [Add-ChatqLogLine](src/queue.ps1)'s line and its roll past 1,048,576 bytes; [Write-ChatqReplyLog](src/phone.ps1)'s line; the `alerts.log` line (§2.3) |
| `idle.json` | captured `ioreg -c IOHIDSystem` output → seconds, as the double's IEEE-754 bits in hex (§3.5) |

**The live checks** are the contracts no file can hold: DPAPI keys are this user's, and a zone's changes are this PC's. [tests/vectors/live.ps1](tests/vectors/live.ps1) makes its cases on the spot, takes this PowerShell's answers, and asks a real chatqd the same:

- **DPAPI.** What [Protect-ChatqSecret](src/alerts.ps1) seals opens to what [Unprotect-ChatqSecret](src/alerts.ps1) gives, and what PowerShell cannot open chatqd refuses. `chatqd vector dpapi <hex>` opens `{value: <hex>, protected: true}`: exit 0 with the text as UTF-8 and nothing after it (`''` is no bytes), exit 1 with nothing on stdout where PowerShell gives `$null`.
- **Local stamps.** Instants around this zone's changes, as `(Get-Date).ToString('o')` renders them, and those instants and wall-clock times as `ConvertTo-ChatqDate` reads them from JSON. `chatqd vector local-stamps --ps <exe> <stamp>...` answers one LF-ended line per stamp, an empty line for `$null`, exit 0; the checks ask 100 stamps to a run.
- A bad call is exit 64.

`tests/sections/native.ps1` runs them in this PC's zone whenever a chatqd is built. `tests/vectors.ps1 -Live <exe>` runs them alone, makes no vectors, works in a sandbox of its own (`tests/.sandbox/vectors-live-<edition>`) and exits with the number of failing checks. CI runs that under `Pacific Standard Time` and `Korea Standard Time`, a zone that keeps summer time and one that does not, with each PowerShell (§6.4).

### 6.2 What the PS self-test keeps testing

All of it. The PS watcher stays the fallback, and every step op is PS code. Existing sections such as [tests/sections/auto-continue.ps1](tests/sections/auto-continue.ps1) (its loop source check included), [tests/sections/phone.ps1](tests/sections/phone.ps1) and [tests/sections/permit.ps1](tests/sections/permit.ps1) are unchanged. M5a's refactor must leave them green with no edit to their assertions.

New in `tests/sections/native.ps1`:

1. **Vectors.** Regenerate and diff (always).
2. **Engine decision.** `Get-ChatqWatcherEngine` across config, env, missing or non-executable binary, preflight pass/fail, every strike kind, blown fuse and Linux, through the `$script:ChatqSpawn` seam (always).
3. **Step protocol**, in a section of its own, [tests/sections/native-step.ps1](tests/sections/native-step.ps1). `Invoke-ChatqNativeStep` for each op against fixtures, including:
   - the `state.json` pid seam and the runner pid seam;
   - parent-death self-termination (a fake parent pid that exits; a reused pid with a wrong start time);
   - the `$script:`/`$W`/`$PID` audit and round-trips (§3.6);
   - the `pick` catch line equal to the PS loop's;
   - the parent-name audit (§5.6), from M5: DEFERRED.md "The parent-name audit".
4. **The contract harness** (§6.5), when a chatqd binary is present (CI provides one).

### 6.3 Rust tests

- Unit tests per `chatq-core` module, plus the vector runners.
- `rx_sync.rs`: the two regexes equal `src/queue.ps1` (§2.9).
- `version_sync`: in `build.rs`, plus a test for readable failure text.
- **Stamp formatter**: 7 digits, padding, offsets.
- **Lock tests.** Two processes; on Windows a `share_mode(0)` holder vs an `Open(Open, ReadWrite, None)` prober written in PowerShell, invoked from the test only on Windows CI; on macOS a `flock` holder vs a pwsh `FileShare.None` prober (Tier 2 and the macOS CI leg).
- **Process tests** with `fake-cli` (M5; neither is built yet):
  - stream fixtures for done, limited, overloaded, auth, network and Codex `rate_limits`;
  - a `.cmd` wrapper around fake-cli for the batch path, asserting the exact `GetCommandLineW` the child saw;
  - the handle list (the child holds no handle to `watcher.lock`);
  - stdin larger than 1 MB;
  - stderr flood (memory stays flat; the spool holds it all);
  - a 1 MB+ stdout line; lone CR; invalid UTF-8; `.jsonl` bytes CRLF/LF and flush per line (a reader sees each line before the next is sent);
  - a tick count over 20 s, with ticks during a chattering stream;
  - deadline; cancel file; `D/stop` mid-run (`byStop`);
  - tree kill of a grandchild.
- **HTTP tests** (M3) against a local `std::net::TcpListener` fake ntfy: poll `since`, 429, a slow server versus the 5 s and 8 s timeouts, TLS off. The agent is dropped after each burst (connection count). These loopback servers are tests only, never in the product.
- `clippy -D warnings`, `rustfmt --check`, `cargo deny check`.

### 6.4 CI legs ([.github/workflows/test.yml](.github/workflows/test.yml))

The existing legs stay. Two Rust legs run beside them; every run step of both is inside `native/`, so rustup finds `rust-toolchain.toml` and cargo finds `.cargo/config.toml` (§3.1).

- **`native-windows`** (windows-latest), in this order:
  1. `rustup toolchain install` (the pinned 1.99.0);
  2. `cargo build --release --locked --target x86_64-pc-windows-msvc`, then upload of `chatqd.exe` as the artifact `chatqd-x86_64-pc-windows-msvc`. The build comes first so the PowerShell legs get an exe whatever a later step finds;
  3. `cargo fmt --all --check`;
  4. `cargo clippy --workspace --all-targets --locked -- -D warnings`;
  5. `cargo test --workspace --locked`;
  6. the live checks (§6.1) from the repo root: under `tzutil /s` `Pacific Standard Time`, then `Korea Standard Time`, each of `powershell` and `pwsh` runs `tests/vectors.ps1 -Live` on the release exe, and the step fails on the sum of their failing checks;
  7. `cargo deny check` (§3.4), cargo-deny installed by `taiki-e/install-action`.
- **`native-macos`** (macos-latest, Apple Silicon), in this order:
  1. `rustup toolchain install`, `rustup target add aarch64-apple-darwin x86_64-apple-darwin`, and Rosetta installed if the runner lacks it;
  2. fmt and clippy as above;
  3. `cargo test --workspace --locked` on arm64, then again with `--target x86_64-apple-darwin` under Rosetta;
  4. release builds of both Apple targets;
  5. `lipo -create` into `target/universal-apple-darwin/release/chatqd` and `lipo -archs`; **`codesign --force --sign -`, then `codesign --verify --strict --verbose=2`**; `chatqd version --root ..` run natively and under `arch -x86_64`;
  6. `chmod 0755` and a `.tar.gz` that keeps the mode, uploaded as the artifact `chatqd-universal-apple-darwin` (§4.7).
- The **existing Windows matrix legs** (`powershell`, `pwsh`) have `needs: native-windows` and run whether or not it passed (`if: !cancelled()`). They download its exe into `native/target/release/`, where `tests/sections/native.ps1` looks for a developer's build; if there is none, its checks of chatqd say so and skip. These legs stay in the runner's own zone, UTC.
- **`memory`** (planned, not yet built; windows-latest, after native-windows): start chatqd through the harness, waiting on a fake limit, listening to the fake ntfy that `CHATQ_NATIVE_SEAMS` points it at. After 60 s and 10 polls, assert private bytes ≤ 16 MB (soft; the real target check is Tier 1).
- The PS suite on macOS stays deferred (DEFERRED.md "CI on macOS and Linux"). Mac integration is Tier 2, plus the Rust-only macOS leg above.

[release.yml](.github/workflows/release.yml) calls this whole workflow before it makes the release assets (§4.7), and so does `publish.yml` on a tag.

### 6.5 Seams and the contract harness (new)

The PS tests reach about 40 in-process seams: `$script:ChatqReplyPollSeam`, `ChatqNtfySeam`, `ChatqJoinSeam`, `ChatqToastSeam`, `ChatqIdleSeam`, `ChatqDownSeam`, `ChatqFooterSeam`, `ChatqClockSeam`, `ChatqHeldKickSeam`, `ChatqExtHomeSeam`, `ChatqStatusUrl` (a file path allowed), `ChatqSpawn`, `ChatParentSeam`, `ChatqAliveSeam`, `ChatqAskAliveSeam`, `ChatqPermitExeSeam`, `ChatqHookTimeoutSec` and others. A separate process cannot reach them, so they cross by file.

- **The seams file.** `CHATQ_NATIVE_SEAMS=<path>`, a JSON object, read as pwsh 7 reads it (§2.2). Each honoured seam is logged to `chatqd.log`. The same path goes to every step (`-Seams`) and to a PS watcher chatqd starts. `src/native-step.ps1` maps each name onto `$script:` seam variables by the table below, before the op runs, and so does the harness's PS-watcher launch. The handover timings and process-table seams are therefore set inside steps exactly as the PS tests set them today. A name the table does not list is ignored.

  | Name | Value | chatqd itself (M2) | `$script:` variable a step sets |
  |---|---|---|---|
  | `capture` | a directory | with `spawn`, its own launch records | recorders that write a JSON file there instead of the call happening: [`ChatqToastSeam`](src/alerts.ps1) `{param($Title,$Text)}` → `toast-<n>.json` `{title, text}`; [`ChatqNtfySeam`](src/alerts.ps1) `{param($server,$body,$headers)}` → `ntfy-<n>.json` `{server, body, headers}`; [`ChatqJoinSeam`](src/alerts.ps1) `{param($url)}` → `join-<n>.json` `{url}`, returning `$null` (no error); [`ChatqDownSeam`](src/phone-down.ps1) `{param($Method,$Url,$Headers,$Body)}` → `down-<n>.json` `{method, url, headers, body}`, returning `$null`; [`ChatqLiveSendSeam`](src/phone.ps1) `{param($o)}` → `live-<n>.json` `{alert}` |
  | `spawn` | `true` (needs `capture`) | records its launches instead of starting them, as `ChatqSpawn` does: `<capture>/spawn-<n>.json` = `{engine, exe, args, cmdline, command, cwd}`, `command` being the decoded PS command for a PS launch and null for a native one | [`ChatqSpawn`](src/watcher.ps1) `{param($l)}` → `spawn-<n>.json` `{engine, exe, args, command}` from `$l`'s `Engine`, `Exe`, `Args` and `Command`, returning `$true` |
  | `clock` | an ISO stamp, or a number of seconds | M3: the quiet-hours check of the held summary is made at it (seconds counted from chatqd's start); every other gate and wait keeps the real clock | [`ChatqClockSeam`](src/phone-extras.ps1) = [ConvertTo-ChatqDate](src/queue.ps1) of the stamp, or `(Get-Date).AddSeconds(<n>)` at the step's start; [Get-ChatqNow](src/phone-extras.ps1) then gives it |
  | `statusUrl` | a URL, or a file path (anything not `^https?://`) | not used: no native status call in M2 | [`ChatqStatusUrl`](src/queue.ps1) |
  | `idleSeconds` | a number | not used in M2 | [`ChatqIdleSeam`](src/alerts.ps1) = `[double]<n>` |
  | `alive` | a bool | not used in M2 | [`ChatqAliveSeam`](src/live-chats.ps1) = `{ param($Entry) <bool> }` and [`ChatqAskAliveSeam`](src/ask.ps1) = `{ param($Req) <bool> }` |
  | `ntfyBase` | a base URL | M3: the poll's server when config names none, taken only for a loopback host (`chatqd.log` says when it is refused) | [`ChatqReplyServer`](src/phone.ps1), the reply server used when config names none. Publishes are captured anyway |
  | `joinBase` | | | none: Join's URL is a literal in [Get-ChatqJoinUrl](src/alerts.ps1), with no variable to set. Join calls are captured under `capture` instead |
  | `handoverOff` | a bool | | [`ChatHandoverOff`](src/core.ps1), so [Test-ChatqHandoverOn](src/watcher.ps1) says no and no step drives VS Code |
  | `panic` | a bool | M0 test only: the first pass panics, so §4.1 item 8's strike, `finally` and handoff are tested | none |
  | `connectForbidden` | a bool | M3: every poll's connect is refused as a firewall refuses it ([http::get_forbidden](native/crates/chatqd/src/http.rs), WSAEACCES through the same mapping), so the refused-connect handoff (§8 "Deliberate differences") is tested; nothing is sent anywhere | none: the PS watcher that takes over polls as usual |

  - `<n>` in a capture file name is the first number from 1 whose file does not exist, the file created with create-new, so chatqd and steps never share one.
  - Each record is written by `ConvertTo-Json -Depth 8` (chatqd: `serde_json`), so `body` and `headers` are as that serialises them.
  - M0's `hold` seam is gone: M2 waits for real, and its waits, `stop` and `wake` mid-wait are tested by the harness's own cases.
- **The harness** (`native.ps1` item 4). Each case is a fixture `D` plus a seams file plus a scripted event list: queue a job, touch `wake` with `now`, post to the fake ntfy, write a cancel file, advance the clock. Every case runs twice: once with the PS watcher (`Invoke-ChatqWatchLoop` in a child, seams applied) and once with chatqd. The comparison, with stamps and pids masked, covers:
  - `watcher.log`, `alerts.log`, `replies.log` and `jobs.log` line for line;
  - the job files and `state.json` semantically;
  - `queue.md` byte for byte;
  - the captured pushes, toasts and spawns.

  Cases:
  - lock interplay both ways: PS watcher holding → chatqd gives up after 5 tries, deletes its `pending.json` and leaves `last.json` as it was; chatqd holding → `Test-ChatqWatcherAlive` true and the PS loop gives up;
  - stop, restart and wake (`now` fresh vs stale, `seen` written);
  - empty-queue exit with the late-job and window rechecks;
  - post-exit respawn on an open reply window, and the respawn's engine after a simulated update (new loader version, binary present or absent);
  - handoff into PS, with state carried;
  - first-pass timers;
  - a full Claude job and a Codex job through `pick` (M2), and through `pre-run`/process/`post-run` (M5) with fake-cli: done, limited mid-run with prompt landed and not, network retry ×3, auth, overloaded with status-page outage and recovery, cancel, `byStop`, deadline;
  - a permission run: request sent, declined (not this run's, not seen within 10 s, digest changed, 20 an hour), answered, withdrawn, timed out, bridge failed to start;
  - phone replies: junk floods per stage, a genuine reply, replay, too old, expired, 20 uses, refusal push throttle, a compose look and change with their limits, a pairing answer, `unsaved` (replies.lock held by the harness), `MaxMessages` 10 and 2;
  - ask relay and landing (found, not taken, held back);
  - held summary and the usage soon/reset alerts;
  - fuse strikes: pending without ack, crash, preflight failure.

---

## 7. Milestones

Each milestone is shippable on its own, behind the engine switch, with `ps` the default until M7. Each lands in one versioned commit with CHANGELOG, README and TESTING.md updates.

### M0: Skeleton (build, lock, switch)

**Status.** Built, in ChatVersion 0.10.15. Tier 0 is the CI of §6.4 and `native.ps1`. Tier 1 is TESTING.md's S55; waiting under the `hold` seam, M0 measured 1.1 MB private, against the 4 MB target of §3.3. Tier 2 is open, since there is no Mac here: FUTURE_WORK.md "A native watcher's launch on a Mac".

**Delivers.**

- `native/` workspace; CI legs `native-windows`/`native-macos` (codesign verify included); release workflow ([release.yml](.github/workflows/release.yml), the unsigned dry run of §4.7).
- `chatqd watch` does:
  - lock (§4.3), pid, start/stop log lines, the acks;
  - `stop`, `restart`, `wake` (mtime, `now` freshness, `seen`);
  - [Restore-ChatqWatchState](src/watcher.ps1) and [Save-ChatqWatchState](src/watcher.ps1);
  - keep-awake;
  - [Wait-ChatqUntil](src/watcher.ps1);
  - empty-queue exit with both rechecks;
  - the post-exit respawn with the native decision (§4.2).
- **Handoff to the PS watcher** (§4.4) once start-up's own writes are done (pid, `started` line, restore) and the first pass's `stop` and `restart` checks have passed, before that pass writes anything else, when any of these holds:
  - a job is queued (a fresh `now` in `D/wake` is then left unread, §1.1 wake row);
  - [Test-ChatqReplyOpen](src/phone.ps1) is true;
  - the repair is due (§1.1 repair row: a `running` job, `D/permit/` leftovers, `D/ask/*.req.json`);
  - [Test-ChatqHeldWaiting](src/phone-extras.ps1) or [Test-ChatqAutoWanted](src/auto-continue.ps1) is true, or `D/queue` may hold a stray file (§1.1 rows), since the PS first pass would act on them;
  - the board would be anything but the trivial one (§1.1 empty-queue row).
- **So M0 never waits in real use**: every pass either hands off or exits. Its wait, keep-awake, and `stop`/`wake` while waiting are reached only through the `hold` seam (§6.5), and Tier 1 steps 4 and 5 run under it. TESTING.md says the memory figure was taken under `hold`; the wait loop is the same code M2 waits in.
- PS side: `Get-ChatqWatcherEngine`; [Get-ChatqWatcherLaunch](src/watcher.ps1) native branch with `--culture`; preflight, pending/ack, the fuse.
- `install.ps1` and `chatinstall` are unchanged: binaries come only from a dev build or `CHATQ_CHATQD`.

**Check.**

- **Tier 0.** `cargo test`; `native.ps1` items 1 (stamps, launch, state), 2 and the harness's lock, flag, empty-exit, respawn and handoff cases.
- **Tier 1, this PC.**
  1. Build chatqd into `bin/<version>/<target>/`; no setting needed.
  2. With an empty queue, `chatq` starts chatqd: `queue empty` and stopped in `watcher.log`, lock released, `last.json` `empty`.
  3. Queue a job: `chatqd.log` shows the handoff, the PS watcher logs `carrying on…` and runs it.
  4. `chatqrun -Stop` while chatqd waits under the `hold` seam.
  5. Measure chatqd private bytes while it waits under the `hold` seam, with `wake` poked meanwhile; record it in TESTING.md as taken under the seam.
  6. Kill chatqd with Task Manager: the next shell's auto-start records one crash strike, starts a watcher, and the decision still says native.
  7. Rename the exe's folder mid-session: the next launch's decision says PS.
- **Tier 2.** Build, sign and run the lock test on a Mac.

### M1: Contract core and vectors (no behaviour change)

**Status.** Done, in ChatVersion 0.10.15: `chatq-core` as §3.1 lists it, the 20 vector files of §6.1 with a Rust runner each, and the live checks. Where a later milestone's duty is not reachable from a vector, FUTURE_WORK.md "The rest of the tool in Rust" names the check that milestone must add.

**Delivers.** All of `chatq-core` (§3.1) and all vector files (§6.1) with both runners. Engine behaviour is unchanged.

**Check.** Tier 0 only: vectors green on both CI hosts and on macOS (Rust side).

### M2: Native loop, PowerShell steps

**Status.** Built, in ChatVersion 0.10.16, to the step contract of §2.4, §3.6, §4.4, §6.5 and §8 "M2 contract notes". Tier 0 passes: `cargo test` (with `timers.json` replayed through the loop) and both PowerShells' self-test, the twin run included. Tier 1 is TESTING.md's S57, not yet run, so the memory while waiting and the steps an hour are not measured yet. Tier 2 is S57 on a Mac, after M0's. The parent-name audit waits for M5 (DEFERRED.md "The parent-name audit"), and the listening cases of `timers.json` for M3 (FUTURE_WORK.md "The rest of the tool in Rust").

**Delivers.**

- chatqd runs the whole [Invoke-ChatqWatchLoop](src/watcher.ps1) control flow itself:
  - job listing and order;
  - [Get-ChatqDueTime](src/watcher.ps1);
  - `-Now` job writes;
  - the native gates (held, ask-landed, auto, block rule, usage soon, reply open);
  - the first-pass and interval timers;
  - [Write-ChatqBoard](src/alerts.ps1) natively when not listening;
  - the per-pick error path through `Invoke-ChatqPick`.
- Through steps: `repair`, `block`, `pick`, `auto`, `stray`, `soon`, `held`, `ask-landed`, `alert`, `job-write`.
- No handoff for queued jobs any more. An open reply window still handed off in M2, carrying `W` and the caches through `handoff.json` (§4.4); from M3 chatqd listens itself.
- PS side:
  - `Invoke-ChatqNativeStep`, `src/native-step.ps1`, `Invoke-ChatqPick` (the loop now calls it too);
  - the `state.json` pid seam and `Get-ChatqRunnerPid`;
  - the parent check in `Invoke-ChatqProcess`'s `$check`;
  - the carry codecs; the audit test.

**Check.**

- **Tier 0.** `native.ps1` item 3 and the harness's job cases through `pick`; the board goldens; `timers.json`, both ways: [chatq-core/tests/timers_vectors.rs](native/crates/chatq-core/tests/timers_vectors.rs) and chatqd's [timers_replay](native/crates/chatqd/src/watch/timers_replay.rs) through the real loop, a case whose reply window opens checked up to its handoff in M2, and whole from M3; `gates.json`.
- **Tier 1.**
  - A real Claude job and a real Codex job queued behind a real limit overnight. `watcher.log` diffs clean against a PS night by the harness's masking.
  - `chatqrun -Now` mid-wait.
  - Kill chatqd mid-run: the step ends itself within 5 s, the CLI finishes or orphans, and the next watcher logs `interrupted`.
  - Memory while waiting; step count and peak per hour, recorded.
- **Tier 2.** On a Mac: a job picked through a step under `pwsh`, the step's reading of chatqd's start (`proc_pidinfo`) equal to `-WatcherStart`, and a step whose chatqd is killed ending itself.

### M3: Native listening

**Status.** Built, in ChatVersion 0.10.21, to §3.6, §3.7 and §8. Tier 0 passes: `cargo test` (`timers.json`'s listening cases replayed whole, `wire.json`, `reply-triage.json`, `reply-state.json`) and both PowerShells' self-test, the twin listening and pairing runs included. Tier 1 is TESTING.md's S59, its memory step [tests/m3/run-5b.ps1](tests/m3/run-5b.ps1) run for an hour on 2026-10-22: 2.58 MB private at the gate (§3.3); the day, steps 2-8, not yet run. Tier 2 is S59 on a Mac, not run (DEFERRED.md, "M3 on macOS").

**Delivers.**

- [Get-ChatqReplyPollSeconds](src/phone-down.ps1), the native poll, triage and junk path, `replystate.rs` (§3.7).
- The listening branch (`listening for phone replies …`, `replies closed`), and the `board` step while listening.
- The `reply` step.
- PS side: [Invoke-ChatqReplyPoll](src/phone.ps1) gains the given-lines seam, so the step runs its body unchanged.
- No handoff remains except on panic, and where the system refuses chatqd the poll's connect (a firewall; §8 "Deliberate differences").

**Check.**

- **Tier 0.** `wire.json`, `reply-triage.json`, `reply-state.json`; the harness's phone cases.
- **Tier 1.**
  - `reply.listen always` for a day: memory sampled hourly, against §3.3's re-based target.
  - A board request, a requeue and an ask answer from a real phone.
  - Junk posted to the topic is logged with throttling and spawns no step.
  - A pairing from the setup window.
- **Tier 2.** The S44 listening checklist on a Mac.

### M4: Native lane gate

**Delivers.**

- [Confirm-ChatqAllowed](src/watcher.ps1)'s state machine natively:
  - `lane|model` keys and the 3 min reuse;
  - `<lane> back after N min`, `<lane> allowed`, `<lane> still limited until HH:mm<from>`;
  - refused → fail; the probe-fail backoff with the 3rd-strike alert;
  - the outage machine with [Get-ChatqClaudeStatus](src/queue.ps1) (system proxy; file seam);
  - the 6 h reminder; the login block.
- Through steps, for good: `probe` (Claude `-p` probe and Codex app-server plus exec probe, CLI discovery and the version cache inside), `block`.
- Through steps until M6: `usage-reset`, `auto-outage`, the alerts.
- PS side: `Get-ChatqLaneProbe` refactored out of Confirm-ChatqAllowed, and called by it, with no change in behaviour.

**Check.**

- **Tier 0.** `due.json`, the harness's limited/overloaded/auth/probe-fail cases with fake CLIs and a status file.
- **Tier 1.** The probe spikes against the real CLIs: limited, allowed, logged out by renaming the credentials, offline by disabling the network; a Codex account at 100% answered by the app-server with no turn; a status-page outage simulated through the seams file.

### M5: Native runs

**Delivers.**

- **M5a (PS only):** the four-function split of §3.8. The PS watcher uses it. Suite green, no assertion edited.
- **M5b:**
  - chatqd's process runner (§2.6), `stream.rs`, the mid-run tick with the heartbeat, the permission gate, the in-run poll, ask-landed, `byStop`, cancel and the deadline;
  - the `pre-run`, `run-started`, `permit-tick`, `post-run` and `run-ps` steps.
- The permit bridge stays PS, launched by `claude` from `pre-run`'s `mcp.json`.

**Check.**

- **Tier 0.** `argline.json`, `env.json`, `jsonl.json`, `stream-state.json` with the replay check; fake-cli including `.cmd`; `GetCommandLineW` byte equality with a PS-launched run of the same job; the harness's run and permission cases; the parent-name audit.
- **Tier 1.**
  - Real runs: a fresh chat, resume, attachments, Ultracode carry, `--effort`, a permit run answered from the phone, a permit request left to time out, cancel mid-run, `chatqrun -Stop` mid-run, an npm `claude.cmd` with a hostile title, the extension's live tail of the `.jsonl` during a run.
  - S35/S45/S46/S51 as TESTING.md lists them.
  - Peak and idle memory during an hour-long run.

### M6: Native alerts

**Delivers.**

- For alerts that do not register (§1.4): `alerts.log`, toast (WinRT on a worker thread, falling back to the `toast` step), osascript, ntfy, Join.
- Presence, events, quiet hours, holds, the footer, the held summary, usage soon/reset.
- The `command` channel is spawned directly with `--ps`.
- Answerable alerts still go whole through an `alert` step.

**Check.**

- **Tier 0.** A seam-based alert vector: given config and event, the route, which channels fire and with what payload, compared with [Send-ChatqAlert](src/alerts.ps1)'s captures in the harness.
- **Tier 1.** A toast shows under the "Windows PowerShell" source; a Tasker/Join phone push; a quiet-hours hold and summary; memory after a toast.
- **Tier 2.** The phone channels on the real phone, the S52 checklist.

### M7: Remainder and default flip

**Delivers.**

- [Clear-ChatqStrayFiles](src/queue.ps1) natively.
- Auto-continue scan natively, or kept as a step if its 5-minute cost measures under 1% CPU. Measure, then decide.
- Default engine `native`; signed releases; `install.ps1`/`chatinstall`/extension distribution in §4.7's order, with chmod and re-sign.
- PS watcher kept as the fallback.

**Check.**

- **Tier 0.** Full suite on both hosts with the binary present, and with it absent (fallback).
- **Tier 1.** A week's soak on this PC: daily memory, `watcher.log` diff review, no fuse strikes other than deliberate ones.
- **Tier 2.** A fresh install on a second Windows PC and on a Mac from `install.ps1`; an extension install on each; an update across versions while a job waits.

### M8: Stubs (ask hook, permit bridge) and IPC

As §5, with its own SPEC. This includes the liveness predicate change and the byte-equal digest test that closes DEFERRED.md "A lighter launcher for the ask hook".

### M9: Overlay

Out of this SPEC's scope. Its spike ran 2026-10-20 (TESTING.md S58); what it found that binds M9's design is in §8 "The M9 spike".

#### M9: the overlay's snapshot

M9a keeps the PowerShell host and draws its panel in a Rust process of its own (`native/overlay/`). The host is [Start-ChatOverlayHeadlessHost](src/overlay-host.ps1): the lock, `overlay.pid`, the collector, the restarts and every verb that changes state stay in it. The panel only reads and asks.

- **The snapshot.** `data/overlay.json`, as [Invoke-ChatOverlayCycle](src/overlay-data.ps1) writes it for every host: `{schema: 1, version, pid, at, header, counts, config, commands, rows, recent, recentMore}`, `ConvertTo-Json -Depth 6 -Compress`, written when it changed and at least every 10 s. `pid` is the host's; no reader uses it. A value nested past depth 6 is written as its .NET name (`"@{...}"`, `"System.Collections.Hashtable"`): the reader ([snapshot::parse](native/overlay/src/snapshot.rs)) names each such path, and the sandbox's own snapshot is checked to hold none (tests/sections/overlay-host.ps1).
- **The headless host's additions,** present only when the context holds `Events`, so the WPF and macOS hosts' snapshots are unchanged:
  - `ui: {spin, console, closing, script, claudeHome, tabs}` — `spin` a usage read under way (`Ctx.Fetch`, `CopilotFetch`, `CodexFetch`), the refresh spinner WPF reads from its context today; `console` while the console's process says it shows, and from an `-Open console` start until that process first says how it is (`Ctx.PanelConsole`, set from [Update-ChatOverlayConsoleChild](src/overlay-host.ps1)), and `closing` while a close by hand is on its way (`Ctx.PanelClosing`), the panel hidden for either ([App.want_shown](native/overlay/src/app.rs)) and its words for them the host's ([App.act](native/overlay/src/app.rs)); `script` and `claudeHome` what an open's child is started with ([open.command](native/overlay/src/open.rs)); `tabs`, `{sessionId, window}` for each open VS Code tab, the window a raise by name looks for ([App.start_raise](native/overlay/src/app/opening.rs));
  - `events: [{id, at, kind, ...}]` — the one-shot news. `id` is `<host start ms>-<n>`, so a new host never repeats an old id ([Add-ChatOverlayEvent](src/overlay-host.ps1)). Two kinds: `balloon` `{title, text, ms, icon, click, keys}`, from [Show-ChatOverlayBalloon](src/overlay-host.ps1) (`click` is the balloon's kind: `ask`, `memory`, `leak` or empty); and `said` `{said, text, tone, ms, about}`, the outcome of a panel's verb, the said marker WPF draws in its own window ([Add-ChatOverlaySaid](src/overlay-host.ps1)): `said` is the marker's kind (`done`, `delete`, `reload`), `tone` `dim` or `warn`, `ms` how long it stays, `about` the key of the row it is about (`reload:<pid>` for a reload ask). The panel shows every event, oldest first, one at a time, each for its `ms` (6 s when it has none), and only then lists it as seen ([ui::Hold](native/overlay/src/ui.rs)), so none goes unshown. The list is kept in `data/overlay-events.json` across a restart and drops an event once the panel has seen it, or after 10 minutes ([Update-ChatOverlayEvents](src/overlay-host.ps1)).
- **The panel's word back,** `data/overlay-ui.json`: `{at, underWay, seen, done, rect}`, `at` in epoch ms, written whole through a rename ([ui.save](native/overlay/src/ui.rs)). `seen` lists the event ids it has shown - a said once its time is out or another said has taken its place ([App.put_said](native/overlay/src/app.rs)), so a panel started again shows it again whole; `done` the ids of the snapshot's `commands` it has carried out, which the host then drops from them ([Update-ChatOverlayCommands](src/overlay-host.ps1)), so a panel started in its place carries out the rest and none twice; `rect` is the panel's place in screen pixels, which the console grows from. `underWay` holds the code-change and memory restarts off, the plan's "drag, picker, pointer in": the panel says it while the pointer is on it or a press is held there, a drag of the panel or an edge, the settings box open, an opacity or row count not yet sent, a full screen it stepped aside for, or an open under way ([App.under_way](native/overlay/src/app.rs)). It counts only while `at` is under 10 s old ([Test-ChatOverlayUiUnderWay](src/overlay-host.ps1)), so a hung panel holds nothing off for good. The host adds its own: a close by hand on its way, and the console's process's own under way, read from `console-ui.json` (below), or that process starting, 20 s at most ([Update-ChatOverlayConsoleChild](src/overlay-host.ps1), in [Start-ChatOverlayHeadlessHost](src/overlay-host.ps1)).
- **The console's word back,** `data/console-ui.json`: `{pid, at, shown, underWay, events, request}`, `at` in epoch ms, written whole by the console's process each pass and by its window's 3 s timer, so `at` stays new through its own modal loops, the folder picker and a drag ([Save-ChatConsoleUi](src/overlay-windows.ps1)). `pid` is the console process's own; the host reads only the one it started ([Read-ChatConsoleUi](src/overlay-host.ps1), [Update-ChatOverlayConsoleChild](src/overlay-host.ps1)). `shown`: its window shows as the console. `underWay`: as the panel's, from [Test-ChatOverlayUnderWay](src/overlay-windows.ps1), so it holds while the console shows at all; it counts only while `at` is under 10 s old ([Test-ChatOverlayUiUnderWay](src/overlay-host.ps1)). `events`: its balloons and said markers, under 10 minutes old, which the host takes once each by id as its own ([Add-ChatOverlayEvent](src/overlay-host.ps1)) for the panel to show; the console's process never writes `overlay-events.json` ([Save-ChatOverlayEvents](src/overlay-host.ps1)). `request`: `{alive, spawned, at}`, the watcher its answer to the reset ask started, which the host then follows as its own ([Update-ChatOverlayAsk](src/overlay-host.ps1)), once by its `at`; the console keeps it in the file as long as it runs. The host keeps the ids it took 15 minutes and never takes an event or a request older than that, so neither is taken again once its id is let go. A process that ends writes `shown` false last.
- **Verbs.** The panel writes `overlay-cmd` lines as every host's panel does ([Send-ChatOverlayCommand](src/overlay-data.ps1)): `<utc time> <verb>[ <words>]`. `close`, `phone`, `crash-on`, `crash-off`, `console`, `console-key`, `console-back`, `console-ui` and `hotkey` are the headless host's own ([Invoke-ChatOverlayCycle](src/overlay-data.ps1)): it acts on them and leaves them out of `commands`. `console-ui` is the console's process's wake: written when what its `console-ui.json` says changed (shown, its events, its request), it carries no words and does nothing but start the host's next pass at once, which reads the file. The console's verbs go to that process as lines on its stdin ([Send-ChatConsoleLine](src/overlay-host.ps1)): `console` as `show`, `console-key` as `key`, which the process decides, since only it can see whether its window has the keyboard ([Invoke-ChatConsoleLine](src/overlay-windows.ps1)); `console-back`, `close`, and the shell's `lock`, `unlock`, `toggle`, `hide`, `collapse`, `expand` and `reset` as `back`; a `reload` or `config` verb as `reload`; an answer to the reset ask as `answer` or `answer stale`. The shell's `hotkey` takes the console back to the panel while it shows; otherwise the host puts it in `commands` for the panel, as it does a show and expand of its own ([Send-ChatOverlayPanelVerb](src/overlay-host.ps1)). A verb's words are read whole and checked against that verb ([Test-ChatOverlayVerbArg](src/overlay-data.ps1)); a line whose words do not fit is dropped, and a verb that takes none drops any. A key is a row's (`s:<id>`, `c:<id>`, `j:<id>`, `recent:<id>`), `[0-9A-Za-z_.:-]{1,400}`, compared case and all:
  - `ask-go [k1,k2...]`, `ask-leave [...]` — the reset ask, as the macOS menu sends it;
  - `opened <key> <exit>` — the panel's open child ended so: the unread dot goes on 0, 25, 40 and 41, the tray's words for the code become a balloon ([Get-ChatOverlayOpenBalloon](src/overlay-host.ps1)), the said marker [Get-ChatOverlayOpenSay](src/overlay-host.ps1)'s;
  - `delete <key>` — the panel asked "sure?" first; the chat deleted as the WPF chip does ([Remove-ChatOverlayRow](src/overlay-host.ps1)), unless its row has gone or cannot be ([Test-ChatOverlayRowDeletable](src/overlay-host.ps1)), which is said as a warning;
  - `reload-answer <pid>:<id> reload|later` — a VS Code window's reload ask answered (`Write-ChatReloadAnswer`) and its banner left out until the window has taken it;
  - `card <key>` — the row's hover card written to `data/card.json` `{key, at, model}` ([Get-ChatOverlayCardModel](src/overlay-data.ps1)'s model, `null` for a row not there), nothing said. The card's words and a notice row's card, which WPF makes in its own part ([Get-ChatOverlayCardWords](src/overlay-windows.ps1), [Get-ChatOverlayNoticeModel](src/overlay-windows.ps1)), are the panel's to make from the row and the model.

  They are carried out by [Invoke-ChatOverlayPanelVerb](src/overlay-host.ps1), never put in any host's `commands`, and each that says something sets `Ctx.PassNow`, which starts the next pass at once ([Invoke-ChatOverlayCollectLoop](src/overlay-data.ps1)) for the panel to draw the outcome.
- **State.** `overlay-state.json` is the panel's while it runs. The host writes the close by hand (`Set-ChatOverlayClosed`) only after the panel has exited, from the file as the panel left it.
- **The wake.** The headless host's collect loop runs with `-WakeMs 250` ([Invoke-ChatOverlayCollectLoop](src/overlay-data.ps1)): a command that comes in between passes starts the next pass at once, not after the 2 s interval.
- **Start and quit.** The host starts `chatq-overlay.exe "<data folder>" --since <ms>` with no window and its stdin a pipe ([Start-ChatOverlayUi](src/overlay-host.ps1)). Closing that pipe is the quit ([Stop-ChatOverlayUi](src/overlay-host.ps1); a kill after 5 s), and the host's death closes it too. As a backstop the panel quits after 20 s with no new snapshot. A panel that exits unasked is started again: three starts in 10 minutes at most, the first and two restarts, and its exit after the third ends the host (`panel`), which blows the panel's fuse and starts the WPF host (`0.11.1`, below); each is given the first one's `--since` (`UiSince`), so a command sent while a panel was down is carried out by the next. The headless launch ([Get-ChatOverlayLaunch](src/overlay.ps1) `-UiExe`) loads only the collector's parts, `CHATQ_OVERLAY` without `CHATQ_ALLPARTS`: no overlay-windows, console or overlay-mac, and none load later: the console is a process of its own (below). A restart onto new code finds the new code's panel: an exe staged under `bin/<version>/x86_64-pc-windows-msvc/` beside the script follows the code's version, the loader's on disk, as [Get-ChatOverlayPanelExe](src/overlay.ps1) reads it ([Resolve-ChatOverlayUiExe](src/overlay-host.ps1)); a version with none staged gets the WPF host, as a fresh start does, never the old version's exe - and a headless host started for such a version hands over to the WPF host before it takes the lock; any other path is kept. A restart starts the panel `data/config.json` asks for then: the same exe while `overlay.panel` is `native`, the WPF host once it is not; and the console `-Open` asked for, when the first pass ended the host before it was opened.
- **The console's process.** The WPF console, in a Windows PowerShell `-STA` of its own, started by the host as the console is asked for ([Start-ChatConsoleProcess](src/overlay-host.ps1)): [Get-ChatOverlayLaunch](src/overlay.ps1) `-Console -HostPid <pid> -ConsoleOpen show|key` runs [Start-ChatConsoleHost](src/overlay-windows.ps1) with `CHATQ_OVERLAY` and `CHATQ_ALLPARTS`, every part loaded, its stdin a pipe the host holds, sharing the host's hidden console window, and no `STARTF_USESHOWWINDOW`, so its own window shows as it asks. `data/console.lock` keeps it to one. Before each show it is sent, and as it starts, the host calls `AllowSetForegroundWindow` for its pid ([Grant-ChatConsoleFront](src/overlay-host.ps1)), not under `CHATQ_NOFRONT`; the panel's own grant to the host is unchanged (DEFERRED.md "The foreground grant from the overlay"). Its context is its own: `-Peek` passes, so it takes no command and saves no `overlay.json`; `NoFetch`, so it asks no usage endpoint and shows what its host last saved ([Restore-ChatOverlayUsage](src/overlay-data.ps1), [Update-ChatOverlayUsage](src/overlay-data.ps1)); `WantAuto` off, auto-continue left to its host; `Events` none. A setting it saves sends `reload`, for the host and the panel to read the config again ([Save-ChatOverlaySetting](src/overlay-windows.ps1)). It reads its stdin off the window's thread ([Receive-ChatConsoleLine](src/overlay-windows.ps1)), and a line coming in ends the wait between its passes ([Wait-ChatOverlayHeadlessConsole](src/overlay-windows.ps1) `-Wake`, [Test-ChatConsoleLine](src/overlay-windows.ps1)). It ends once its console has gone back to the panel and `$script:ChatConsoleKeepMinutes` are up, 0, so at once; once its stdin ends - the host closing it ([Stop-ChatConsoleProcess](src/overlay-host.ps1), a kill after 3 s) or dying; or once `-HostPid` is gone, looked for every 5 s. The host lets a process that has ended go, and starts it again once if a show it sent was never seen (`ConWant`); the panel stays hidden from an `-Open console` start's first snapshot until the process first writes `console-ui.json` (`ConHold`), so it does not flicker on during the cold start. Its `shown` counts only while its `at` is under 30 s old ([Update-ChatOverlayConsoleChild](src/overlay-host.ps1)) - its window's 3 s timer keeps it new through its own loops - so a hung console does not keep the panel hidden. A host that ends, a restart among its ends, closes the console: a starting or shown console holds the code-change and memory restarts off, as the panel's under way does. The WPF host's console is unchanged: a window of the WPF host's own process.
- **Logs.** The panel logs its memory and its own words to `data/logs/overlay-panel.log` once a minute, the spike's modes to `data/spike.log` beside the exe every 10 s; each rolls to one `.1` copy past 1 MB ([selflog](native/overlay/src/selflog.rs)).
- **Vectors.** `native/vectors/overlay-snapshot.json` holds each PowerShell's text for five snapshots and what a reader takes from it; `native/vectors/overlay-clock.json` the reset and tooltip words a panel must say as the host does ([Format-ChatOverlayReset](src/overlay-data.ps1), [Format-ChatOverlayResetAt](src/overlay-data.ps1), [Get-ChatOverlayResetWindow](src/overlay-data.ps1), [Format-ChatOverlayTooltip](src/overlay-data.ps1)). The panel's own port of those four is held to it by `cargo test` ([clock](native/overlay/src/clock.rs), its test `every_clock_case_says_what_powershell_said`), each case's wall clock read in the case's own time zone. `native/vectors/overlay-panel.json` holds the WPF panel's rules the Slint one ports, a `kind` per function (what a chip offers and when, where the chip, the card and the bar go, the rows an edge's drag counts, a marker's and the folded line's words, a row's clock, the hotkey, the window an open brings forward), held to by [model](native/overlay/src/model.rs)'s `every_panel_case_answers_as_powershell_did`.
- **Decided for M9a (2026-10-21),** the plan's open points as the main session settled them: overlay-host is part 27 of the tool, with no gate of its own; `overlay-ui.json` and `overlay-events.json` are kept as above; stdin's close is the panel's quit; the verbs only the headless host takes stay its own; and `-UiExe` is opt-in at 0.11.0, the WPF host still the default. The opt-in is `overlay.panel` `native` (`charlie -Panel native`, [Get-ChatOverlayConfig](src/overlay-data.ps1)): [Start-ChatOverlayProcess](src/overlay.ps1) then starts the headless host on `chatq-overlay.exe` from `bin/<version>/x86_64-pc-windows-msvc/` beside the script, the version the loader on disk says ([Get-ChatOverlayPanelExe](src/overlay.ps1)), and on the WPF host, with one `overlay.log` line, while none is staged. test.yml builds it beside chatqd and release.yml packs it as `chatq-overlay-<v>-x86_64-pc-windows-msvc.zip`. **`0.11.1` (2026-10-22) makes it the default:** absent `overlay.panel` reads `native`, an explicit `ps` stays the WPF host, and a user who never chose moves on update with nothing said ([Get-ChatOverlayConfig](src/overlay-data.ps1) `panelChosen`); a missing exe is said in `overlay.log` only where `native` is chosen. The VSIX ships the exe (§4.7). **The panel's fuse:** an exe whose start throws, or the third exit in 10 minutes, blows `data/native/panel-fuse.json` for the loader's version ([Set-ChatOverlayPanelFuse](src/overlay.ps1), from [Start-ChatOverlayHeadlessHost](src/overlay-host.ps1)), logged with `-Always`; the host then starts the WPF host with no exe looked for ([Start-ChatOverlayProcess](src/overlay.ps1) `-Wpf`), which says it once in its tray ([Show-ChatOverlayPanelFuseNotice](src/overlay.ps1)). [Get-ChatOverlayPanelExe](src/overlay.ps1) gives '' while the fuse names this version; a new version, or `charlie -Panel native` ([Clear-ChatOverlayPanelFuse](src/overlay.ps1), and a restart of a running overlay), tries native again. A panel that hangs without exiting is not caught (DEFERRED.md "A panel that hangs without exiting").
- **Decided for M9b, step 1 (0.11.6, 2026-10-23),** by the user from TESTING.md S62's automatic run (`data/s62/auto.json` of its clone): the native panel's console leaves the headless host for a process of its own, started on demand, and **closes with its window** (`$script:ChatConsoleKeepMinutes` = 0, [Start-ChatConsoleHost](src/overlay-windows.ps1)). The measured headless host, settled 60 s with no console parts, is **130.8 MB private** (130.6 in the spawn run); the console loaded into it, as 0.11.1 did, held 242.2 MB open 10 s and 239.0 MB 30 s after back, its ~111 MB kept until a restart. With the console a process of its own, the host held 140.8 MB and 137.9 MB, and the console's process 261.8 MB open and 258.5 MB hidden. A cold start, spawn to first frame, took 2.08 to 2.19 s over six runs (2.14 the first; runs 2-6 median 2.16, at most 2.19), its lists filled at 2.66 to 2.79 s (median 2.78), against 1.07 s for the in-host first open and 0.19 s warm; from the host, click to frame 2.31 s. S62's own rule (cold median at most 2.0 s for a close on exit) said keep it warm 15 minutes; the user overrode that, since a warm process holds some 258 MB for 15 minutes after each use, more than the in-host console's 111. The warm keep stays one constant at 0. The host's `AllowSetForegroundWindow(child)` returned true (`lastError` 0), and S62's hand step, over a remote desktop, saw the console come to the front on the click, the tray and `chatconsole`, even where the host's grant failed, so the panel needs no `ASFW_ANY` and is unchanged; the hotkey is still to try at the PC. The console in Slint is open work (FUTURE_WORK.md "The console in Slint").

#### M9a: the native panel's parity with the WPF one

The Slint panel is [App](native/overlay/src/app.rs) with its pointer ([pointer](native/overlay/src/app/pointer.rs)) and open flow ([opening](native/overlay/src/app/opening.rs)), on the spike's parts. The host starts it with `--since <ms>`, its first panel's start, so a command older than the panel is never carried out twice, and one a panel says it has done (`done`) goes from the list ([Start-ChatOverlayUi](src/overlay-host.ps1), [Update-ChatOverlayCommands](src/overlay-host.ps1)). Its new words to the host are `opened <key> <exit> <look>` / `opened <key> behind|late|nostart`, `config opacity|maxRows|theme|recent <v>` and `auto-chip <key> dont|continue`, carried out by [Invoke-ChatOverlayPanelVerb](src/overlay-host.ps1) and checked by [Test-ChatOverlayVerbArg](src/overlay-data.ps1), and `console`, `console-key` and `console-back`, the headless host's own. What holds between the two is [App.tick](native/overlay/src/app.rs), [App.commands](native/overlay/src/app.rs) and [ui](native/overlay/src/ui.rs): the last good snapshot held until it is stale, a command from before `--since` left, every event shown before it is listed as seen. It is tested by [the_last_good_snapshot_is_held_until_stale](native/overlay/src/ui.rs), [every_event_is_shown_before_it_is_seen](native/overlay/src/ui.rs), [a_said_is_never_on_show](native/overlay/src/ui.rs) and [seen_follows_the_hosts_events](native/overlay/src/ui.rs), and by the loopback's 'started' and 'stdin closed'.

Each inventory item of m9-features.md has a row: where it is, and what tests it. "Host" is the PowerShell host every panel shares; the native panel draws what the snapshot says of it. A test is named as it runs:

- **Goldens:** the software renderer's PNGs against `native/overlay/goldens`, by their `golden_*` test.
- **Loopback:** `tests/m9/panel-loopback.ps1` on the release exe, driven by `CHATQ_PANEL_DRIVE` lines ([App.drive_line](native/overlay/src/app/pointer.rs)); a check by its lead words.
- **Panel:** a `kind` of `native/vectors/overlay-panel.json`.
- **PS sections:** a section of `tests/sections/` by name; a check by its lead words.
- **Other names:** `cargo test`'s.

| Item | Where | Tested by |
|---|---|---|
| A1 one collect pass: rows, states, order | host: [Invoke-ChatOverlayCycle](src/overlay-data.ps1), [Get-ChatOverlayRows](src/overlay-data.ps1), in [Invoke-ChatOverlayCollectLoop](src/overlay-data.ps1); read by [snapshot.parse](native/overlay/src/snapshot.rs) | [overlay](tests/sections/overlay.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the headless host's overlay.json is the WPF host's'; vector overlay-snapshot, [every_golden_reads_as_its_answer](native/overlay/src/snapshot.rs) |
| A2 transcript tail | host: [Find-ChatTailRecords](src/overlay-data.ps1) | [overlay](tests/sections/overlay.ps1), [phone-board](tests/sections/phone-board.ps1) |
| A3 open chats and where they run | host: [Read-ChatOpenTabs](src/overlay-data.ps1), [Get-ChatProcessTable](src/overlay-data.ps1), [Get-ChatOverlayProcessChain](src/overlay-data.ps1); the tabs to the panel as `ui.tabs` | [overlay](tests/sections/overlay.ps1); [host-work](tests/sections/host-work.ps1), the chain through [Get-ChatHostWork](src/host-work.ps1); B10's checks |
| A4 panel window: top right, on top, click-through, drag, place kept | [App.place](native/overlay/src/app.rs), [App.save_place](native/overlay/src/app.rs), [model.placement](native/overlay/src/model.rs), [App.start_move](native/overlay/src/app/pointer.rs) | loopback 'no place of its own', 'the window', 'dragged by -40,30', 'click min', 'started again', 'a place off every screen'; panel `placement` |
| A5 tile row, 7-segment clock, where-it-runs mark | [panel.draw_tile](native/overlay/src/panel.rs), [art.seg_points](native/overlay/src/art.rs), [model.row_clock](native/overlay/src/model.rs), [model.tile_mark](native/overlay/src/model.rs) | [golden_panel_dark](native/overlay/src/panel.rs), [golden_panel_capped](native/overlay/src/panel.rs); [the_clock_has_the_mockups_numbers](native/overlay/src/art.rs), [glyphs_sit_where_wpf_centres_them](native/overlay/src/art.rs); [the_panel_is_as_wide_as_a_tile_in_its_frame](native/overlay/src/panel.rs); panel `rowClock`, `rowWords` |
| A6 config, state file, log, theme | host: [Get-ChatOverlayConfig](src/overlay-data.ps1), the `config` verb ([Invoke-ChatOverlayPanelVerb](src/overlay-host.ps1)); panel: [App.save_place](native/overlay/src/app.rs), [look](native/overlay/src/look.rs), `system` read again by [App.fifth](native/overlay/src/app.rs), [selflog](native/overlay/src/selflog.rs) | [overlay-host](tests/sections/overlay-host.ps1) 'config: the box's settings saved'; loopback 'a slider, after its rest', 'a theme choice'; [names_hex_and_the_text_fallback](native/overlay/src/look.rs); [a_log_rolls_to_one_old_copy](native/overlay/src/selflog.rs); the light goldens |
| A7 Claude usage gauge | host: [Update-ChatOverlayUsage](src/overlay-data.ps1); panel: [panel.gauge](native/overlay/src/panel.rs), [card.usage](native/overlay/src/card.rs), [clock.reset](native/overlay/src/clock.rs) | [usage](tests/sections/usage.ps1), [overlay](tests/sections/overlay.ps1); [golden_card_usage_below](native/overlay/src/card.rs), [golden_card_usage_above_light](native/overlay/src/card.rs); [markers_gauges_and_the_rule](native/overlay/src/panel.rs); [a_gauges_card_hangs_under_it_with_one_reset_time](native/overlay/src/card.rs), [a_stale_gauges_card_greys_its_name_and_percents](native/overlay/src/card.rs); vector overlay-clock, [every_clock_case_says_what_powershell_said](native/overlay/src/clock.rs); panel `activeUsage`; loopback 'click again' (refresh) |
| A8 hover card | host: `card <key>`, [Get-ChatOverlayCardModel](src/overlay-data.ps1) to `card.json`; panel: [App.card_tick](native/overlay/src/app.rs), [card.chat](native/overlay/src/card.rs) | [hover-card](tests/sections/hover-card.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'card: the row's hover card'; loopback 'hover a tile'; [golden_card_chat_right](native/overlay/src/card.rs), [golden_card_chat_left_light](native/overlay/src/card.rs); [a_chats_card_says_whose_what_and_the_turns](native/overlay/src/card.rs), [a_chats_card_waits_for_its_model](native/overlay/src/card.rs), [the_cards_model_is_the_one_for_its_key](native/overlay/src/card.rs); panel `cardPlace`, `cardWords`, `cardRow` |
| A9 open chip, raise, show-fresh, the said marker | [chip](native/overlay/src/chip.rs), [App.open_row](native/overlay/src/app/opening.rs), [open.spawn](native/overlay/src/open.rs), [open.raise](native/overlay/src/open.rs), [model.raise_plan](native/overlay/src/model.rs); host: `opened`, [Get-ChatOverlayOpenSay](src/overlay-host.ps1), [Get-ChatOverlayOpenBalloon](src/overlay-host.ps1); the said on its row, [App.saids](native/overlay/src/app.rs) | [the_childs_script_is_the_wpf_overlays_word_for_word](native/overlay/src/open.rs), [a_raise_refused_calls_nothing](native/overlay/src/open.rs), [the_child_runs_hidden_and_its_exit_code_comes_back](native/overlay/src/open.rs); [it_comes_after_a_rest_and_a_click_under_a_parked_pointer_asks_again](native/overlay/src/chip.rs), [golden_chip_open_delete_sure](native/overlay/src/chip.rs), [golden_panel_light_unlocked_said](native/overlay/src/panel.rs); loopback 'started', 'click open'; [overlay-host](tests/sections/overlay-host.ps1) 'opened: the unread dot gone on 0', 'opened with a look', 'the panel's opened on the headless launch'; [show-fresh](tests/sections/show-fresh.ps1); panel `openable`, `chipActions`, `chipTarget`, `step`, `chipLayout`, `raisePlan`, `selectWindow`, `openBusy` |
| A10 tray, menu, balloons, hotkey | [trayicon.menu_spec](native/overlay/src/trayicon.rs), [App.tray](native/overlay/src/app.rs), [App.hotkeys](native/overlay/src/app.rs), [App.balloon_event](native/overlay/src/app.rs); host: [Show-ChatOverlayBalloon](src/overlay-host.ps1) | [the_menu_has_the_wpf_items_in_their_order](native/overlay/src/trayicon.rs), [the_menu_words_follow_the_state](native/overlay/src/trayicon.rs), [the_dot_sits_bottom_right_in_its_ring](native/overlay/src/trayicon.rs), [the_tray_takes_the_most_urgent_state](native/overlay/src/model.rs); panel `hotkey`; vector overlay-clock (the tooltip); loopback 'unlocked from the menu', 'Move to top right from the menu', 'hotkey console', 'an ask's balloon clicked', 'a tray click while closing'; [overlay-host](tests/sections/overlay-host.ps1) 'a balloon on the headless host'; the live tray is Tier 1 |
| A11 close by hand, auto-start, code restart | host: [Start-ChatOverlayHeadlessClose](src/overlay-host.ps1), [Set-ChatOverlayClosed](src/overlay-data.ps1), [Test-ChatOverlayCodeChanged](src/overlay-data.ps1) restarting headless, [Resolve-ChatOverlayUiExe](src/overlay-host.ps1); [Start-ChatOverlayAuto](src/overlay.ps1) starts the WPF host while it is the default; panel: hidden for `ui.closing` | [overlay](tests/sections/overlay.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'a close by hand', 'the shell's hotkey: the panel's; in a close by hand's 4 s', 'a restart while a close by hand is on its way', 'a panel that keeps exiting', 'Resolve-ChatOverlayUiExe', 'its process gone' (a close tells the console first); loopback 'click close', 'closing by hand', 'a tray click while closing', 'the close taken back' |
| B1 delete: bin, sure?, chatrm | [chip.delete](native/overlay/src/chip.rs), [App.clicked](native/overlay/src/app/pointer.rs); host: [Remove-ChatOverlayRow](src/overlay-host.ps1), [Test-ChatOverlayRowDeletable](src/overlay-host.ps1) | [delete_asks_sure_then_deletes_on_a_second_click_in_time](native/overlay/src/chip.rs), [a_busy_chats_delete_is_greyed_and_takes_no_click](native/overlay/src/chip.rs); [golden_chip_open_delete_sure](native/overlay/src/chip.rs), [golden_chip_ask_words_and_a_greyed_delete](native/overlay/src/chip.rs); [overlay-host](tests/sections/overlay-host.ps1) 'delete: a Recent row deleted', 'the headless host carries out its panel's delete'; panel `deletable`, `deleteArmed` |
| B2 console | host: [Start-ChatConsoleProcess](src/overlay-host.ps1) on `console` and `console-key`, [Send-ChatConsoleLine](src/overlay-host.ps1), [Update-ChatOverlayConsoleChild](src/overlay-host.ps1), [Grant-ChatConsoleFront](src/overlay-host.ps1); the console's process: [Start-ChatConsoleHost](src/overlay-windows.ps1), [Invoke-ChatConsoleLine](src/overlay-windows.ps1), [Save-ChatConsoleUi](src/overlay-windows.ps1), [Open-ChatOverlayHeadlessConsole](src/overlay-windows.ps1); panel: sends `console`, `console-key` and `console-back`, hidden for `ui.console` ([App.act](native/overlay/src/app.rs)) | [overlay-host](tests/sections/overlay-host.ps1) 'the native panel's console's launch', 'the console asked for on the headless host', 'its word: only its own process's', 'asked for again while it runs', 'one that has gone is let go', 'told to go', 'NoFetch', 'chatconsole's start on the headless host', 'the host's verbs for it', 'its process gone'; its STA run 'the native panel's console's process', 'it opens cloaked', 'its word in console-ui.json', 'its host's lines', 'the console hotkey's line', 'back to the panel, it goes at once', 'one already running', 'the console's run calls no function'; its parts run 'the console on the headless launch'; [host-work](tests/sections/host-work.ps1) 'the console's own process'; [find-delete](tests/sections/find-delete.ps1) 'a shell's load leaves out the overlay's parts'; [overlay](tests/sections/overlay.ps1) (the console mode); loopback 'click max', 'hotkey console', 'the host's console up', 'its hotkey in the console', 'the console gone'; whether it comes to the front is TESTING.md S62's hand step |
| B3 Codex usage | host: [Start-ChatqCodexUsageFetch](src/overlay-data.ps1), [Read-ChatqCodexUsage](src/overlay-data.ps1); panel as A7 | [codex-appserver](tests/sections/codex-appserver.ps1), [usage](tests/sections/usage.ps1); panel `activeUsage`; A7's goldens |
| B4 Copilot usage | host: [Start-ChatqCopilotFetch](src/overlay-data.ps1), [ConvertFrom-ChatqCopilotQuota](src/overlay-data.ps1); panel as A7 | [overlay](tests/sections/overlay.ps1), the quota read (the `gh api` call itself, as before M9a, by none); panel `activeUsage` 'Copilot alone' |
| B5 memory-low warning | host: [Update-ChatOverlayMemory](src/overlay-data.ps1), [Show-ChatOverlayMemory](src/overlay-host.ps1); panel: the MEMORY marker (D1) and the balloon (A10) | [host-work](tests/sections/host-work.ps1); panel `headNotices` |
| B6 leak watch | host: [Update-ChatOverlayLeaks](src/overlay-data.ps1); panel: the LEAK marker (D1) | [host-work](tests/sections/host-work.ps1); panel `headNotices` |
| B7 self-restart, heap compaction | host: [Invoke-ChatOverlayHeapCompact](src/overlay-host.ps1), [Update-ChatOverlayRestartDue](src/overlay-host.ps1), held off by [Test-ChatOverlayUiUnderWay](src/overlay-host.ps1); the panel has neither, as the inventory says | [overlay](tests/sections/overlay.ps1), [host-work](tests/sections/host-work.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the panel's under way counts only while its word is under 10 s old'; the loopback's soak (`-Minutes`) |
| B8 resize by edges, into Recent | [App.size_to](native/overlay/src/app/pointer.rs), [model.resize](native/overlay/src/model.rs), [controls.edges](native/overlay/src/controls.rs) | [the_edges_take_their_strips_and_the_line_shows_along_one_side](native/overlay/src/controls.rs); [golden_edges_hint_n](native/overlay/src/controls.rs), [golden_edges_hint_s_light](native/overlay/src/controls.rs); panel `resize`, `heightCap`, `edgesRect`; loopback 'the south edge dragged up' |
| B9 settings box, controls bar | [controls.settings](native/overlay/src/controls.rs), [controls.bar](native/overlay/src/controls.rs), [App.controls_target](native/overlay/src/app.rs); to the host `config`, and the Cut off choice as `auto-on` or `auto-ask` | [a_slider_moves_to_a_press_and_follows_its_thumb](native/overlay/src/controls.rs), [the_box_says_its_values_and_fills_the_chip_in_force](native/overlay/src/controls.rs), [the_tips_are_the_wpf_ones](native/overlay/src/controls.rs); [golden_controls_bar](native/overlay/src/controls.rs), [golden_controls_box_below_light](native/overlay/src/controls.rs), [golden_controls_box_above_folded_and_spinning](native/overlay/src/controls.rs); panel `controlsPlace`, `controlsShown`; loopback 'click gear', 'a slider, after its rest', 'a theme choice'; [overlay-host](tests/sections/overlay-host.ps1) 'config: the box's settings saved', 'the host's own verbs on the headless launch' |
| B10 unread dot | host: [Update-ChatOverlayUnread](src/overlay-data.ps1), [Get-ChatForegroundPid](src/overlay-data.ps1), gone on an `opened` 0 | [overlay](tests/sections/overlay.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the unread dot on the headless launch', 'opened: the unread dot gone on 0'; [golden_panel_dark](native/overlay/src/panel.rs) |
| B11 Recent | host: [Update-ChatOverlayRecent](src/overlay-data.ps1), `config recent`; panel: [panel.draw_recent](native/overlay/src/panel.rs) | [overlay](tests/sections/overlay.ps1); [recent_lines_go_first_and_their_header_with_the_last](native/overlay/src/panel.rs); [overlay-host](tests/sections/overlay-host.ps1) 'delete: a Recent row deleted' |
| B12 full-screen step-aside | [App.full_screen](native/overlay/src/app.rs), [win32.full_screen_of](native/overlay/src/win32.rs) reading [win32.full_screen](native/overlay/src/win32.rs)'s query, [model.full_screen_state](native/overlay/src/model.rs) | [each_answer_of_the_full_screen_query](native/overlay/src/win32.rs), [the_real_query_answers](native/overlay/src/win32.rs); loopback 'a full screen', 'shown by hand during it', 'the next full screen', 'the query answering'; panel `fullScreen` |
| B13 unlock hint, relock, Move to top right | [App.set_locked](native/overlay/src/app.rs), [App.relock](native/overlay/src/app.rs), [model.unlocked_notice](native/overlay/src/model.rs), `reset` in [App.act](native/overlay/src/app.rs) | [it_locks_again_two_minutes_after_it_is_left](native/overlay/src/app.rs); [golden_panel_light_unlocked_said](native/overlay/src/panel.rs); panel `unlocked`; loopback 'unlocked from the menu', 'locked again', 'Move to top right from the menu' |
| B14 collapse to one line | [App.set_collapsed](native/overlay/src/app.rs), [model.compact](native/overlay/src/model.rs), [panel.build](native/overlay/src/panel.rs) | [folded_keeps_its_line_and_drops_the_markers_past_the_cap](native/overlay/src/panel.rs); [golden_panel_folded](native/overlay/src/panel.rs); panel `compact`; loopback 'started' (folded by a command), 'a host command: expand' |
| B15 `charlie -Print`, the macOS panel | stays PowerShell: [Write-ChatOverlayPrint](src/overlay-data.ps1), `src/overlay-mac.ps1` | [overlay](tests/sections/overlay.ps1); `tests/overlay-mac-check.js` |
| B16 Codex job and queued rows | host: [Get-ChatOverlayRows](src/overlay-data.ps1); panel: [art.tile_mark](native/overlay/src/art.rs), [model.more_line](native/overlay/src/model.rs) | [a_queued_tile_dashes_from_its_top_left_round](native/overlay/src/art.rs), [the_more_line_counts_idle_and_queued](native/overlay/src/model.rs); [golden_panel_dark](native/overlay/src/panel.rs); [overlay](tests/sections/overlay.ps1); panel `rowWords` |
| C1 cut-off rows | host: [Format-ChatOverlayCutOff](src/overlay-data.ps1), [Get-ChatOverlayCutOffReset](src/overlay-data.ps1); panel: [model.row_clock](native/overlay/src/model.rs) | [reset-ask](tests/sections/reset-ask.ps1), [host-work](tests/sections/host-work.ps1), [overlay](tests/sections/overlay.ps1); panel `rowClock`, `chipActions`; [golden_panel_dark](native/overlay/src/panel.rs) |
| C2 limit-over ask | host: [Complete-ChatqResetAsk](src/overlay-data.ps1) for `ask-go` and `ask-leave`, in [Invoke-ChatOverlayCycle](src/overlay-data.ps1); [Update-ChatOverlayAsk](src/overlay-host.ps1); a changed ask shown opened out ([Start-ChatOverlayHeadlessHost](src/overlay-host.ps1)); panel: [model.ask_notice](native/overlay/src/model.rs), the chip's words, the tray menu's head | [reset-ask](tests/sections/reset-ask.ps1), [host-work](tests/sections/host-work.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the reset ask's answer', 'the host's own verbs on the headless launch'; [the_banners_and_reloads_answers_name_what_they_answer](native/overlay/src/chip.rs); [an_ask_heads_the_menu_with_its_keys_in_the_verbs](native/overlay/src/trayicon.rs); [golden_chip_ask_words_and_a_greyed_delete](native/overlay/src/chip.rs); panel `askHead`, `askCount`, `askLeave`, `headNotices`; loopback 'an ask's balloon clicked' |
| C3 auto-continue on a card | host: [Format-ChatOverlayDeferral](src/overlay-data.ps1), [Show-ChatOverlayAutoNotice](src/auto-continue.ps1); panel: `auto-chip <key> dont` or `continue` | [overlay](tests/sections/overlay.ps1), [auto-continue](tests/sections/auto-continue.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the panel's auto-continue choice', 'config: the box's settings saved, in range; auto-chip'; [golden_chip_continue_light](native/overlay/src/chip.rs); panel `chipActions`, `rowWords`, `cardWords` |
| C4 crash continue | host: [Invoke-ChatqCrashContinue](src/overlay-data.ps1); panel: the tray's `crash-on` and `crash-off`, the host's own | [host-work](tests/sections/host-work.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'the host's own verbs on the headless launch'; [the_menu_words_follow_the_state](native/overlay/src/trayicon.rs) |
| C5 reload ask | host: `header.reload`, `reload-answer` ([Invoke-ChatOverlayPanelVerb](src/overlay-host.ps1), [Write-ChatReloadAnswer](src/chatrm.ps1)); panel: [model.reload_notice](native/overlay/src/model.rs), the chip | [reload-ask](tests/sections/reload-ask.ps1); [overlay-host](tests/sections/overlay-host.ps1) 'reload-answer: the window's ask answered'; [the_banners_and_reloads_answers_name_what_they_answer](native/overlay/src/chip.rs); panel `reloadText`, `reloadNotice` |
| C6 background work counted as working | host: [Update-ChatOverlayBackground](src/overlay-data.ps1); panel: the row's words | [background](tests/sections/background.ps1), [alert-channels](tests/sections/alert-channels.ps1) |
| C7 answered-job closing | host: [Close-ChatqAnsweredJobs](src/overlay-data.ps1) | [overlay](tests/sections/overlay.ps1) |
| D1 marker tiles | host: [Get-ChatOverlayNotes](src/overlay-data.ps1); panel: [model.head_notices](native/overlay/src/model.rs), [panel.draw_mark](native/overlay/src/panel.rs), [art.notice_glyph](native/overlay/src/art.rs), [card.notice](native/overlay/src/card.rs) | panel `headNotices`, `sayWord`, `unlocked`, `openBusy`; [a_markers_card_says_its_word_then_each_line](native/overlay/src/card.rs); [markers_gauges_and_the_rule](native/overlay/src/panel.rs); [glyphs_sit_where_wpf_centres_them](native/overlay/src/art.rs); [golden_card_notice_left](native/overlay/src/card.rs), [golden_panel_dark](native/overlay/src/panel.rs); [overlay](tests/sections/overlay.ps1), [host-work](tests/sections/host-work.ps1) |

---

## 8. Risks and open questions

### Risks

1. **AV false positives.** A new exe that spawns hidden PowerShell may be quarantined. Mitigated by:
   - signing and the version resource;
   - `-File` steps;
   - WDSI submissions;
   - preflight and the fuse falling back to PS on the first failed launch.

   Residual: the first releases after each version change have no reputation.
2. **System proxy parity.** .NET uses WinINet/IE settings including PAC/WPAD on Windows. chatqd resolves the same through WinHTTP (`WinHttpGetIEProxyConfigForCurrentUser` + `WinHttpGetProxyForUrl`). Authenticating proxies (NTLM/Kerberos) are **not** supported by ureq; where they exist, ntfy/Join/status calls would fail where PS succeeds. Mitigation: on a 407 or a proxy auth failure, the call is redone by a step running the PS function (an `alert` step for publishes; for the poll, a `reply` step with `fetch:true`), and chatqd logs `proxy needs authentication - phone calls go through PowerShell` once to `chatqd.log` and keeps routing that way for its life.
3. **.NET date parsing leniency: removed.** No limit text or transcript block is parsed natively: [ConvertFrom-ChatqLimitText](src/queue.ps1) runs only in `probe`, `block` and `post-run` steps, for good. Cost: one step per waiting lane per 10 min. M7 may port the scans only with a harvested corpus and a `chatqd.log` line for every unparsed `try again` text.
4. **Process-lifetime state split** between chatqd and steps (dedupe sets, the ask-sent list, caches) could make a reply act twice or an ask check run late. Mitigated by:
   - the three carriers and the audit with type round-trips (§3.6);
   - every candidate batch going whole to one step (§3.7);
   - the file-backed nonces and `lastId` in `replies.json`.
5. **Step latency and transient memory.** About 0.4 s and 85 to 211 MB private per step (median 140, 9 test samples, 2026-10-19); heavy on a PC already short of memory. Bounded by the gates, so no step runs on a pass where PS would have done nothing. Measured at M2 and M5, with per-hour step counts recorded in TESTING.md.
6. **Orphan semantics.** They depend on steps killing themselves when chatqd dies. The parent check compares pid and start time on both OSes (§3.6), and the `-Existing` writes never resurrect. Residual: up to one tick (5 s) of a step's work after chatqd died, which is no worse than a PS watcher killed mid-write.
7. **Image name and parent change.** Task Manager shows `chatqd`. A run's CLI parent becomes chatqd (M5) or `powershell` (a step, M2–M4). §5.6's audit makes "nothing keys on the watcher's image" a test, not an assertion. User scripts outside the repo that key on it would see a difference.
8. **Two engines drift.** Every behaviour change must land in both, plus vectors, until the PS watcher is retired. Drift is held down by the vector regeneration check, the contract harness, and the decision to keep policy (retry rules, outcome classification, reply acting, the board while listening) in shared PS functions both engines call. The cost is real.
9. **macOS untested in PS CI.** Mac parity rests on the Rust macOS leg and Tier 2 runs (DEFERRED.md "CI on macOS and Linux").
10. **WinRT toast under another app's AUMID** from a non-PowerShell exe. Expected to work for an unpackaged desktop process, since the AUMID has a Start-menu shortcut. If Windows drops it silently, the `toast` step runs [Show-ChatqToast](src/alerts.ps1).
11. **Long data path on macOS** (> 103 bytes) means no IPC socket in M8: latency only.
12. **Culture.** §2.11 covers the culture-sensitive strings, and the `culture.json` vector holds them. Residual: a launching PowerShell that changed `CurrentCulture` in-process passes that culture. A PS watcher it starts would get the user default instead. Accepted, logged in `chatqd.log` when `--culture.name` differs from the OS user locale.
13. **The fuse counts a hand kill.** A chatqd killed from Task Manager leaves `watcher.pid` behind, so it is one crash strike. Three in a day fall back to PS until the version changes or `D/native/fuse.json` is deleted. The alternative, not counting crashes at all, would miss AV kills and access violations, which matter more. TESTING.md's M0 check says so. Decided 2026-10-15: every kill counts.
14. **Memory target.** It is now measured, not asserted (§3.3). If TLS or COM residue keeps listening above 8 MB, the fallback options, in order: drop the agent sooner, move polls to a short-lived thread, then re-base with the measurement recorded.

### Deliberate differences (observable, and why no reader relies on them)

- **Image name** `chatqd` and the run's parent (risk 7).
- **`taskkill.exe`** is run from `%SystemRoot%\System32` by absolute path. PS resolves the bare name through PATH. The two differ only if PATH puts another `taskkill.exe` ahead of System32, which is a planted-binary case worth closing.
- **`.jsonl` lines keep flowing during a mid-run step.** PS stops reading stdout while `onTick` runs (a 20 s push stalls the stream). chatqd's reader keeps logging, and `claude` is never back-pressured. Content and order are identical; only arrival timing differs, in the tail's favour.
- **`#<seq> error: helper step <reason>`** with no `@ <frame>` unless the reason is `failed: <error>`, only when a pick step does not answer well: it did not start, did not load, died, or threw outside Invoke-ChatqPick's own catch. The PS equivalent is the watcher process dying, which logs nothing at all.
- **Handle inheritance** is narrowed to the three pipes for runs (§2.6). .NET inherits every inheritable handle, and the watcher owns none it means to pass on.
- **The pick and block steps read the job again.** chatqd lists the queue, then the step finds the job by id. A `pick` skips a job removed, or no longer `queued`, in between (`{gone:true}`); a `block` step skips only a removed one, since [Update-ChatqBlock](src/watcher.ps1) reads nothing of the job but its lane, and scans for a changed one with the job as re-read. The PS loop goes on with the copy it listed: it probes and runs a job its user just removed or changed, or scans for it. The gap is the step's start, about 0.4 s.
- **Timers are not carried on a handoff.** `handoff.json` carries `W` and the caches (§4.4), not chatqd's auto (5 min) and stray (6 h) timers or its board time. The PS watcher runs the auto scan and the stray sweep on its first pass, as every PS watcher does after a restart.
- **The soon prune-save is skipped once per key.** When every due soon key is already in `data/usage-alerts.json`, chatqd adds it to `ChatqUsageSent` with no step, so [Use-ChatqUsageAlertState](src/phone-extras.ps1)'s [Save-ChatqUsageAlertState](src/phone-extras.ps1), which prunes old keys on every save, does not run for it. The file is pruned at its next save by anyone: a soon alert that goes, or the overlay's heads-ups. A key the prune drops names a reset long past or a window long gone, so no gate asks for it again.
- **A pick failure is written Update-only, and its alert waits for the write** (§2.4). The PS catch calls [Complete-ChatqJob](src/watcher.ps1) without `-Existing`, so a job file removed in that instant comes back, failed; and it sends the alert even when that write threw. chatqd never brings a removed job back, and alerts only for a job it failed.
- **A handoff carries more than a PS restart does.** `handoff.json` carries `lastAllowed`, `probeFails`, `scannedAt` and the caches (ask entries, reply dedupe sets, soon keys, the summary's last try), which a PS watcher handing over to a PS watcher drops. So the PS watcher that takes over from chatqd mid-life does not repeat a probe chatqd made under 3 min ago, a scan under 10 min ago, an ask check or a soon alert. Your decision 6: these handoffs happen mid-life, where dropping them would repeat pushes. In M2 that was the reply window opening; from M3 it is a panic, or a firewall refusing chatqd the poll's connect.
- **The auto, stray and rescan timers read the pass's start time.** chatqd fires them on the `now` it took at the top of the pass. The PS loop reads Get-Date at each test, so its later tests drift by however long the steps before them in that pass took. A timer can fire one pass apart between the engines when a pass's steps straddle its due time. Nothing reads when a timer fired, only that it did.
- **The poll ignores the environment proxy.** chatqd's poll ([http.get](native/crates/chatqd/src/http.rs)) goes through the system proxy alone, as Windows PowerShell 5.1's `Invoke-WebRequest` does; `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are not read. pwsh 7's `HttpClient` reads them first, so where they are set and name another route than the system's, a pwsh 7 watcher and chatqd poll by different routes. Nothing chatq sets them, and a step's own calls keep their edition's behaviour.
- **The soon gate's wake time past a failed lock.** On the failure path only: when [Use-ChatqUsageAlertState](src/phone-extras.ps1) throws on its lock or save, [Send-ChatqUsageSoon](src/phone-extras.ps1)'s catch ends its walk over the lanes, so the PS loop wakes only for the lanes it reached. chatqd takes the wake time from the native gate, over every lane. Either way nothing is recorded and the alert is tried again on the next pass.
- **A failed step records its attempt** (§3.6 "Failure"): `block` stamps `scannedAt`, `held` sets `ChatqSummaryTriedAt`, `ask-landed` drops its due entries. In the PS watcher the same fault is a throw: from [Update-ChatqBlock](src/watcher.ps1) or [Test-ChatqAskLanded](src/ask.ps1), which the loop calls outside any `try`, it ends the watcher; inside [Send-ChatqHeldSummary](src/phone-extras.ps1) its own `catch` takes it. A step retried every pass would cost 0.4 s and 100 MB a pass; recorded, it waits as a success would.
- **A failed `reply` or `board` step holds the next one back** (§3.6 "Failure"), 1 min doubling to 10, with one `watcher.log` line at most every 10 min. The PS watcher has no such hold: the same fault is a throw inside [Invoke-ChatqReplyPoll](src/phone.ps1), whose own catch logs `poll error: <msg>`, or inside [Write-ChatqBoard](src/alerts.ps1), whose own catch takes it, and the next pass acts again. The hold is on the step alone, so the rest matches: chatqd still fetches at the poll's cadence, logs and saves a junk-only batch while held, logs a failed fetch by the same 10 min rule, and fetches a held candidate batch again, kept since `lastId` has not moved, until the hold ends.
- **The poll's HTTP is chatqd's own** ([http::fetch](native/crates/chatqd/src/http.rs)), where the PS watcher's is its edition's `Invoke-WebRequest`. No reader sees the route, only the body or `poll failed: <why>`:
  - one 8 s deadline for the whole call, connect to the last body byte;
  - at most 5 redirects, Windows PowerShell 5.1's default;
  - ureq's user agent, which ntfy does not read;
  - the body decoded once as UTF-8, bad bytes replaced as .NET's `UTF8Encoding.GetString` does, never a throw; at most 10 MiB, past which the poll fails `the answer was too long`;
  - `<why>` a fixed text per kind of failure, never the library's message, which may hold the URL and so the topic;
  - a proxy that asks for credentials (407) fails the poll as `proxy needs authentication`, said once in `chatqd.log` (DEFERRED.md "A proxy that asks for credentials").
- **A connect the system refuses hands the window to the PS watcher.** A firewall that blocks programs by default lets PowerShell out but refuses a new `chatqd.exe` its connect at once: WSAEACCES (10013), which std reads as `PermissionDenied` and [Fail::of](native/crates/chatqd/src/http.rs) as `Fail::Forbidden`, `Windows does not let chatqd connect (a firewall?)`. Found on this PC on 2026-10-22: Windows Firewall's `DefaultOutboundAction` is `Block`. The PS watcher's poll gets out, so where chatqd's cannot it listens instead, with no user action:
  - [Poller::poll](native/crates/chatqd/src/watch/reply.rs) counts that poll as not made: `ChatqReplyPolledAt` put back, no `poll failed:` line, nothing saved, so the PS watcher polls at once;
  - it logs `the firewall blocks chatqd, so the PowerShell watcher listens for phone replies instead - allowing chatqd.exe out saves the memory that watcher takes` once to `watcher.log`;
  - [loop::run](native/crates/chatqd/src/watch/loop.rs) hands over as up to 0.10.20 an open window always did (§4.4), W and the caches in `handoff.json`, `handing over to the PowerShell watcher: Windows does not let chatqd connect (a firewall?)` in `chatqd.log`;
  - no state remembers the refusal: the next chatqd to start polls natively again, so an allow rule for `chatqd.exe` takes at its next start. A spawn per poll was not taken: a PowerShell every 6–20 s is risk 5's cost many times over.

  Any other failed connect stays `poll failed: the connection failed`, and chatqd listens on.

### Review items not taken as proposed

- **`CREATE_NO_WINDOW` for steps (critique 2).** Not taken. Steps run code that touches the console: the 5.1 `[Console]::InputEncoding` swap in [Start-ChatqProcess](src/queue.ps1) and `$Host.UI.RawUI` in [Get-ChatqWidth](src/alerts.ps1). With no console those take different paths than in today's watcher, which has a hidden console from `Start-Process -WindowStyle Hidden`. Steps get the same hidden console (`CREATE_NEW_CONSOLE` + `SW_HIDE`), so any flash risk is exactly today's. chatqd's own CLI spawns do use `CREATE_NO_WINDOW`, as .NET's `CreateNoWindow` does.
- **Keep the whole board as a helper step (critique 2).** Not taken: it is rewritten on every pass, up to every 30 s, and a step per pass would cost more memory than the port saves. Taken in part: the board while listening, where [Get-ChatqBlocks](src/alerts.ps1) scans transcripts, stays a `board` step. The not-listening board is ported with goldens across three cultures and two TZs, CRLF included. The critique's claim that the board reads usage and chat counts from `overlay.json` does not match the code: [Get-ChatqUsage](src/alerts.ps1) is for `chatqlist` alone, and [Write-ChatqBoard](src/alerts.ps1) does not call it.
- **A stderr cap (first draft).** There is none in PS: `ReadToEndAsync` is uncapped. chatqd keeps the full content and spools it to a file instead of memory (§2.6).
- **"Port the outcome classifiers and the retry policy" (first draft) vs "assign an owner" (critique 1).** Owner assigned: the `post-run` step, for good. Porting would duplicate the product's core judgement for no memory gain, since it runs once per run.
- **Codex probe and app-server native (critique 1, as a question).** Answered: a `probe` step, for good, alongside CLI discovery. A probe already spawns a CLI process far larger than the step.
- **The `replies.json` writes (critique 1).** Taken, narrowly. chatqd writes only the junk-only and `lastPolledAt` saves, through a vector-tested port of the full save with prune. Every write that records or acts on a genuine message stays in the `reply` step, save-before-act included.

### M0 corrections (2026-10-15, from reading the PS sources; for review)

Each is fixed in the section named. None is a decision of yours yet.

- **M0 never waits** (§7 M0): every pass hands off or exits, so the `hold` seam (§6.5) is how the wait is reached.
- **The first pass does more than M0 ports**: the held summary, the auto scan, the stray sweep and the board. Each now means a handoff, except the trivial board (§1.1).
- **A `-Now` taken and handed over is lost**: left unread when jobs are queued (§1.1 wake row).
- **Repair triggers** follow the functions, not "non-empty `D/permit/`" (§1.1 repair row).
- **[Test-ChatqReplyOpen](src/phone.ps1) moves to M0**, which needs it three times (§1.1).
- **A `busy` ack hid a crash**: only the lock holder writes `last.json`; `pending.json`'s deletion is the ack (§4.2).
- **`chatqd version`** prints its compiled version and the folder target (§4.2).
- **`forbid(unsafe_code)`** could not hold with an inner `allow`; now `deny` (§3.1). Toolchain and config files are found from the current directory (§3.1).
- **No `config.lock`** for chatqd: it never writes config (§2.1).
- **The fuse's alert** comes from a PS decision call, and a strike's launch is the call's own (§4.2).
- **Zoneless stamps** differ by flavour (§2.2); **curly quotes** are doubled in the launch (§2.7).
- **New formats**: `verified.json`, `fuse.json`'s `alerted` (§4.5), the capture spawn record (§6.5).

### M2 contract notes (2026-10-18)

Your decisions of 2026-10-18, where the contract carries them:

1. M2 ships as `0.10.16`; the version moves only in M2's last, versioned commit.
2. The harness runs each job case twice, once per engine, and compares (§6.5 "The harness").
3. A failed step whose gate still holds records its attempt (§3.6 "Failure").
4. A step that cannot be launched is reason `did not start` (§3.6 "Failure"; §2.4 for a pick).
5. The parent-name audit (§5.6) waits for M5, as §5.6 already says: DEFERRED.md "The parent-name audit".
6. A mid-life handoff carries `W` and the caches through `handoff.json` and `carry.clixml` (§4.4).

Where the contract departs from the earlier text, from reading the PS sources:

- **Maps travel as pair lists**, not JSON objects (§3.6 "The `w` encoding"): an empty lane key and `Answers` keys that differ only by case would each make 5.1's `ConvertFrom-Json` throw.
- **`Answers` comes back ordinal**: an `OrderedDictionary` with `[StringComparer]::Ordinal`, as [ConvertTo-ChatqAskAnswers](src/ask.ps1) builds it, not `[ordered]`, which is case-blind and would merge two questions.
- **`ntfyBase` maps to `ChatqReplyServer`**, the reply server's default; publishes are captured whatever their server. **`joinBase` maps to nothing**: Join's URL is a literal with no variable, and `capture` takes every Join call anyway (§6.5).
- **`job-write` has a second shape**, `complete`, for a pick failure on a file chatqd may not write (§2.4).
- **The failed alert needs the failure written** (§8 "Deliberate differences").
- **`ok:false`** is a reason of its own, `failed: <error>`, beside the two the earlier text named.
- **Two of M2's job cases run under chatqd alone** (§6.5 "The harness"), as the PS watcher has no counterpart to run. A pick step killed mid-run: chatqd's failure write is compared with [Complete-ChatqJob](src/watcher.ps1) and the loop's failed alert, run on a twin of the job file the step left. A pick that opens the reply window: only chatqd hands over, so the PS watcher it would start is started on its `handoff.json` and must carry on from it.

Open, for review:

- **A `soon` step that keeps failing runs every pass** until the reset is past, since neither engine records a failed soon attempt. It needs a step that does not start or dies inside [Send-ChatqUsageSoon](src/phone-extras.ps1), which never throws. Recording it as sent would lose the alert; leaving it costs one step a pass while it lasts (FUTURE_WORK.md "A heads-up step that keeps failing").
- **chatqd does not honour the `clock` seam in M2.** Its gates run on the real clock while a step's [Get-ChatqNow](src/phone-extras.ps1) follows the seam. A harness case that moves the clock into or out of quiet hours can see chatqd skip a `held` step the PS watcher would run. Such cases set no `clock` in M2. M3 honours it for that quiet-hours check (§6.5).

### Memory, measured (2026-10-19/20)

One day on this PC, live processes told from tests by the logs' start and stop lines.

- **No job ran.** Every minute the watcher ran, it listened: each live alert from the overlay opens the reply window ([Send-ChatqAlert](src/alerts.ps1), [Open-ChatqReplyWindow](src/phone.ps1)) and starts a watcher. With `reply.hours` 0.5 it ran 58% of the day. M2 would have saved nothing.
- **M3** would save about 98 MB private averaged over the day, about 166 while a watcher runs; listening held 2.58 MB against §3.3's 8 MB (TESTING.md S59).
- **The overlay** ran all day at 271 MB private. M9 at an 80 MB gate would save about 191, about twice M3; the spike held 6.8 (below). Its memory restart ([Update-ChatOverlayRestartDue](src/overlay-host.ps1)) was never due: no run drifted more than 12 MB past where it settled.
- **Without a port,** `reply.on` false ([Test-ChatqReplyOpen](src/phone.ps1)) or `liveAlerts` false ([Test-ChatqLiveAlertsOn](src/phone.ps1)) takes the watcher off such a day: the same saving as M3. The first loses everything from the phone; the second the live alerts themselves. Not taken: replies to live alerts stay (8 of the 12 replies in the 26 days before).
- **Stop rule.** Time-weighted private MB of the live overlay and watcher over a 24 h log, 374 that day. The watcher port stops for memory below 50; M9 goes at 80 or less after an hour of its spike and stops above 150; memory work stops at 100 or when every item left projects under 50 a day. A day with queued jobs is measured before M4 and M5 are ruled out for memory.
- **The M9 spike** (2026-10-20, TESTING.md S58): one Slint process with the five windows, the tray, the hotkey, the content read live and a stand-in for the collector's reads held 6.8 MB private at its highest over minutes 45-60 by its own sampler (median 6.5; memlog's minute samples 6.6, median 6.5), a slope of -0.01 MB/h over minutes 30-60, a start peak of 6.3, handles flat (32 GDI, 34 USER, 256 from minute 5) and CPU 0.055% of the machine by process times (65.2 M cycles a second, not yet "The overlay's own cost"'s measure); the UI alone held 5.0 MB, and the live overlay 314 beside it. With §3.3's 8 MB for TLS and the steps M9 would start (2.5 live-alert senders an hour, from the measured day's 53 in 21.25 h, times risk 5's 85 to 211 MB, times about 5 s each, as that day's measured senders lasted: 0.3 to 0.7), the projected overlay is 15.1 to 15.5 MB; at risk 5's 0.4 s a step it would be 14.8 to 14.9. By the stop rule: go on Windows for memory (6.8 at or under 80, the slope under 2 MB/h); the behaviours held, bar six left to the hand, the chord held down among them (TESTING.md "Still to check by hand"); a Tier 2 Mac check comes before M9 builds past Windows. The spike has no collector, so the 191 holds only once the collector moves.
- **The headless host** (2026-10-23, TESTING.md S62's automatic run): the PowerShell behind the native panel, the collector still in it, settled at 130.8 MB private 60 s after its start with no console parts loaded. Since 0.11.6 the console is not in it but a process of its own, about 262 MB while it is open and nothing once it closes (§7 M9, "Decided for M9b, step 1").

### The M9 spike (2026-10-20)

What TESTING.md S58 found that binds M9's design on Windows, each in the spike's code under `native/spikes/overlay/` (committed with 0.10.20; `native/overlay/` started from it). None is a stop.

- **Five windows move in one batch, sized through Slint.** Following the panel from `WM_WINDOWPOSCHANGED` showed the windows a frame apart in one of five traced moves, in two of ten runs, and the batch never did, so all five move in one DeferWindowPos batch with SWP_NOSIZE (`win32::move_together`). Sizes go through Slint as logical sizes, rounded as Slint rounds (`Glue::replace`, `Glue::px` in glue.rs). A batch that sized a window before Slint knew its new scale panicked Slint's software renderer.
- **A scale change is the port's to place.** winit resizes each window alone, from its current physical size, so rounding compounds; Slint only takes the scale. `WM_DPICHANGED` reached a window only when it was next moved or sized, up to 8 s apart (the cause not proven), so the port re-places all five on a change and sizes them again once each has its scale.
- **winit rewrites the extended style on every show.** A `WM_STYLECHANGING` subclass holds it (`win32::make_overlay`), set while the window is hidden (`show_no_activate` in main.rs); not activating, no taskbar entry and no drag and drop are set through winit's attributes (`unstable-winit-030`, in `main`).
- **Click-through is winit's hit test and a window per strip.** `set_cursor_hittest` (TRANSPARENT and LAYERED) on the panel and one no-activate window per strip (`mouse::set_lock`); alpha-0 pixels, HTTRANSPARENT, SetWindowRgn and WS_EX_TRANSPARENT alone (`win32::set_click_through`) each failed.
- **A layered window needs its attributes.** `set_cursor_hittest` makes WS_EX_LAYERED with no SetLayeredWindowAttributes, so the window never draws until `win32::layered_opaque` sets them.
- **A shown window is cloaked until it paints.** A layered card shows its last picture while the UI thread is busy; DWMWA_CLOAK until the next `WM_PAINT` (`win32::cloak_until_painted`) shows no stale frame.
- **Han text needs a fallback list.** Slint's default, Yu Gothic, draws simplified Chinese as nothing, silently; `han_fallbacks` in main.rs sets a list through fontique (`unstable-fontique-011`).
- **Fonts are mapped, not private.** Malgun, the two Microsoft CJK faces, Yu Gothic and Segoe UI Emoji map about 12 to 20 MB each, with 16 MB of font cache: working set, not the private figure the gate counts.
- **opengl32 in the module list is the PC's.** The MarkAny filter on this PC (`imgsf50filter_x64.dll`) injects opengl32, glu32 and dxcore into every GUI process, so a check for a GPU path reads the exe's own imports, not the module list.
- **The tray runs on the UI thread.** Every tray-icon, muda and global-hotkey event is heard where the crate hears it and handed to Slint's loop with `invoke_from_event_loop`; no loop or poll of the port's own. global-hotkey sends a release from a thread it starts for each press, which by its source polls the key every 50 ms. The menu takes the foreground, and after each close it stayed the spike's for up to 40 s in the 10 s samples; whether the WPF overlay keeps it the same way was not looked at.
- **The balloon needs tray-icon forked or patched.** Its NIF_INFO goes on tray-icon's own window under a uID the crate keeps private, found in the spike by Shell_NotifyIconGetRect (`tray::find_uid`). A git source fails §3.4's "crates.io only", so the change is a `[patch]` to a vendored path crate or a fix upstream (DEFERRED.md "tray-icon's private balloon id").
- **The tooltip is cut at 127 units.** At 128 Windows loses the NUL silently; `gate::tray::cut_tip` keeps 126 and an ellipsis, never splitting a surrogate pair. muda has no bold item and no item tooltips.
- **muda's ids are new on every rebuild.** A handler matches the id the last build gave, never one kept from before.
- **The menu's modal loop stops Slint's timers.** Gaps of 1.2 to 6.3 s, the menu's time open; the port needs a SetTimer/`WM_TIMER` tick that runs inside the menu's loop, or accepts a card frozen while the menu is open (FUTURE_WORK.md "Slint's timers while the tray menu is open").
- **The pointer can be unreadable.** GetCursorPos fails while the input desktop is another's, the lock screen's say; `win32::cursor_now` gives none and the poll skips that read.
- **The close toast covers the topmost windows.** Windows' own toast drew over the spike's topmost status window at the screen's foot, where the panel's home is (FUTURE_WORK.md "The toast over the panel's corner").
- **Slint's preferred height ignores `for` rows before the first show.** The card read 61 px, one line, for six before it first showed; the spike takes the wanted rects after each show (`glue::show_next`).
- **One size read uses Slint's private API.** `Glue::item_size` reads an item's size through `slint::private_unstable_api`, which can change in any Slint release (DEFERRED.md "Slint's private API in the spike").
- **Licences.** Slint is taken under Royalty-free 2.0, with the Slint badge in the README when M9 ships; the overlay's graph adds BSL-1.0, ISC and BSD-2-Clause, outside §3.4's allow-list, which M9's own `deny.toml` would have to name. Done in `0.11.1`: the badge is in both READMEs, `native/overlay/deny.toml` names them, and the exe ships with `THIRD-PARTY-NOTICES.html` from cargo-about (§4.7). cargo-about 0.9.2 drops a clarified LicenseRef file whose licence id is the crate's own, so [about.toml](native/overlay/about.toml) gives Slint's text the id `LicenseRef-Slint-Royalty-free-2.0-text`; a cargo-about upgrade has to check the Slint crates still list with the text.

### Open questions for you

1. **Name and folder.** Decided 2026-10-15: `chatqd` in `native/`, binaries at `R/bin/<version>/<target>/`, beside `data/`, since they are shipped code, not runtime data.
2. **Switch command.** Decided 2026-10-15: none. Native runs whenever its binary is there; `watcher: "ps"` in config is the hand-edited escape hatch (§4.2).
3. **Default flip.** At M7 as proposed, or later? How long should the PS watcher stay as a fallback? Proposed: two minor versions after the flip, then a decision recorded in DEFERRED.md.
4. **Signing budget.** Azure Trusted Signing or SignPath OSS for Windows? For macOS, an Apple Developer ID and notarization, or ad-hoc re-signing after `lipo` (required either way, §4.7)?
5. **VSIX packaging.** Platform-specific VSIXes (Marketplace) or one VSIX with all binaries (local install)? Decided for `0.11.1`: one VSIX, carrying only the Windows panel exe, copied on Windows only (§4.7); platform-specific VSIXes wait for a Mac binary or a size that matters (DEFERRED.md "Platform-specific VSIXes").
6. **Windows on ARM.** Ship `aarch64-pc-windows-msvc` too, or rely on x64 emulation?
7. **Linux.** Confirm that Linux stays on the PS engine with no native build.
8. **Step entry.** Settled: `-File src/native-step.ps1` (§3.6). This adds one file to the payload lists of `install.ps1`, `chatinstall` and [extension/build.js](extension/build.js). Object now if you prefer otherwise.
9. **Auto-continue scan.** Port natively at M7, or keep it as a 5-minute step if measured cheap?
10. **M8 liveness.** Adopt the per-request lock file (`D/ask/<rid>.lock`) as the primary ask-hook liveness, with the process match kept only for the upgrade window?
11. **Fuse and hand kills.** Decided 2026-10-15: every kill counts (risk 13).

### Decided beyond this SPEC (2026-10-15)

- **Order of the whole port:** lazy profile (PS) and the overlay's heap log first, then this watcher, then the M8 stubs, then the overlay (M9). **Changed 2026-10-20**, from the measured day (§8 "Memory, measured"): after M2, the M9 spike comes next, then M3; replies to live alerts stay, so M3 is what takes the watcher off a day of them. The spike ran the same day (§8 "The M9 spike"), so M3 is next.
- **M9 overlay:** one cross-platform Rust UI (Slint's software renderer on winit, Slint 1.18.1 under its Royalty-free 2.0 licence, with `tray-icon` and `global-hotkey`), platform modules only where a window behaviour needs one; no GPU-rendered toolkit, no WebView. **Spiked 2026-10-20** (TESTING.md S58): the must-have window behaviours it checked held on Windows, six left to the hand (TESTING.md "Still to check by hand"), with the design consequences in §8 "The M9 spike"; memory: go on Windows, 6.8 MB at the gate. A Windows go does not settle "one cross-platform UI": a Tier 2 Mac check comes before M9 builds past Windows (DEFERRED.md "The M9 spike on a Mac").
- **Shell commands stay PowerShell.** Porting them too is future work, not planned.