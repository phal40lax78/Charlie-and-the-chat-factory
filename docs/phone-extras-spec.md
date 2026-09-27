# Spec: four smaller phone features

Usage heads-ups, quiet hours, voice, and a reply typed outside the browser.
Each one builds on 0.8.0 as the code has it now. They are separate:
any of them can ship without the others. When two meet, the order is
fixed in [Where they meet](#where-they-meet).

The command is **`chatnotify`** in every spec here. `chatqnotify` stays
as an alias. The config keys, `data/` files and event names do not
change with the rename.

**Settled, kept by all four.** No key in any push. Only a reply whose
MAC checks out ([Unprotect-ChatqReplyMessage](src/phone.ps1)) does
anything. Nothing a reply does runs above `reply.maxMode`. Pairing works
by code. Replies are rate-limited: 20 uses per alert, one refusal push
per alert every 10 minutes, nonces spent once. Nothing here sends a
push from the overlay's window thread: the overlay writes to
`data/outbox/` ([Send-ChatqLiveAlert](src/phone.ps1)). Nothing sends or
waits on the network inside a
[Use-ChatqReplyState](src/phone.ps1) block, or inside any lock this
spec adds.

**Shared change: new event names.** `$script:ChatqPhoneEvents` in
[src/phone.ps1](src/phone.ps1) gains `usage`. `summary` (the
quiet-hours summary) is added to the always-go list in
[Test-ChatqPhoneEvent](src/phone.ps1), beside `test`, `reply` and
`pair`. A user whose `phoneEvents` is a list (not "all") does not get
`usage` until they tick it. `chatnotify` says so once, in its status
lines: `usage heads-ups are on, but 'usage' is not among the phone's
events`.

---

## 1. Usage heads-ups

### Behaviour

Three alerts, all under one new event, `usage` (title
`chatq · usage`):

| kind | when | who decides | says | page buttons |
|---|---|---|---|---|
| **threshold** | a 5-hour or weekly window (Claude or Codex) crosses a threshold, 90% by default | the overlay's pass (Windows) | `Claude 5h at 91% · resets 13:00 · 3 queued` | Status |
| **soon** | a lane is limited, prompts are queued in it, and the reset is `usage.soonMinutes` (10) away | the watcher | `Claude resets 13:00 · 3 queued · they go then` | **Send now** · Status |
| **reset** | a lane that was limited probes "allowed", with 2 or more jobs queued in it | the watcher | `Claude limit reset · 3 queued · sending #12 now` | Status |

- **Threshold** with nothing queued still goes. It warns you before
  you start something long. `· 3 queued` is left out when nothing is
  queued for that provider.
- **Soon** only goes when the wait was at least 30 minutes when the
  lane was blocked. A 15-minute fallback block (a probe that got no
  reset time, see [Confirm-ChatqAllowed](src/watcher.ps1)) never
  alerts: it is a guess, not a reset.
- **Reset** needs 2 or more jobs queued in the lane. With one, the
  `started` alert that follows seconds later already says it. The
  watcher sends a single reset alert for the whole lane, not one per
  job.
- **Priority:** 0 for threshold and soon. 1 for reset: the queue is
  moving, which you may want to see.

**Away or not: not gated beyond what every alert already has.** All
three go through [Send-ChatqAlert](src/alerts.ps1). At the PC, you get
the toast, and the phone stays quiet (`quietMinutes`). Away, the phone
gets it. A threshold heads-up is worth a toast at the desk: the
overlay shows the figure, but only if you look at it. So this is
unlike live alerts, which send nothing at the desk (the overlay row
*is* the alert there).

### Where the usage comes from

- **Threshold:** the overlay's own usage, as
  [Update-ChatOverlayUsage](src/overlay-data.ps1) returns it for the
  snapshot. That is the live endpoint for Claude (or Claude Code's
  cache, whichever is newer), and the newest rollout for Codex. The
  objects are [ConvertTo-ChatOverlayUsage](src/overlay-data.ps1)'s:
  `provider`, `source`, `at`, `stale`, `windows[]` with `label`,
  `percent`, `resetsAt`, `limited`.
  [Get-ChatqUsage](src/alerts.ps1) is **not** used. It returns text
  parts (`"5h 83%"`), not numbers, and the watcher re-reading
  `.claude.json` on every pass is what its own comment says is not
  worth it.
- **Soon and reset:** the watcher's own `$W.blocked[$lane]` (`Until`,
  `Type`), and the probe result in
  [Confirm-ChatqAllowed](src/watcher.ps1). No usage figure is needed.

**Why the overlay for thresholds:** it already polls usage every
`usageSeconds` (5 min busy, 15 min idle) with back-off on 429, and it
runs whether or not anything is queued. The watcher runs only while
something is queued or a reply window is open. Without the overlay,
there are no threshold alerts (macOS/Linux, or the overlay stopped).
`chatnotify` says so, as it does for live alerts. Soon and reset work
on every OS, from the watcher.

### Mechanics

**Overlay (threshold).** New `Update-ChatqUsageAlerts $Ctx $Usage
$Queued [-Now]` in [src/phone.ps1](src/phone.ps1), in the "chats you
run yourself" region. It is called from
[Invoke-ChatOverlayCycle](src/overlay-data.ps1) right after
`Update-ChatqLiveAlerts`, under the same `$Ctx.WantPhone` gate, with
the `$usage` array and the queued jobs.

1. Config through
   [Get-ChatqLiveAlertConfig](src/phone.ps1) (10 s cache). Return at
   once when any of these holds: no phone channel and toast off;
   `usage.alerts` false; `usage` not a phone event and toast off.
2. For each provider in `Claude`, `Codex` (Copilot is skipped), each
   window with label `5h`, `week`, or `<model> week`:
   - skip when `stale`, or `limited`, or `percent >= 100`. A limit is
     the watcher's business (`limited` event, soon, reset).
   - skip when `at` is over 30 minutes old. A cached figure from a
     `/usage` hours ago is not news.
   - for each threshold `t` in `usage.at`, ascending: crossed when
     `percent >= t`. Only the **highest** crossed threshold not yet
     sent goes. At 95% with `[75, 90]` both unsent, one alert says 95%,
     and both are then recorded as sent.
3. Dedup key: `t|<provider>|<home or ''>|<label>|<t>|<resetsAt as
   epoch minutes, or 'x'>`. A window's `resetsAt` names that window
   instance, so the next window starts clean. With no `resetsAt`, the
   key is `'x'` and it expires 5 h (5h) or 7 days (week) after it was
   written.
4. Hand-off: one outbox file per alert through
   [Send-ChatqLiveAlert](src/phone.ps1), with `event = 'usage'`,
   `priority = 0`, no `sessionId`, and a new field `kind = 'threshold'`.
   [Send-ChatqOutboxFile](src/phone.ps1) passes `-Job $null` when there
   is no `sessionId`, so the link is jobless (`x=1`).
5. The key is recorded **before** the file is written. A crash between
   the two loses one heads-up. It never sends two.

**First pass after the overlay starts:** nothing special. The dedup
file survives restarts. An overlay started at 92% with no record sends
one heads-up (once, ever, for that window), which is the right
outcome.

**Dedup file:** `data/usage-alerts.json`, `{ "<key>": "<utc iso>" }`,
changed only through new `Use-ChatqUsageAlertState { param($st) ... }`.
It has the same shape as [Use-ChatqReplyState](src/phone.ps1): lock
`data/usage-alerts.lock`, opened with no sharing, 3 s wait with random
back-off, and it throws when the lock can't be had or the save fails.
On every save it prunes: keys whose reset passed more than a day ago,
`'x'` keys past their expiry, and anything over 200 entries (oldest
first). The overlay and the watcher both write it, which is why it
has a lock. A save that throws means nothing is sent. The next pass
tries again.

**Watcher (soon).** New `Send-ChatqUsageSoon $W` in
[src/watcher.ps1](src/watcher.ps1), called in
[Invoke-ChatqWatchLoop](src/watcher.ps1) after the pick loop finds
nothing due (right before `Set-ChatqKeepAwake`). For each lane in
`$W.blocked`:

- `Type` is a limit, meaning not `probe failed` and not
  `login needed`. Overloads live in `$W.outage`, not here.
- `Until - now <= soonMinutes`, and `Until - blockedAt >= 30 min`.
  This needs a new `At` on the block object, set where the block is
  set (in [Update-ChatqBlock](src/watcher.ps1) and
  [Confirm-ChatqAllowed](src/watcher.ps1)). It is saved and restored
  with `blocked` in [Save-ChatqWatchState](src/watcher.ps1) and
  [Restore-ChatqWatchState](src/watcher.ps1).
- At least one job is queued in that lane, and it is not held by its
  own `notBefore` past `Until`.
- Dedup key `s|<lane>|<Until epoch minutes>`, in the same file.

The alert is `Send-ChatqAlert 'usage' <text> 0 -UsageKind soon`. It
names no job, so the link is jobless and carries `w=1` (below).
`Wait-ChatqUntil` wakes at least every 30 s, so a soon alert is at
most 30 s late. It also caps the lane's wait to `soonMinutes` before
`Until`, so a watcher sleeping until the reset wakes in time. Change:
`$nextAt` is the smaller of itself and `Until - soonMinutes` while an
unsent soon exists.

**Watcher (reset).** In [Confirm-ChatqAllowed](src/watcher.ps1)'s
allowed branch: read `$was = $W.blocked[$lane]` before it is set to
`$null`. When `$was` was a limit (as above), the lane has 2 or more
queued jobs, and key `r|<lane>|<$was.Until epoch minutes>` is unsent,
call `Send-ChatqUsageReset $W $Job $was` →
`Send-ChatqAlert 'usage' "... sending #<seq> now" 1 -UsageKind reset`.
It sends before `Invoke-ChatqJob` starts. `started` follows.

**The link.** [Send-ChatqAlert](src/alerts.ps1) gets
`[string]$UsageKind`. [New-ChatqReplyAlert](src/phone.ps1) stores it
in the registry entry as `usage = '<kind>'` (a new optional field,
kept by [Get-ChatqReplyState](src/phone.ps1) and
[Save-ChatqReplyState](src/phone.ps1) like `live`).
[Get-ChatqReplyLink](src/phone.ps1) adds `w=1` when the kind is
`soon`. Nothing in `w` is trusted: the watcher decides from the
registry entry, never from the link.

**The new act: `wake` (Send now).** It is added to the page's `ACTS`
and to [Invoke-ChatqReply](src/phone.ps1):

- Refused unless the entry's `event` is `usage` and its `usage` is
  `soon`. Answer: `Send now is for a usage alert about a reset -
  nothing done`.
- Refused if the same process did a phone wake in the last 2 minutes
  (`$script:ChatqPhoneWakeAt`). Answer: `asked 1 min ago - the watcher
  is on it`.
- Nothing queued: `nothing queued - nothing to send`.
- Otherwise `Send-ChatqWake 'now'`. This is exactly `chatqrun -Now`'s
  write. The watcher reading the reply is the one that acts on it, in
  its next loop pass: it forgets limits, overloads and busy-chat
  deferrals, then probes. Answer: `trying the queue now - 3 queued; a
  probe goes first, so nothing is sent while the limit still holds`.
- The act picks no mode and queues nothing new. Jobs run in the modes
  they were queued with at the PC, so `reply.maxMode` is not involved
  and cannot be raised by it. The probe is what makes it safe: a
  still-limited lane is blocked again, and no prompt is planted
  ([Confirm-ChatqAllowed](src/watcher.ps1)).
- Edge case: `-Now` also clears busy-chat deferrals. The job's own
  check in [Invoke-ChatqJob](src/watcher.ps1) (the `Get-ChatShowHold`
  and busy checks) runs again before sending, so a chat busy at the
  PC is deferred again, not typed into.

**Page ([docs/reply.html](docs/reply.html)).**
- `parseFragment` reads `w` → `f.wake = q.w === '1'`. `alertFragment`
  keeps it.
- In `buttonsFor`, the jobless branch: for `e === 'usage'`, `send` is
  `{ act: 'wake', label: 'Send now' }` when `wake`, else Status. `more`
  is `[status]` when `wake`, else `[]`. `about` text:
  - wake: `The queue waits for the limit to reset. Send now asks the
    PC to try at once - a probe goes first, so nothing is sent while
    the limit still holds.`
  - no wake: `About usage limits. Status asks the PC what its queue is
    doing.`
- `sentText` for `wake`: `Sent "Send now". The PC answers with a push.`
  (the generic branch already says this).

### Config, flags, window

`data/config.json`:

```json
"usage": { "alerts": true, "at": [90], "reset": true, "soonMinutes": 10 }
```

| key | default | |
|---|---|---|
| `usage.alerts` | `true` | threshold heads-ups |
| `usage.at` | `[90]` | thresholds, whole percents 1-99, at most 3 |
| `usage.reset` | `true` | soon and reset alerts |
| `usage.soonMinutes` | `10` | how long before a reset the soon alert goes; `0` for none (reset alerts stay) |

A missing block means all defaults. New
`Get-ChatqUsageAlertConfig $Cfg` returns
`@{ Alerts; At; Reset; SoonMinutes }` with the defaults filled in and
bad values dropped (a non-number, out of range, more than 3 → the
default).

`chatnotify` flags, handled by
[Set-ChatqNotifyConfig](src/phone.ps1) keys `UsageAlerts`, `UsageAt`,
`UsageReset`:

| flag | |
|---|---|
| `-UsageAlerts on\|off` | threshold heads-ups |
| `-UsageAt 75, 90` | thresholds; refused unless whole numbers 1-99, at most 3: `usage thresholds: up to three whole percents from 1 to 99` |
| `-UsageReset on\|off` | the soon and reset alerts |

Console messages: `usage heads-ups at 75%, 90% of a 5-hour or weekly
window`; `usage heads-ups off`; `resets: an alert 10 min before one
with prompts queued, and when it happens`.

`chatnotify` status lines gain:
`usage    at 90% (the overlay checks) · resets on` and, when the
overlay is not running or is stale, the same suffix
[Get-ChatqLiveAlertStatusText](src/phone.ps1) uses.

**Setup window.** A new block at the end of WHAT REACHES THE PHONE,
before the toast box:

```
[x] Usage at [ 90 ] %                    (UsageBox, UsageAtBox, MaxLength 8)
    Claude or Codex, 5-hour or weekly window. Needs the overlay.
[x] When a limit resets with prompts queued   (ResetBox)
    Ten minutes before, with Send now, and when it goes.
```

`UsageAtBox` takes `90` or `75, 90`. A bad value blocks Save with
`Usage: up to three whole percents from 1 to 99.` All three controls
join [Get-ChatqPhoneSetupSnapshot](src/phone-setup.ps1),
[Read-ChatqPhoneSetupForm](src/phone-setup.ps1) and
[Get-ChatqPhoneSetupChanges](src/phone-setup.ps1). The `usage` event
box appears in `EventsPanel` with the other events.

### Edge cases

- **Two Claude accounts:** the overlay reads one config dir
  (`$Ctx.ClaudeHome`). Thresholds cover that account only. The home
  is part of the key.
- **Percent drops** (a live figure lower than the cache): no alert,
  and no un-recording. The key is per window instance.
- **A reset passes while the figure is still ≥ t** (the stale window
  shows 0 after reset in
  [ConvertTo-ChatOverlayUsage](src/overlay-data.ps1)): the new window
  has a new `resetsAt`, and it alerts again only when it crosses
  again.
- **`resetsAt` changes** on the server for the same window (rounding):
  the key uses epoch *minutes*. A change of whole minutes would
  re-alert once. Acceptable, and logged.
- **Soon, then Send now works early** (extra usage bought): the reset
  alert does not go, because the block was cleared by the probe
  before any reset was seen. The started alerts say it.
- **The watcher restarts inside the soon window:** the dedup file
  keeps it from sending twice.
- **Quiet hours:** a usage alert is held like any other (section 2).
  A `soon` held all night has a dead `Send now` by morning. The summary
  says `usage: Claude reset 03:00, 3 queued - went at 03:01`, taken
  from the held text, and carries no Send now.

### Tests

`tests/sections/usage.ps1` (new cases) and `tests/sections/phone.ps1`:

1. `Update-ChatqUsageAlerts`, with a `$Ctx` whose `PhoneCfg` holds a
   config and `$script:ChatqLiveSendSeam` catching files:
   - 89% → nothing; 90% → one `usage` file, `kind threshold`, text
     `Claude 5h at 90% · resets HH:mm`;
   - a second pass at 91% → nothing (same key);
   - `[75, 90]` at 95% → one file saying 95%, and both keys recorded;
   - `stale` → nothing; `at` 31 min old → nothing; `limited` → nothing;
     `percent 100` → nothing;
   - a new `resetsAt` at 90% → one more;
   - `usage.alerts false` → nothing, and no file lock taken;
   - `Copilot` rows → nothing.
2. `Use-ChatqUsageAlertState`: lock held by another handle → throws;
   pruning of old and `'x'` keys; 250 keys → 200 kept.
3. Watcher, with the seams `tests/sections/watcher.ps1` already uses:
   - soon: a lane blocked 2 h, `Until` in 9 min, 2 queued → one
     `Send-ChatqAlert 'usage'` with `-UsageKind soon`; blocked 20 min
     → none; a 15-min fallback block → none; nothing queued → none;
   - `$nextAt` is capped to `Until - soonMinutes`;
   - reset: `Confirm-ChatqAllowed` over a `five_hour` block with 3
     queued → one reset alert before the job runs; with 1 queued →
     none; over `probe failed` → none; the same `Until` twice → one.
4. Link and registry: `-UsageKind soon` → entry `usage = 'soon'`, link
   has `x=1&w=1`; threshold → no `w`.
5. `Invoke-ChatqReply` `wake`: on a `soon` entry → the wake file reads
   `now`, answer text as above; on a `threshold` entry → refused; on a
   `done` entry → refused; twice in 2 min → the second refused;
   nothing queued → `nothing queued`. No job file changes in any case,
   and no mode anywhere.
6. `Set-ChatqNotifyConfig`: `UsageAt '75,90'` saved as `[75,90]`;
   `0`, `100`, `x`, four values → refused, nothing saved.
7. Page (`tests/reply-page-check.js`): `parseFragment` reads `w=1`;
   `buttonsFor('usage', '', true, '')` with wake → send `wake`, more
   `[status]`; without wake → send `status`; every act in `buttonsFor`
   is in `ACTS`, and `wake` is one the watcher knows (the existing
   "every act" check picks it up).
8. Manual (TESTING.md): let the 5h window cross 90% with the overlay
   running and the phone away. One push, and none on the next passes.

### Out of scope

- Copilot's monthly quota.
- A threshold heads-up without the overlay (macOS, Linux, overlay
  stopped). That would need the watcher to read usage while nothing
  is queued.
- A second Claude account's usage in the overlay.
- Pausing the queue from the phone ("don't send at the reset").
  **Skip** on a job's own alert already does that per job.

---

## 2. Quiet hours

### Behaviour

A daily window, say 00:00-07:00, when phone alerts are **held**, not
sent. The exception is the events marked urgent: `failed` by default.
When the window ends, **one summary** push says what was held. Nothing
is dropped silently.

**Why a summary, not dropped:** a `failed` you did not mark urgent, or
a `needs input` on a queued job, is still something to act on in the
morning. Dropping it means reading `alerts.log` to find out. One push
at 07:00 costs one notification.

**Why `failed` alone is urgent by default:** a `needs input` from chatq
parks that one job, and the queue moves on. Nothing more is lost by
waiting until 07:00. A `failed` includes a refused login
([Block-ChatqLogin](src/watcher.ps1)) or `can't reach` after three
probes, which hold every queued job in that account all night. It is
the one event that is worth waking for. The user can tick `needs input`
too.

What holds and what doesn't:

| | during quiet hours |
|---|---|
| Join and ntfy (the phone) | **held**, except urgent events |
| desktop toast | shown as ever. It is the PC's own screen. |
| your command (`-Command`) | runs as ever, with a new `$env:CHATQ_QUIET` = `1`, so a Pushover or Telegram command can hold itself |
| `alerts.log` | written as ever |
| `test`, `reply`, `pair` (and `-Loud`) | always go. You just did something. |
| urgent events | go, with no voice (section 3) |
| live alerts (chats you run yourself) | held like the rest. They reach [Send-ChatqAlert](src/alerts.ps1) through the outbox. |

Order inside [Send-ChatqAlert](src/alerts.ps1), after the log line,
toast and command, for the phone channels only:

1. `Test-ChatqPhoneEvent`: an event the phone never gets is not held
   either.
2. Presence: at the PC, the toast has said it. Nothing is held, and it
   is not in the summary.
3. **Quiet hours, new:** in the window, not `-Loud`, and the event not
   urgent → `Add-ChatqHeldAlert`. The report line is
   `phone: held - quiet hours until 07:00`. It returns `$false`, with
   `$script:ChatqLastAlertError = 'quiet hours - held until 07:00'`.
   No reply alert is registered and no window opens.
4. Otherwise it is sent as today.

### The summary

- **Event** `summary`, title `chatq · summary`, priority 1. It always
  goes (added to [Test-ChatqPhoneEvent](src/phone.ps1)'s list), since
  everything in it already passed the event filter. It is **not**
  `-Loud`: at the PC at 07:05, it becomes the toast, and the phone
  stays quiet.
- **Text:** first line
  `held 00:00-07:00: 2 done, 1 needs input, 1 usage`. Then one line
  per held alert, oldest first: `03:12 done · #14 Parser rewrite ·
  finished` (time, event, and the held text cut to 80 characters).
  Cut to 700 characters with `… and 4 more (data/logs/alerts.log)`,
  never splitting an emoji, as
  [Get-ChatqPhoneStatusReport](src/phone.ps1) cuts.
- **Link:** jobless (`x=1`). The page offers Status. A held
  `needs input` job is still answerable: Status lists it, and
  `chatqrun <n>` works at the PC. Nothing in the summary answers a
  particular job. That is deliberate: its alert ids were never
  registered.
- **Joins no per-chat notification** (no `-Job`).

**Who sends it.** Whoever first sees the window over with held alerts
waiting. All three are cheap `Test-Path` checks:

1. [Send-ChatqAlert](src/alerts.ps1) itself, at its start, when not in
   quiet hours. Then the summary comes before the alert that follows
   it. A recursion guard, `$script:ChatqSendingSummary`, keeps the
   summary's own `Send-ChatqAlert` call from trying again.
2. [Invoke-ChatqWatchLoop](src/watcher.ps1), once per pass.
3. The overlay's pass (Windows), once a minute: when
   `data/held.jsonl` exists and the window is over, it calls
   [Start-ChatqOutboxSender](src/phone.ps1) unless
   `data/outbox.lock` is held. [Send-ChatqOutbox](src/phone.ps1)
   calls `Send-ChatqHeldSummary` first. The overlay's thread sends
   nothing itself.

With none of them running (a PC with no overlay and an empty queue),
the summary goes with the next alert or the next watcher. `chatnotify`
shows `3 held since 00:14 - the summary goes with the next alert`.

### Mechanics

New in [src/alerts.ps1](src/alerts.ps1), "config and alerts" region:

- `Get-ChatqQuietHours $Cfg` → `$null` (off) or
  `@{ From = [TimeSpan]; To = [TimeSpan]; Urgent = [string[]]; Text = '00:00-07:00' }`.
  A bad stored value (not `HH:mm`, or From equal to To) reads as off,
  never as a crash on every alert.
- `Test-ChatqQuietNow $Qh [datetime]$Now` → `@{ In; Until }`.
  - Local wall clock: `$Now.TimeOfDay`.
  - `From < To` (07:00-09:00): in when `From <= t < To`.
  - `From > To` (overnight, 23:00-07:00): in when `t >= From` or
    `t < To`.
  - `Until` is the next `To` as a `[datetime]`: today's `To` when
    `t < To`, else tomorrow's.
- `Add-ChatqHeldAlert $Event $Text $Priority $Job` appends one JSON
  line to `data/held.jsonl` under a lock (`data/held.lock`, the
  [Use-ChatqReplyState](src/phone.ps1) pattern, 3 s). The line holds
  `at`, `event`, `text` (whitespace folded, cut to 300), `priority`,
  `seq`, `title`, `until`. More than 200 lines: the oldest go.
  Failure to write: the alert **is sent** instead. Report line
  `phone: could not hold (quiet hours) - sent`. A lost alert is worse
  than a woken user.
- `Send-ChatqHeldSummary` does this:
  1. Under the lock: read `held.jsonl` and rename it to
     `data/held-<random>.sending`. The rename is the claim, so a
     second sender finds nothing. Then let the lock go.
  2. Outside the lock: build the text, then
     `Send-ChatqAlert 'summary' <text> 1`.
  3. On `$true`, or the phone skipped because you are at the PC (the
     toast showed it), delete the `.sending` file.
  4. On a network failure, put the lines back in front of whatever
     `held.jsonl` has by now, under the lock, and retry no sooner than
     5 minutes later (`$script:ChatqSummaryTriedAt`).
  5. `.sending` files older than 10 minutes (a sender that died) are
     taken back into `held.jsonl` on the next try.
  6. Items held more than 24 h ago are still listed, marked
     `(yesterday)`.

**Only while quiet hours are on.** Switching quiet hours off
(`-QuietHours off`) with alerts held sends the summary at once, from
`chatnotify` itself.

### Config, flags, window

```json
"quietHours": { "from": "00:00", "to": "07:00", "urgent": ["failed"] }
```

Absent means off. `urgent` absent means `["failed"]`. `[]` means none
(the whole phone is held).

| `chatnotify` flag | |
|---|---|
| `-QuietHours 00:00-07:00` | on, with that window. 24-hour `HH:mm-HH:mm`, the PC's local time. |
| `-QuietHours off` | off. Held alerts go now as a summary. |
| `-Urgent failed, 'needs input'` | what still comes through; `none` for nothing. Names from the phone events plus `usage`. |

`Set-ChatqNotifyConfig` keys: `QuietHours` (the string or `off`) and
`Urgent`. They are checked with everything else first, so a bad value
saves nothing:

- `quiet hours: HH:mm-HH:mm, like 00:00-07:00, or off`
- `quiet hours: from and to cannot be the same time`
- `no event 'x' - these are: none, <list>`

Saved: `quiet hours 00:00-07:00 (this PC's clock) · failed still comes
through · the rest in one summary at 07:00`.

`chatnotify` status line: `quiet    00:00-07:00 · failed comes
through` and, in the window, `· now until 07:00 · 3 held`.

**Setup window,** in WHAT REACHES THE PHONE after the quiet-minutes
row:

```
[x] Quiet hours  from [00:00] to [07:00]      (QuietHoursBox, QuietFromBox, QuietToBox; MaxLength 5)
    This PC's clock. Held until then, then one summary.
    Still send:  [x] failed  [ ] needs input  [ ] done  ...   (UrgentPanel)
```

`UrgentPanel` has one box per phone event (and `usage`), and only the
ones ticked in `EventsPanel` are enabled. The From and To boxes and
the panel are disabled while the box is unticked, but keep their
values, so re-ticking restores them. A bad time blocks Save with
`Quiet hours: times like 07:00, and not the same twice.` All of these
join the snapshot, form reader and change builder of
[src/phone-setup.ps1](src/phone-setup.ps1).

### Time zones and clocks

- **The PC's local time**, not the phone's. The window says
  `this PC's clock`. A laptop that moves zones follows its own clock.
- **DST:** time-of-day comparisons. On a spring-forward night, a
  02:00-03:00 window is simply shorter. On a fall-back night, the
  repeated hour is in the window both times. No special case.
- **Sleep:** a PC asleep through the whole window wakes after `To`.
  Nothing was held (nothing ran), so no summary.
- **Overnight** is the normal case, `From > To`. A daytime window
  (`09:00-12:00`) works the same way.

### Edge cases

- **A reply from the phone during quiet hours:** the answer push is
  `reply` and `-Loud`, so it goes. You are awake and just asked.
- **Pairing at night:** goes.
- **A held `started`, then its `done`,** both in the window: both
  lines are in the summary. Join per-chat replacement doesn't apply
  to held alerts.
- **Quiet hours changed mid-window:** the next `Send-ChatqAlert` reads
  the new window. Held alerts stay held until whichever window is now
  in effect ends.
- **Urgent event while at the PC:** presence wins. Toast only, as
  today.
- **`-Test` during quiet hours:** `-Loud`, so it goes. The test output
  says `quiet hours now - only urgent alerts and tests go`.

### Tests

`tests/sections/alert-channels.ps1`, with a new clock seam:
`$script:ChatqClockSeam`, a `[datetime]` that
[Send-ChatqAlert](src/alerts.ps1) and `Send-ChatqHeldSummary` read in
place of `Get-Date`.

1. `Test-ChatqQuietNow`: 23:00-07:00 at 22:59 (out), 23:00 (in), 03:00
   (in), 06:59 (in), 07:00 (out), with `Until` the right date across
   midnight; 09:00-12:00 at 08:59, 09:00, 11:59, 12:00;
   `Get-ChatqQuietHours` with `07:00-07:00`, `7-9`, `25:00-01:00`,
   missing → off.
2. `Send-ChatqAlert` at 03:00 with `$script:ChatqJoinSeam` counting:
   - `done` → no Join call, one `held.jsonl` line, returns `$false`;
   - `failed` → sent;
   - `test -Loud` → sent;
   - at the PC (`ChatqIdleSeam` 10) → toast only, nothing held;
   - an event not in `phoneEvents` → nothing held;
   - `CHATQ_QUIET=1` reaches the command's environment (the existing
     command seam);
   - no reply alert is registered for a held one.
3. Summary: at 07:01 the next `Send-ChatqAlert 'done'` sends
   `summary` first, then `done`. The file is gone. The text starts
   `held 00:00-07:00: 1 done`. Also:
   - 210 held → 200 kept, 700-char cap, `and N more`;
   - Join seam failing → lines back in `held.jsonl`, no retry within
     5 min;
   - a `.sending` 11 min old → taken back;
   - two callers at once → one summary (the rename claim).
4. Hold write fails (lock held by the test) → sent instead.
5. `Set-ChatqNotifyConfig`: `QuietHours '00:00-07:00'` saved; `off`
   with held lines sends a summary; bad values refused with nothing
   saved; `Urgent none` → `[]`.
6. Watcher pass and outbox sender each call `Send-ChatqHeldSummary`
   (seamed): once per pass when the file is there, not at all when
   not.
7. Setup window (the STA tests in `tests/sections/phone.ps1`): the
   snapshot changes with each new control; a bad time blocks Save with
   the message; unticking keeps the times.
8. Manual: set `-QuietHours` to the next 5 minutes, queue a job that
   finishes inside them, and check that the summary arrives at the
   end.

### Out of scope

- Per-day schedules (weekends), several windows, and the phone's own
  time zone.
- Holding the toast, or the user's command, on chatq's side (the
  command gets `CHATQ_QUIET` and decides).
- A summary that can answer each held job. Its ids would have to be
  registered at hold time, which re-opens the reply window all night
  for nothing.
- Android's own Do Not Disturb. Join's priority 2 may break through it
  depending on the phone. That is the phone's setting.

---

## 3. Voice

### Research

Join's `sendPush` ([joaoapps.com/join/api](https://joaoapps.com/join/api/)):
`say`, "Say some text out loud", and `language`, "The language to use
for the **say** text". The page gives no format for `language`. The
receiving side is Android text-to-speech, which takes an ISO 639-1
code (`ko`, `en`) or a locale (`ko-KR`). chatq sends the two-letter
code. The first real test on the phone (TESTING.md) checks that
`language=ko` reads Hangul in Korean. If it doesn't, the fallback is
`ko-KR`, and the spec's table changes in one place
(`Get-ChatqSayLanguage`).

Join cannot tell whether headphones are in. `say` speaks on whatever
the audio output is, the speaker included. That is why voice is **off
by default** and chosen per event. Headphones-only is a Tasker job
(out of scope).

ntfy has no text-to-speech. Voice is Join only.

### Behaviour

An alert whose event is in `join.say` carries a short spoken line
besides its notification. The line is `<chat> needs input`, not the
alert's text: the end of a reply read aloud in a room is the wrong
default, and long text is slow to hear.

| event | spoken (English) | spoken (Korean) |
|---|---|---|
| `needs input` | `<title> needs input` | `<title> 입력을 기다립니다` |
| `done` | `<title> is done` | `<title> 끝났습니다` |
| `failed` | `<title> failed` | `<title> 실패했습니다` |
| `limited` | `<title> hit the limit` | `<title> 한도에 걸렸습니다` |
| `overloaded` | `Claude is overloaded` | `Claude 과부하` |
| `waiting` | `<title> is still busy` | `<title> 아직 작업 중입니다` |
| `started` | `<title> started` | `<title> 시작했습니다` |
| `usage` | `Claude usage at 91 percent` / `Claude limit reset` | `Claude 사용량 91퍼센트` / `Claude 한도 초기화` |
| `test` | `chatq test` | `chatq 테스트` |

- `<title>` is the job's or chat's title cut to 40 characters, never
  splitting an emoji. With no title, it is `a chat` / `채팅`.
- **Language** (`join.sayLanguage`, default `auto`): `auto` is `ko`
  when the spoken line's title holds Hangul (U+AC00-U+D7A3, or Jamo
  U+1100-U+11FF, U+3130-U+318F), else `en`. `en` or `ko` forces one
  table. Any other code (`ja`, `de-DE`) is sent as `language` with the
  English table. It is checked against `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$`.
- **Length cap:** the spoken line is at most 100 characters.
- **Never** for:
  - an event not in `phoneEvents`. Voice rides on the push, and a push
    that isn't sent can't speak.
  - a held alert (quiet hours), nor an urgent one sent during quiet
    hours.
  - the summary, `reply` and `pair`.
  - `-Quick` pushes (inside a run). Those are always `reply` pushes
    anyway.
- `test` is speakable when the user put it in `join.say`. That is how
  the window's **Send test** proves voice works.

### Mechanics

- [Get-ChatqJoinUrl](src/alerts.ps1) gets `[string]$Say` and
  `[string]$Language`, added to the query after `text` as `say` and
  `language`. They count towards the 1900-character URL budget.
  Trim order when too long: first the text (as now, down to 20
  characters), then `say` (dropped whole), then the icon, then the
  title inside the reply link. Spoken words matter less than a
  readable notification.
- New `Get-ChatqSayText $Event $Job $Text $Cfg` returns `@{ Say;
  Language }` or `$null`. `$Text` is used only for `usage`, to lift
  the percent with `\b(\d{1,3})%`. New `Get-ChatqSayLanguage $Cfg
  $Title`.
- [Send-ChatqJoin](src/alerts.ps1) gets the event (a new `$Event`
  parameter from [Send-ChatqAlert](src/alerts.ps1)) and the quiet-hours
  state. It calls `Get-ChatqSayText` only when the event is in
  `join.say`, not in quiet hours, and not `-Quick`.
- The spoken line passes through Join's servers, as the notification
  text already does. It is shorter than that text, so there is no new
  exposure. The table in README "What passes through whose servers"
  gains: `and, for the events you chose, a spoken line: the chat's
  title and what happened`.

### Config, flags, window

```json
"join": { ..., "say": ["needs input"], "sayLanguage": "auto" }
```

| key | default | |
|---|---|---|
| `join.say` | absent = none | the events read aloud |
| `join.sayLanguage` | `auto` | `auto`, `en`, `ko`, or another language code |

| `chatnotify` flag | |
|---|---|
| `-Say 'needs input', failed` | read these aloud on the phone (Join); `none` for none |
| `-SayLanguage auto\|en\|ko\|<code>` | the spoken language |

In `Set-ChatqNotifyConfig` (keys `Say`, `SayLanguage`), `Say` needs
Join set up: `reading aloud is Join's - set up Join first (chatnotify
-Setup, or -ApiKey)`. A spoken event that is not a phone event is
saved, with a warning: `failed is not among the phone's events - it
is never read aloud until it is (-Events)`. Saved:
`read aloud on the phone: needs input, failed (language: auto - Korean
for a Hangul title)`. Plus the warning line, shown every time:
`Join speaks through the phone's speaker as well as headphones`.

**Setup window,** in the JOIN section under Send test:

```
Read aloud:  [x] needs input  [ ] failed  [ ] done  [ ] test ...   (SayPanel)
Join speaks it on the phone - through its speaker too, if no headphones are in.
```

One box per phone event, `usage` and `test`. A box whose event is
unticked in `EventsPanel` is disabled, and unticked on Save, with the
note. The whole panel is disabled with no Join key saved or pasted.
The language is config and flag only: it is rarely changed, and `auto`
covers Hangul and English.

### Edge cases

- **A Hangul title with an English template:** never. `auto` picks the
  table from the same title it speaks.
- **An emoji in the title:** passed as is. TTS engines skip or name
  it.
- **Per-chat notifications (`join.perChat`):** a `done` that replaces
  `started` still speaks. Join speaks per push, not per notification.
- **Join ignores `say` on an old app version:** the push still arrives
  silently. Nothing to detect.

### Tests

`tests/sections/alert-channels.ps1`, through `$script:ChatqJoinSeam`
(it gets the URL):

1. `join.say = ['needs input']`: a `needs input` URL has
   `say=<escaped "Parser rewrite needs input">&language=en`; a `done`
   URL has no `say`.
2. A Hangul title → Korean table, `language=ko`; `sayLanguage en` with
   a Hangul title → English table, `en`; `sayLanguage 'de-DE'` →
   `language=de-DE`; `sayLanguage 'x y'` → treated as `auto`.
3. A 90-character title → 40 in the spoken line, and the line at most
   100.
4. A URL over budget: the text is trimmed first; with the text at 20
   characters still over, `say` goes before the icon.
5. Never: an event not in `phoneEvents`; quiet hours (clock seam) for
   an urgent one; `-Quick`; `reply`, `pair`, `summary`.
6. `Set-ChatqNotifyConfig`: `Say` with no Join → refused; an unknown
   name → refused; a non-phone event → saved with the warning;
   `none` → key removed.
7. Manual (TESTING.md): `chatnotify -Say test` then `-Test`, heard on
   the phone; a Hangul-titled chat heard in Korean (`language=ko`
   check).

### Out of scope

- Headphones-only speech, and speech on ntfy or the toast.
- Reading the reply's end aloud.
- A language picker in the window.

---

## 4. Reply without the browser (Tasker)

Closes, in its simplest form, FUTURE_WORK's "An inline reply without
the browser" (its option 3).

### Behaviour

The page accepts one more fragment field on an alert link, `text=`. It
fills the reply box with it. **It never sends.** The page opens with
the text in the box, the counter updated, and a line under it:
`Filled in from outside the page - check it, then Send.` You tap
**Send**, as always.

A Tasker profile does the rest. The user types the reply in a
notification's reply field, and Tasker opens the alert's own link
with `&text=<what was typed>` added. That is one tap in the browser
instead of typing there.

### Why never auto-send

The page holds the phone's key. It can't export it, but anything that
opens the page can have it *used*. An alert link is not secret:

- its alert id travels in the Join push, a GET logged in full on
  Join's servers;
- the notification is on the lock screen;
- a link opened from anywhere reaches the same page: another app, a
  web page, a QR code, a browser restoring its tabs, a link preview's
  prefetch.

If a link could send, then anyone who saw one alert's id could build
`#v=2&a=<aid>&...&text=<any prompt>&send=1`, get the phone to open it
once, and the page would seal and post a prompt with the phone's own
key. The MAC would check out, and the prompt would run on the PC, in
`acceptEdits`. The MAC proves that this phone's page sealed the
message. It does not prove that the person meant it. The tap on
**Send** is the only thing that does. A reload or a restored tab would
also send again (with a new nonce, so the replay check would not
catch it).

So: nothing in any link sends, acts, confirms or presses a button, and
`text` is only ever typed into the box. This rule goes in a comment
next to the new code in `parseFragment`.

### The page

In [docs/reply.html](docs/reply.html)'s `ChatqPage` block (tested
under Node):

- `parseFragment`, alert mode only: `text` is read on its own. `+` is
  turned into a space first (Tasker's and Java's URL encoders write
  spaces as `+`; a real `+` arrives as `%2B`). Then
  `decodeURIComponent`. A decode failure, or a value over 16,000
  characters, gives `f.text = ''`. It never makes the whole link
  `bad`: the alert still opens. Control characters other than `\n`
  and `\t` are removed. `\r\n` becomes `\n`. The result is trimmed.
  It is ignored (`''`) on a pairing link, and on a `v=1` link (already
  refused whole).
- `alertFragment` does **not** keep `text`. The kept per-tab alert
  never carries the typed words. They go into the draft instead
  (below).
- New `prefill(spec, f, draft)` → `{ text, note }`:
  - `spec.text` false (a test, a jobless alert, a usage alert):
    `{ text: null }`. The box is hidden, the text is dropped, and the
    note says `This alert takes no text - what was sent along was left
    out.`
  - otherwise `f.text` wins over a saved draft, with the note above.
    When the draft held different text, the note adds ` It replaced
    what was typed here before.`
  - no `f.text`: the draft as today, no note.

In the page code (not the tested block):

- `readLink` already strips the bar (`stripBar`) for an alert link, so
  the text leaves the address bar at once.
- `render()` puts `prefill`'s text into the box, then calls
  `saveDraft()` so a reload keeps it (per tab, `sessionStorage`, as
  typed text is today). It shows the note in `#hint`'s place (a new
  `#prefill` line, `data-kind="note"`) and focuses the box with the
  cursor at the end. **Send** is enabled or not by the counter, as
  always. Text over the limit shows `N bytes too long`, and Send stays
  off.
- `hashchange` with a new link (the same tab, a second Tasker reply)
  goes through `init()` as now, so the new text fills the box, and a
  pending sealed message for other text is dropped by the existing
  `input` rule.
- An unpaired phone shows the `unpaired` card as now. The text is not
  kept.

The key stays in the page (IndexedDB, not exportable). Tasker never
sees it, and nothing is sealed outside the page.

### The Tasker recipe (README, under Reply from the phone)

**What was checked, and what wasn't.**
- AutoNotification **Intercept** can match Join's notification. It
  sees any app's notification through Android's notification listener:
  app filter Join, title filter `chatq ·`, with `%antitle` and
  `%antext` set. But it **cannot** read the link a tap opens (a
  notification's tap target is an Android PendingIntent, not text).
  So Intercept alone cannot build the reply URL.
- The link has to come from Join itself: Join's Tasker event for a
  received push, whose variables include the push's URL. The variable
  names (`%joinurl` is expected) and whether the event fires for a
  push that also makes a notification are **not confirmed** by Join's
  docs (the pages found were navigation only). Step 1 below checks
  both on the phone before anything else is built.
- AutoNotification can post its own notification with a reply field.
  The variable that carries what was typed is not named in any page
  found (`%anreply` is the likely name). Step 4 checks it. If it is
  absent, route B needs no AutoNotification at all.

**Route A: reply field in a notification (Tasker + AutoNotification +
Join).**

1. **Check Join's event.** Profile → Event → Plugin → Join → *Push
   Received* (Join's own event). Task: Flash `%jointitle | %joinurl`.
   Then `chatnotify -Test` with the phone away from the PC. The flash
   must show `chatq · test | https://…/reply.html#v=2&a=…`. If the
   variable list (the tag icon in the task) names the URL differently,
   use that name below. If the event never fires for chatq's pushes,
   stop here: route A can't work on that Join version.
2. **Filter.** In that event, set Title to `chatq ·*` (Tasker
   wildcard), so only chatq's alerts trigger it. Tasks don't pass
   variables from one task to another, so in the Entry task:
   Variable Set `%ChatqLink` to `%joinurl` and `%ChatqTitle` to
   `%jointitle`.
3. **Show a notification with a reply field.** AutoNotification →
   Notify: Title `%ChatqTitle`, Text `%jointext`, a *Reply* action with
   the command `chatqreply`, and Id `chatq`. Join's own notification
   stays too. Cancel it with AutoNotification Cancel (app Join, title
   `chatq ·*`) if you want only one.
4. **Catch the reply.** Profile → Event → Plugin → AutoNotification
   (the event for your own notification's actions), Command filter
   `chatqreply`. First check with a Flash which variable holds the
   typed text (`%anreply`, per the variable list).
5. **Open the page with it.** Entry task:
   - Variable Convert `%anreply` → *URL Encode*, into `%ChatqText`.
   - Browse URL `%ChatqLink&text=%ChatqText`.

   The link already ends inside its `#` part, so `&text=` joins the
   fragment. Nothing after `#` is sent to any server.
6. The page opens with the text in the box. Check it, tap **Send**.

**Route B: no AutoNotification.** Steps 1-2 as above. Then the Entry
task:
- Input Dialog (Tasker's *Input Dialog* action, title
  `%ChatqTitle`) → `%input`.
- Variable Convert → URL Encode.
- Browse URL `%ChatqLink&text=%ChatqText`.

It is a Tasker dialog on the alert instead of a reply field in the
notification. It is the same one tap on Send.

README also says:
- **Send is still a tap in the browser.** On purpose, and why, in one
  sentence: a link that sent by itself could be opened by anything, and
  would send with your phone's key.
- **The typed text is in the page's address** until the page takes it
  out (at once). It is also in whatever Tasker keeps. Browsers may keep
  the address in their history, fragment included, so treat it like
  anything typed into the browser.
- **Only alerts that take a prompt** use it: not a test, a usage alert
  or the summary.

### Edge cases

- **The same alert link opened twice with different text:** the
  second fills the box, and the note says it replaced what was there.
- **The alert expired:** the page fills the box. The PC refuses on
  Send with the existing refusal push (`that alert expired - reply to
  a newer one`).
- **`text=` on a jobless or test link:** dropped, with the note.
- **Emoji and Hangul:** `%XX` UTF-8, decoded by `decodeURIComponent`.
  Tasker's URL Encode writes UTF-8.
- **Broken encoding** (`%E0%A4`): `f.text` is empty. The alert still
  opens, with no note.
- **A long text:** the counter shows it's over, and Send stays off
  until it is shortened. Nothing is cut silently.
- **`send=`, `act=` or any other made-up field:** ignored, as unknown
  fields are today.

### Tests (`tests/reply-page-check.js`)

1. `parseFragment('#v=2&a=abcdefghij&e=done&n=3&c=x&text=hello%20world')`
   → `ok`, `f.text === 'hello world'`.
2. `+` → space; `%2B` → `+`; Hangul `%ED%95%9C` → `한`; an emoji
   (4-byte UTF-8) survives; `%0D%0A` → `\n`; `%00` removed.
3. `text=%E0%A4` → `ok: true`, `f.text === ''`: the link is not `bad`.
4. `text` on a pair link: `f` has no `text`. On `v=1`: `old`, as now.
5. `alertFragment(f)` never contains `text` (the kept alert has no
   typed words).
6. `prefill`: a test spec → `text: null` with the note; a `done` spec
   with `f.text` and no draft → the text and the note; with a
   different draft → the note with "replaced"; no `f.text` → the draft
   and no note.
7. **No auto-send:** the page source has no call to `press(`,
   `deliver(` or `seal(` outside the click and keydown handlers and
   `press` itself. A static check over the logic and page blocks, so
   a later change can't add one without failing the test. Also,
   `parseFragment` output has no field that names an act.
8. Manual (TESTING.md): route B on a real phone. Type `테스트 ok` in
   the dialog, the page opens with it in the box, Send, then the
   `queued #N` push.

### Out of scope

- Sealing in Tasker, which would need a second, readable phone key
  (FUTURE_WORK's options 1-2).
- A chatq-side Tasker-only push (Join text with no title, so no
  notification). It would add a `join.tasker` mode. Only worth it if
  step 1 shows Join's event does not fire for notification pushes.
- iOS: no Tasker.

FUTURE_WORK's entry is then rewritten: the prefill and the recipe
shipped, and what stays open is a reply that needs no tap in the
browser at all, with why (the Send tap is the consent).

---

## Where they meet

In [Send-ChatqAlert](src/alerts.ps1), for the phone channels, in this
order:

1. `Test-ChatqPhoneEvent` (`summary` always passes; `usage` needs
   ticking).
2. Presence (`quietMinutes`): at the PC → toast only. Nothing is held,
   and nothing is spoken.
3. Quiet hours: held, unless urgent or `-Loud`.
4. Voice: only when sent, not in quiet hours, event in `join.say`.
5. Reply link (`w=1` for a soon usage alert), then the channels.

`chatnotify` alone prints, after the live-alerts line:

```
  usage    at 90% (the overlay checks) · resets on
  quiet    00:00-07:00 · failed comes through · now until 07:00 · 3 held
  voice    needs input, failed · language auto
```

The README Alerts section gains a subsection for each feature
(**Usage heads-ups**, **Quiet hours**, **Read aloud**, **Reply from
Tasker**). Its event table gains:
- `chatq · usage` (priority 0/1): a window at a threshold, a reset
  coming with prompts queued, or one that came.
- `chatq · summary` (priority 1): what quiet hours held.

The page's button table gains `usage` (**Send now** · Status, or
Status) and `summary` (Status). CHANGELOG gets one entry per feature.
TESTING.md gets the manual steps listed above.
