# Spec: the PC -> phone channel - whole answers, and any chat from the phone (chatq 0.9.0)

0.8.0 as built is documented in README.md's "## Alerts" section and CHANGELOG.md; its security choices (no key in any push, MAC-verified replies, reply.maxMode, pairing by code, rate limits) hold here. Everything
settled there stays: no key in any push, every phone -> PC message MAC-verified under a key
derived from the phone's D, spent nonces durable before acting (Use-ChatqReplyState), pairing
by code, `reply.maxMode` caps every job the phone makes or requeues, `-NoLinks` on phone text,
refusals rate-limited, nothing sent or waited on inside the replies lock, the PC outbound-only.
The command is `chatnotify` now (`chatqnotify` stays an alias); every string below says
`chatnotify`, the page's `PAIR_CMD` included.

Two features, one channel:
- **(a) Read the whole answer.** A `done`, `needs input` or `failed` alert's page shows the
  chat's whole last reply, not the 200-character excerpt, above the box you answer in.
- **(b) Any chat, from a bookmark.** The paired phone opens the bare page URL (a bookmark or a
  home-screen shortcut, no alert), gets its recent chats and known folders from the PC, picks
  one, types, sends - or starts a new chat in a folder.

Both need the PC to send something to the phone. Today nothing does: the page only POSTs.

---

## 1. What ntfy allows (checked 2026-09-26)

| fact | value | source |
|---|---|---|
| message body | 4,096 bytes; a bigger body becomes an attachment by itself | docs.ntfy.sh/publish |
| message cache | 12 h (`messages_expiry_duration` 43200) | `GET https://ntfy.sh/v1/account`, docs.ntfy.sh/config |
| anonymous messages | **250 per day per IP** (`"basis":"ip","messages":250`) | `/v1/account` |
| anonymous attachment | **2 MB** each, **20 MB** live per IP, **3 h** expiry, 350 MB/day bandwidth | `/v1/account` |
| request rate | burst 60, then one per 5 s (config default) - ntfy.sh's FAQ says one per 10 s; design for 10 s | docs.ntfy.sh/config, /faq |
| poll | `GET /<topic>/json?poll=1&since=<10m\|unix s\|message id\|all\|latest>`, NDJSON | docs.ntfy.sh/subscribe/api |
| filters | `id=`, `message=`, `title=` (exact), `priority=`, `tags=` | same |
| attachment in JSON | `attachment: {name, url, type, size, expires}`; `url` is `https://ntfy.sh/file/<id>.<ext>` | same |
| upload | `PUT /<topic>` with body = file, header `X-Filename` (and `X-Title`, `X-Message`) | docs.ntfy.sh/publish |
| CORS | `Access-Control-Allow-Origin: *` on `/<topic>/json` (200) and on `/file/...` (GET 404 carries it too); preflight allows GET, PUT, POST, headers `*` | `curl -H "Origin: https://phal40lax78.github.io"` against ntfy.sh |

So the page, whose CSP is `connect-src https:`, can `fetch` a topic's JSON and an attachment
from ntfy.sh with `mode: 'cors'`, `credentials: 'omit'` - no change to the CSP.

**Chunking vs attachment - decided: one message, inline when it fits, else one attachment.**
- Chunks would spend the 250-a-day message budget the PC's IP also spends on ntfy alerts: a
  30 KB answer is ~11 chunks. An attachment is one message whatever its size.
- An attachment lives 3 h, an inline message 12 h (= `reply.hours`). So the payload is
  **raw-deflated before it is sealed**, which keeps most answers inline (a 9 KB answer, Hangul
  included, deflates to well under 3 KB), and an expired attachment is fetched again on demand
  (act `read`, section 6).
- Deflate before encryption leaks the compressed length, which ntfy.sh sees either way to within
  16 bytes; nothing an attacker controls is mixed with a secret in one message they can
  re-trigger at will. Accepted.

---

## 2. Keys, topic and wire formats

All from the phone's D (32 bytes), which the PC holds as `reply.key` and the page as a
non-extractable HMAC CryptoKey - `sign` is all the page needs, so **no re-pairing**: a phone
paired on 0.8.0 gets both features as it is.

```
downTopic = "chatq-" + 24 chars, char i = "abcdefghijklmnopqrstuvwxyz234567"[h[i] % 32],
            h = HMAC-SHA256(D, "chatq-down-topic")                  (unbiased: 256 % 32 == 0)
k_alert   = HMAC-SHA256(D, "chatq-alert:" + aid)                     existing, phone -> PC
k_phone   = HMAC-SHA256(D, "chatq-phone:" + cid)                     new, phone -> PC, no alert
k_down    = HMAC-SHA256(D, "chatq-down:"  + did)                     new, PC -> phone
enc = HMAC(k, "enc"), mac = HMAC(k, "mac")                           as now, for every k
```

- The down topic is known only to the PC and the phone: it is in no push, no link, no config
  file (worked out each time). Nobody else can read its timing or post junk to it; the MAC is
  still what makes a message count. It changes with every pairing, as D does.
- Distinct labels mean a message sealed one way never opens another way: a PC -> phone message
  posted back to the reply topic fails the watcher's MAC (and its prefix), and the reverse.

**Phone -> PC, not about an alert** (the reply topic, as replies are):
```
head    = "chatq3c." + cid + "." + b64url(iv) + "." + b64url(AES-256-CBC(enc, iv, utf8(json)))
message = head + "." + b64url(HMAC(mac, head))
cid     = 10 random chars [a-z2-7], new per message, chosen by the page
json    = {"v":3,"act":"<act>", ...fields in the order section 5 gives..., "nonce":"<16 bytes b64url>","ts":<unix ms>}
```
Not deflated (it is small: the page's `MAX_PAYLOAD` 2900 stays). `cid` diversifies the key only;
what makes a message count is the MAC, the nonce and the time.

**PC -> phone** (the down topic):
```
head    = "chatq3d." + did + "." + b64url(iv) + "." + b64url(AES-256-CBC(enc, iv, deflateRaw(utf8(json))))
message = head + "." + b64url(HMAC(mac, head))
did     = the alert's aid (a whole answer) or the request's cid (a list, an ack)   [a-z2-7]{10}
ntfy title = did          (so the page asks for exactly its message: &title=<did>)
```
`deflateRaw` is RFC 1951 with no header: .NET's `System.IO.Compression.DeflateStream`
(5.1 and 7) writes and reads it; the page reads it with `DecompressionStream('deflate-raw')`
(Chrome 103+/Android, Safari 16.4+, Firefox 113+). A browser without it gets the card
`This browser cannot open the whole answer` and everything else still works.

The page checks, in order: 5 parts, prefix `chatq3d`, `did` shape and equal to the one it asked
for, MAC in constant time (a compare over every byte, as `Test-ChatqSameBytes`), then decrypt,
then inflate with an output cap of 4 MB (a deflate bomb stops there), then JSON with
`v === 3` and `ref === did`. Anything else is dropped in silence and the next message looked at.

---

## 3. Config and state

`data/config.json`, `reply` block (all through `Set-ChatqNotifyConfig`):

| key | default | |
|---|---|---|
| `reply.full` | `true` | send the whole answer with `done`, `needs input`, `failed` alerts |
| `reply.fullMax` | `30000` | characters of it at most; over that the **end** is kept (the conclusion is at the end) and the page says how much was left out |
| `reply.compose` | `true` | the phone may list chats, queue to any of them and start new ones |
| `reply.newMode` | `default` | the mode a chat started from the phone runs in, then capped at `reply.maxMode` |
| `reply.listen` | `alerts` | `alerts`: the watcher listens while an answerable alert is out (as now). `always`: while a phone is paired, it listens all the time (section 7) |
| `reply.downPerDay` | `150` | whole answers sent per day at most; lists and acks stop at `downPerDay + 50`. The rest of ntfy.sh's 250 is left to alerts |

`Set-ChatqNotifyConfig` keys: `FullText` (on/off/bool), `FullMax` (int 2000..200000),
`Compose` (on/off/bool), `NewMode` (on the ladder), `Listen` (`alerts`|`always`). Validation
first, nothing saved on a bad value, as the existing keys do. `chatnotify` switches:
`-FullText on|off`, `-Compose on|off`, `-Listen alerts|always`, `-NewMode <mode>`. `FullMax`
and `downPerDay` are config-only (the table under "A few settings are only in config.json").

`data/replies.json` gains (read in `Get-ChatqReplyState`, written and pruned in
`Save-ChatqReplyState`, changed only in `Use-ChatqReplyState` blocks):
```
"picks":     { "<h>": { "kind":"chat"|"folder", "sessionId", "provider", "path", "cwd", "home",
                        "title", "at", "expires" } }     pruned past expires; 300 at most, oldest first
"standing":  true | false                                 listen=always is in effect (section 7)
"compose":   [ "<iso>", ... ]                             when each compose act was taken; pruned past 1 h
"down":      { "day": "yyyy-MM-dd", "full": n, "other": n }   the day's down messages (local date)
"composeRefusedAt": "<iso>" | null                        the last refusal ack, for its rate limit
"hotUntil":  "<iso>" | null                               fast polling after a compose act (section 7)
```
`home` in a pick follows the live-alert rule: `$null` for the default config dir, else the dir.

---

## 4. (a) The whole answer with an alert

### PC side
- **`Get-ChatqTurnText -Path <transcript> [-Max 30000]`** (src/phone.ps1) -> `@{ Parts; Cut; At }`
  or `$null`. Walks the transcript tail back (`Read-ChatqTail`, 4 MB, then 16 MB) to the last
  **real prompt**: a `type:"user"` record, not `isSidechain`, not `isMeta`, whose content is a
  string or holds a `text` block and no `tool_result`. Everything after it, in order:
  `assistant` text blocks -> `@{ t='text'; s=<text> }`; `tool_use` -> `@{ t='tool'; s='<name> <first
  line of command|file_path|pattern>' }` (the shape `Get-ChatqLogEntries` already uses).
  `<synthetic>` model records (limit, 529) become one `t='note'` part with their text. `At` = the
  last record's timestamp. Over `-Max` characters: parts are dropped from the front, the first
  kept one cut at a surrogate-safe point, `Cut` = characters left out.
- **`Get-ChatqJobTurnText -Job <job> [-Max]`** -> the same shape, for a job the watcher ran:
  `Get-ChatqLogEntries $Job -MaxBytes 8MB`, only the entries after the log's last `init`
  (one run), `text` and `tool` kept - Claude and Codex alike, since the job log has both.
  Falls back to `Get-ChatqTurnText $Job.path` for a Claude job with no log.
- **`Send-ChatqReplyText -Rc -Aid -Event -Job [-Quick]`** -> `$true` when the down message went.
  Only when `reply.full`, the event is `done`, `needs input` or `failed`, `$Job.sessionId` is
  set, the text is not empty and the day's `down.full` is under `downPerDay` (counted in a
  `Use-ChatqReplyState` block *before* the send, never inside it). Text from
  `Get-ChatqJobTurnText` when `$Job.id`, else (a live alert) `Get-ChatqTurnText $Job.path`.
  Payload:
  ```
  {"v":3,"kind":"reply","ref":"<aid>","ts":<ms>,"event":"done","title":"<chat title>",
   "at":"<iso, turn end>","cut":0,"parts":[{"t":"text","s":"..."},{"t":"tool","s":"Bash git status"}]}
  ```
- **`Send-ChatqDown -Rc -Did -Body <ordered hashtable> [-Quick]`** -> `@{ Ok; Error; Bytes;
  Attached }`. Seals with `Protect-ChatqDownMessage`. Sealed length <= 3,900 bytes: `POST
  <server>/<downTopic>` with the sealed text as a `text/plain` body. Longer: `PUT
  <server>/<downTopic>` with the sealed text as the body and headers `X-Filename: <did>.txt`,
  `X-Message: chatq`. Both carry `X-Title: <did>`, `X-Firebase: no` (ntfy.sh forwards nothing to
  Google), `X-Cache: yes`, priority 1 (`X-Priority: 1`). Over 1.9 MB sealed, or a PUT the
  server refuses (a self-hosted ntfy without attachments answers 400/413): the parts are cut
  from the front until the sealed text fits inline, `cut` says how much, sent inline. One try
  with an 8 s timeout (`-Quick` or not: it goes ahead of the push, which must not wait 60 s).
  Seam `$script:ChatqDownSeam` `{ param($Method, $Url, $Headers, $Body) }` -> `$null` sent,
  or an error string. Never throws; failures to `replies.log`, one line per 10 min.
- **`Send-ChatqAlert`** (src/alerts.ps1), in the branch that registers an answerable alert:
  after `New-ChatqReplyAlert` and **before** the channel loop:
  `$full = Send-ChatqReplyText $rc $reply.Aid $Event $Job -Quick:$Quick`, then
  `$reply.Link = Get-ChatqReplyLink $rc $reply.Aid $Event $Job -Full:$full -At <alert unix s>`.
  Not for `-PairLink`, `-NoReply`, or events other than the three.
- **`Get-ChatqReplyLink`** gains `-Full` (adds `r=1`) and `-At` (adds `w=<unix seconds>`; every
  alert link gets `w`). Join's 1,900-character budget: +19 characters, still fits (the trimming
  in `Get-ChatqJoinUrl` is unchanged).
- The live path needs nothing new: the outbox sender calls `Send-ChatqAlert` with
  `ConvertTo-ChatqLiveJob`, whose `path` is the transcript.

### Page side (alert mode)
- `parseFragment` reads `r` (`'1'` or absent) and `w` (`^[0-9]{9,11}$`); `alertFragment` keeps both.
- On render, when the event is `done`, `needs input` or `failed` and the alert is about a chat:
  a **reply panel** above the compose box. It fetches
  `<server>/<downTopic>/json?poll=1&since=<w - 120, else 12h>&title=<aid>` and takes the
  **newest** message that opens (an answer sent again on `read` is newer). A message with an
  `attachment` is fetched from `attachment.url` only when that URL's origin is the server's and
  its path starts `/file/`, and `attachment.size` <= 2 MB (the body is read up to 2 MB, then
  aborted).
- With `r=1` and nothing yet: polls every 4 s, up to 30 s (the push can beat the POST that went
  before it only by a race; this covers it). Without `r=1`: one look, then the button.
- States and text:

| state | panel shows |
|---|---|
| loading | `Getting the whole answer...` |
| shown | the answer (rendering below); above it `Claude's answer - 14:02` (`at`), and when `cut` > 0: `The first 12,345 characters are left out.` |
| none (no `r`, or 30 s passed) | `The whole answer is not here.` button **Ask the PC for it** (act `read`, section 6) |
| attachment expired (404 / `expires` passed) | `ntfy.sh keeps a long answer 3 hours - that one is gone.` button **Ask the PC for it** |
| asked | `Asked - the PC sends it within about 15 s while it listens.` then polls 4 s x 60 s |
| no answer to the ask | `No answer. The PC may be asleep, or no longer listening for this alert.` |
| cannot open | `This browser cannot open the whole answer.` (no `DecompressionStream`) |

- **Rendering** - plain text, a small subset of markdown, built with `createElement` and
  `textContent` only (a page check fails on any `innerHTML`, `outerHTML`, `insertAdjacentHTML`
  or `document.write`):
  - ```` ``` ```` fences -> `<pre><code>` with the language word dropped; horizontal scroll
    inside the block, never the page.
  - `` `x` `` -> `<code>`; `# ...` lines -> a bold line; `**x**` -> `<strong>`; list and table
    lines kept as they are (tables: lines starting `|` go in one `<pre>`, monospace).
  - Links stay text, the URL visible, not clickable (a tap selects).
  - `t='tool'` parts: one muted line, `-> Bash git status`; three or more in a row fold into
    `-> 5 tools` that expands on tap. `t='note'`: a warn-coloured line.
  - `white-space: pre-wrap; word-break: keep-all; overflow-wrap: anywhere` (Hangul wraps at
    word gaps, long tokens still break). Font stack unchanged (it has Noto Sans KR).
- **Long text:** the panel is at most 45 vh with its own scroll and a fade at the bottom;
  **Show all** makes it full height (the compose box then scrolls into view below it). While
  the keyboard is up (`max-height: 520px`) the panel collapses to one line
  `Claude's answer - tap to read`, so Send stays above the keys. **Copy** copies the whole text
  (`navigator.clipboard.writeText`, on the tap; its failure is `Copy is blocked here`).
- Decrypted text lives in memory only - never in `sessionStorage`, `localStorage` or IndexedDB.
  A reload fetches it again.

---

## 5. (b) Any chat, from a bookmark

### The acts (phone -> PC, `chatq3c.`)
```
{"v":3,"act":"list","nonce":"...","ts":...}
{"v":3,"act":"status","nonce":"...","ts":...}
{"v":3,"act":"send","h":"<chat handle>","id":"<first 8 of its session id>","text":"...","nonce":"...","ts":...}
{"v":3,"act":"new","h":"<folder handle>","name":"<optional title, 60 max>","text":"...","nonce":"...","ts":...}
```
Key order as written: the page's `buildComposePayload` and the vector hold it.

### What the PC answers (PC -> phone, `chatq3d.`, `did` = the request's `cid`)
```
{"v":3,"kind":"list","ref":"<cid>","ts":...,"host":"DESKTOP-M15B07E","cap":"acceptEdits",
 "newMode":"default","listen":"always","until":"<iso openUntil or null>","compose":true,
 "chats":[{"h":"k3m2qa","id":"1a2b3c4d","p":"claude","t":"Parser rewrite","f":"parser",
           "w":"D:\\src","m":"acceptEdits","mc":true,"a":"<iso last activity>",
           "live":"idle|busy|waiting|","q":1,"ni":12}],
 "folders":[{"h":"x7pq2m","n":"proj_AS-BW","w":"d:\\Workspace"}],"more":14}

{"v":3,"kind":"ack","ref":"<cid>","ts":...,"act":"send","ok":true,
 "say":"queued #14 for Parser rewrite - runs in acceptEdits, the phone's limit","seq":14}
```
`m` = the mode it would run in after the cap, `mc` = brought down; `q` = queued jobs for that
chat; `ni` = the seq of a job of it that needs input; `more` = chats not listed.

### PC side
- **`Get-ChatqPhoneList [-Quick]`** -> `@{ Chats; Folders }` with fresh handles.
  - Chats: `Sync-ChatIndex -Provider claude, codex` (skipped with `-Quick`, inside a run: the
    index as it is), then `Get-ChatIndex` rows that are not `Hidden`, newest `Mtime` first, **30**
    at most, plus every interactive live session (`Get-ChatqLiveSessions -RegistryOnly` for the
    watcher's config dir) not already in, found with `Get-ChatqRowById`. Copilot rows never.
  - Per chat: title `Format-ChatTitle 60`; cwd and mode from a **bounded** read -
    `Get-ChatqPhoneChatMeta -Row` reads the transcript's first and last 256 KB only (no
    `Find-ChatqTailString` 64 MB walk), cached in `$script:ChatqPhoneMetaCache` by path +
    `Mtime`. Mode unknown: `m` = the cap, `mc` = `$false`, and the page says `at most
    acceptEdits`. Codex: `m` = its sandbox, `workspace-write` when wider (as `Invoke-ChatqReply`).
  - Folders: distinct existing directories from, in order, the listed chats' cwds,
    `data/console-state.json` `folders`, and the cwds of jobs in the queue; **15** at most. Only
    folders chatq already knows - never one the phone names.
  - Handles: `New-ChatqRandomName 6` each, unique in the batch; written to `picks` with
    `expires` = now + `reply.hours`, in the same `Use-ChatqReplyState` block that records the
    request.
- **`Test-ChatqReplyMessage`** gains a branch: a message starting `chatq3c.` goes to
  `Unprotect-ChatqComposeMessage $Message $Rc.Master` -> `@{ Ok; Stage; Error; Cid; Payload }`
  (same stages and constant-time MAC as `Unprotect-ChatqReplyMessage`; `v` must be `3`). Junk
  at `format`/`mac` is junk as now (does not count against `-MaxMessages`). The result goes in
  a new `Compose` field; `Receive-ChatqReply` hands it to `Receive-ChatqCompose`.
- **`Receive-ChatqCompose -Rc -Id -Message -Checked [-Quick]`** - the order of
  `Receive-ChatqReply`, bound to the phone instead of an alert:
  1. nonce seen (memory, then file) -> dropped in silence, `lastId` moved.
  2. One `Use-ChatqReplyState` block: `lastId`, `lastPolledAt`, the nonce spent, the act's time
     appended to `compose`, `hotUntil` = now + 2 min, and for `list` the new `picks`. A save
     that fails -> `'unsaved'`, nothing done, the message comes back next poll.
  3. Refusals (each answered with an `ack` `ok:false` - MAC checked out, so it is the phone -
     at most one every 60 s, `composeRefusedAt`; replays never answered):

  | check | say |
  |---|---|
  | `reply.compose` off | `the PC does not take chats from the phone - chatnotify -Compose on` |
  | `|age|` > 10 min (`list`, `status`) or > 30 min (`send`, `new`) | `that was sent too long ago, or the phone's clock is off - nothing done` |
  | more than 30 `list`/`status`, or 20 `send`+`new`, or 5 `new`, in the last hour | `too many from the phone this hour - nothing done` |
  | handle unknown, expired, wrong kind | `that list is out of date - refresh it` |
  | `id` is not the first 8 of the pick's `sessionId` | same as above |

  4. `Invoke-ChatqCompose $Payload $Pick -Rc $Rc -Quick:$Quick` -> `@{ Act; Ok; Say; Job }`.
- **`Invoke-ChatqCompose`**:
  - `list`: `Get-ChatqPhoneList`, the `list` down message. No push.
  - `status`: `ack` with `say` = `Get-ChatqPhoneStatusReport`. No push.
  - `send`: the path `Invoke-ChatqReply`'s `prompt` takes, fed from the pick instead of the
    alert entry: text not empty and <= 8,000 characters, `Get-ChatqRowById -Id -Provider -Path
    -Cwd`, `Get-ChatqJobInfo`, the Codex sandbox rule, `Limit-ChatqPhoneMode` on the chat's own
    mode (no old job, so no job mode), `New-ChatqJob -Kind prompt -Rule 'phone' -NoLinks
    -JobHome <pick.home>`. A needs-input job of that chat is **left alone** (unlike an alert
    reply, nothing says the text answers it): `say` adds `- #12 still needs input`. A chat
    live and waiting: the held-at-the-PC wording `Invoke-ChatqReply` uses. A job running in it:
    `- it goes after #11, running now`. Factor the shared body out of `Invoke-ChatqReply`'s
    `prompt` case as **`New-ChatqPhoneJob -Row -Text -Mode -Cap -JobHome -Live`** -> `@{ Error;
    Job; Note }` and call it from both.
  - `new`: the folder pick's `cwd` must still exist; `New-ChatqJob -Kind new -Cwd <cwd> -Title
    <name, control and format characters stripped, 60 max> -Mode <Limit-ChatqPhoneMode
    reply.newMode cap> -Rule 'phone' -NoLinks` (default config dir, `JobHome` `$null` - as the
    console's new chat). `say`: `new chat "<title>" queued as #15 in <folder leaf> - runs in default`.
  - `send` and `new`, when a job was made: the `ack`, **and** `Send-ChatqAlert 'reply' $say 1
    -Loud -Job $job` as every reply is answered - the push is what reaches a phone whose page
    was closed, and its link answers the new job. For `new` the push says less than the sealed
    ack (0.9.0 review): `new chat queued as #15 - runs in default`, never the title - the name
    typed on the phone, or the prompt's first line standing in for one - nor the folder, since
    Join logs its GETs and an ntfy alert topic may be read by others.
  - `continue` (Continue at reset): `New-ChatqPhoneJob -Kind continue`, then the cut-off's
    marker in `data/auto/` as the reset ask's answers write it (`Save-ChatqAskAnswer -Answer
    continue -Source phone -Seqs` the job's number, `-Extra` the chat and its reset), so a skip
    of that job from the phone reads as declined to auto-continue and the reset ask alike.
  - A job act (`now`, `skip`, `stop`, `retry`, `allow`) finds its job by the handle's whole id
    only (`Find-ChatqJob -Exact`), and only when that job still has the handle's number: a job
    queued in the same second for the same chat is that id with `-2`, never taken in its place.
- The watcher is started for nothing new: a `send`/`new` job is picked up by the loop that read
  it, as reply jobs are.

### Page side - the home screen
The bare URL with a paired phone replaces today's `home` card with the **compose home**; the
`unpaired` card stays for an unpaired phone. A bookmark or **Add to Home screen** of the bare
URL is the entry point (a manifest or service worker is out of scope). Opened, it sends `list`
at once (one POST; the user opened it to do this) and polls the down topic
`?poll=1&since=<send time - 60>&title=<cid>` every 4 s.

```
+-----------------------------------------+
| chatq on DESKTOP-M15B07E        Refresh |
| [ Search chats                        ] |
| + New chat                              |
| OPEN NOW                                |
|  Parser rewrite            idle   2m    |
|  parser - claude - acceptEdits          |
|  Radar viewer        waiting on you     |
| RECENT                                  |
|  Plugin unification               3h    |
|  ...                                    |
| Listens all the time - Status           |
+-----------------------------------------+
```
- **Waiting for the list:** three grey rows and `Asking the PC for your chats...`. After 45 s:
  card `No answer from the PC` - body: `It listens while an alert is out, or all the time with
  Listen all the time on (chatnotify -Listen always). A PC that sleeps answers once it wakes, if
  that is within 10 minutes.` - button **Try again**. The same card for a PC older than 0.9.0
  (it drops the act), with the fine line `Or the PC runs a chatq older than 0.9.0.`
- **The list:** two groups, `Open now` (live not empty) then `Recent`. A row: title (2 lines at
  most), then `folder - provider - mode` muted; right side the age (`2m`, `3h`, `4d`) and a
  chip for `waiting on you` / `busy` / `idle` and `#12 needs input`. `mc` shows the mode as
  `acceptEdits (phone's limit)`; unknown mode as `at most acceptEdits`.
- **Search:** filters as you type over title and folder: both sides NFC-normalized,
  `toLocaleLowerCase()`, every space-separated word must occur (any order) - Hangul and English
  alike. Nothing matches: `No chat matches "<q>".` Chats beyond the list: `+14 older chats are
  not listed.`
- **Footer:** from the list's `listen`/`until`: `Listens all the time` or `Listens until 02:10
  (an alert is out)`; a **Status** link (act `status`, answer shown in a status box).
- **Tap a chat -> compose view:** header `Parser rewrite`, below it `parser - claude`, a mode
  chip `acceptEdits` (`phone's limit` when `mc`), and a line from its state:
  `open in VS Code - goes in when it is idle` / `waits on you at the PC - goes once that is
  answered there` / `#12 needs input - this does not answer it; that alert does` /
  `goes next`. The same textarea, byte counter (`MAX_PAYLOAD` 2900) and Send as the alert form;
  a back arrow to the list. Draft per chat in `sessionStorage` under
  `chatq-cdraft:<p>:<id>` (text only, as alert drafts).
- **+ New chat -> folder view:** the folders as rows (`n` bold, `w` muted), with the same
  search; tapping one opens the compose view with header `New chat in proj_AS-BW`, an optional
  one-line **Name** field (placeholder `Named from the first line if left empty`), the mode
  chip from `newMode` (`default - anything that would ask is denied`), and Send. No free-typed
  path: a folder chatq does not know cannot be picked.
- **Send:** POST, then `Sent - waiting for the PC...`; the `ack` fills the status box
  (`ok` green, else red with its `say`). No `ack` in 45 s: `Sent, but no answer yet. The PC
  reads it if it listens within 30 minutes; after that it is dropped.` The same sealed message
  is kept for **Try again** (same nonce, as the alert form does), and the draft is not cleared
  until an `ack` with `ok` comes. An `ack` `that list is out of date` refreshes the list and
  keeps the draft.
- **From an alert page:** a small **Other chats** link in the footer opens the compose home
  (the alert fragment stays in `sessionStorage`; back returns to it).
- Nothing decrypted is stored; the list lives in memory and a reload asks again.

### Card and UI text, collected (the page's `cardText` gains `nolisten`, `oldpc`, `nodecomp`)
`Asking the PC for your chats...` / `No answer from the PC` / `Search chats` / `New chat` /
`Open now` / `Recent` / `No chat matches "<q>".` / `+<n> older chats are not listed.` /
`New chat in <folder>` / `Name` / `Named from the first line if left empty` /
`Sent - waiting for the PC...` / `Sent, but no answer yet. The PC reads it if it listens within
30 minutes; after that it is dropped.` / `Listens all the time` / `Listens until <HH:mm> (an
alert is out)` / `Other chats` / `Claude's answer - <HH:mm>` / `Show all` / `Copy` /
`The first <n> characters are left out.` / `Ask the PC for it` / `This browser cannot open the
whole answer.`

---

## 6. The alert-bound act `read`

`chatq1` as today, `act: "read"`, empty text. `Invoke-ChatqReply` gains a `read` case: the
alert entry must be about a chat; `Send-ChatqReplyText` again with the entry turned into a job
shape (`Find-ChatqJob $Entry.jobId`, else `ConvertTo-ChatqLiveJob $Entry`), not counted against
`downPerDay` more than once per alert (a second `read` within 3 h of a send is answered only if
the first went as an attachment). **No push** - the page is open and waiting; `Feedback` is
logged. Counts a use of the alert (20 at most), as every act does. The page's `ACTS` gains
`read` (the page check holds every act to the watcher's list).

---

## 7. The watcher's role: who is listening

A compose message is read only by a watcher that is polling. Today one polls only while an
answerable alert is out (`openUntil`). Decided: **both, by a setting** - `reply.listen`:

- `alerts` (default): unchanged. The bookmark works whenever an alert went out in the last
  `reply.hours` (the usual case while you are away and chats finish), and otherwise the page
  says, after 45 s, that nobody is listening and how to change that. No cost.
- `always`: the watcher listens while a phone is paired, alert or not.
  - `replies.json` `standing` = `$true`. **`Start-ChatqReplyStanding`** sets it (no-op unless
    `reply.on`, paired, `listen` = `always`); called by `chatnotify -Listen always`, by the shell
    start block in VS-code-chat-manager.ps1 (one line before the existing "listening for phone
    replies" check) and by the Windows overlay's host once at its start (one separable line in
    `Start-ChatOverlayHost`, then `Request-ChatqWatcher` - that file is the other session's).
  - `Test-ChatqReplyOpen`: true when `openUntil` > now **or** (`listen` = `always` and paired
    and `standing`). Cheap as now: config and the file are only looked at.
  - `Close-ChatqReplyWindow` (`chatqrun -Stop`) clears `standing` too: a stop stops the
    listening until the next shell, overlay start or answerable alert. `-Listen alerts` and
    `-Reply off` clear it; `Reset-ChatqReplyCursor -Close` clears it.
  - **Cost, said in the dialog and README:** one hidden PowerShell kept running (about 60-120 MB),
    an ntfy.sh GET every 20 s (~4,300 a day; these are requests, not messages, so they do not
    touch the 250), no CPU to speak of between polls. It never keeps the PC awake
    (`Set-ChatqKeepAwake $false` as in the listen branch): a sleeping PC answers when it wakes,
    within the 10- and 30-minute age windows.
- **Poll interval**, **`Get-ChatqReplyPollSeconds`** -> 6 while `hotUntil` > now (the 2 minutes
  after a compose act: the list is usually followed by a send), 15 while an alert window is open,
  20 standing only. The watcher's listen branch passes it to `Invoke-ChatqReplyPoll -MinSeconds`
  and to `Wait-ChatqUntil`. Inside a run (`$onTick`) it stays 30 s, 10 s while hot. The hot
  rate (10 a minute for 2 minutes) runs over ntfy.sh's one-per-10-s refill and lives off the
  60 burst; it is the only place that does.
- The board and `chatnotify` status say which: `listening for phone replies until 02:10` /
  `listening all the time`. `Get-ChatqPhoneStatusText` gains `listening all the time` and
  `whole answers on|off`.
- Out of scope, noted for FUTURE_WORK: a held-open ntfy stream (`/json` without `poll=1`) in
  place of polling, for answers in about a second.

---

## 8. Privacy

- **ntfy.sh** sees, on the down topic: when a whole answer, a list or an ack went and its size
  (compressed, to 16 bytes); a long answer's sealed file for 3 hours. It cannot tie the down
  topic to the reply topic except by timing, and neither name is in any push. Titles, folders,
  prompts and answers are never readable there.
- **Join** sees `r=1` and `w=<time>` more in each link. Nothing else changes.
- **The phone** holds decrypted titles, folders and answers in the page's memory only; drafts in
  `sessionStorage` as now. A script on another page of the shared `github.io` origin could use
  the key to sign a `list` and read the answer - the same exposure as posting replies today,
  now also reading: README's "The page's site is shared" paragraph says so, and
  `chatnotify -ReplyPage` is still the fix. **Compose off** (`-Compose off`) removes the list
  from that exposure.
- The list sends each folder as its leaf name plus its parent path, never more than chatq
  already shows in the console.
- `replies.log` logs acts and handles, never text, titles or folders.

---

## 9. Functions, by file

src/phone.ps1 (new): `Get-ChatqDownTopic -Master`; `Get-ChatqReplyKeys` gains `-Label`
(default `'chatq-alert:'`); `Compress-ChatqBytes` / `Expand-ChatqBytes -MaxBytes` (raw
deflate); `Protect-ChatqDownMessage -Key|-Master -Did -Payload [-Iv] [-Deflated]` and
`Unprotect-ChatqDownMessage` (tests, and the vector); `Protect-ChatqComposeMessage` (tests) and
`Unprotect-ChatqComposeMessage`; `Send-ChatqDown`; `Get-ChatqTurnText`; `Get-ChatqJobTurnText`;
`Send-ChatqReplyText`; `Get-ChatqPhoneChatMeta`; `Get-ChatqPhoneList`; `Receive-ChatqCompose`;
`Invoke-ChatqCompose`; `New-ChatqPhoneJob` (factored out of `Invoke-ChatqReply`);
`Start-ChatqReplyStanding`; `Get-ChatqReplyPollSeconds`; `Add-ChatqDownCount` (the day's
counters, in a lock block). Changed: `Get-ChatqReplyConfig` (Full, FullMax, Compose, NewMode,
Listen, DownPerDay, DownTopic), `Set-ChatqNotifyConfig`, `Test-ChatqReplyMessage`,
`Receive-ChatqReply`, `Invoke-ChatqReply` (`read`), `Get-ChatqReplyLink`, `Get-ChatqReplyState`,
`Save-ChatqReplyState`, `Test-ChatqReplyOpen`, `Close-ChatqReplyWindow`,
`Reset-ChatqReplyCursor`, `Get-ChatqPhoneStatusText`.
src/alerts.ps1: `Send-ChatqAlert` (section 4). src/watcher.ps1: the poll interval
(section 7). src/queue.ps1: declare `$script:ChatqDownSeam` beside the other seams.
src/commands.ps1: `chatnotify` switches and status lines. src/phone-setup.ps1: in **Replies**,
three checkboxes - **Show Claude's whole answer on the phone**, **Let the phone queue to any
chat, or start one**, **Listen all the time** with the hint `So the phone can reach the PC
without an alert. A hidden PowerShell stays running and asks ntfy.sh every 20 s.`
VS-code-chat-manager.ps1: the one shell-start line. src/overlay-windows.ps1: the one host line
(separable hunk, other session). docs/reply.html: sections 2, 4, 5, 6.

---

## 10. Tests

**Fixtures** (Node's `crypto` and `zlib` as the reference, in `tests/fixtures/make-reply-vector.js`):
- `down-vector.json`: `D` = bytes 0x00..0x1f, `did` = `"abcdefghij"`, iv = 0x10..0x1f, the payload
  JSON with Hangul (`"s":"yes, commit it 한글"` as raw UTF-8), `deflated` (b64url, from
  `zlib.deflateRawSync`), the expected `message`, `downTopic`.
- `compose-vector.json`: the same D, `cid` = `"klmnopqrst"`, iv, the exact `send` payload, `message`.

**PowerShell** (tests/sections/phone.ps1, appended; 5.1 and 7):
- `Get-ChatqDownTopic` = the vector's; `Protect-ChatqDownMessage -Deflated <vector bytes> -Iv`
  reproduces the message byte for byte; `Unprotect-ChatqDownMessage` opens it; our own deflate
  round-trips (Hangul, empty, 1 MB) and `Expand-ChatqBytes -MaxBytes` stops a bomb.
- `Unprotect-ChatqComposeMessage` opens the compose vector; a changed byte anywhere is `mac`; a
  `chatq3c` sealed under an alert key, and a `chatq1` under a phone key, both fail.
- `Get-ChatqTurnText` on synthetic transcripts: stops at the last real prompt, not at a
  `tool_result` user record, skips sidechain records, keeps order, tool lines, `<synthetic>`
  as a note, cut from the front at `-Max` with `Cut` set and no half surrogate.
- `Get-ChatqJobTurnText` from a synthetic job log with two runs: only the last; Claude and
  Codex lines.
- `Send-ChatqDown` via the seam: <= 3,900 sealed -> POST with `X-Title`, `X-Firebase: no`;
  over -> PUT with `X-Filename`; the seam refusing the PUT -> inline, cut, `cut` > 0.
- `Send-ChatqAlert 'done'` with replies on (Join seam + down seam): the down message goes
  before the Join URL, the link has `r=1&w=`; the down seam failing -> no `r=1`, the push
  still goes; `-FullText off` -> no down message; `started` -> none; `downPerDay` reached ->
  none, and the counter resets on a new day.
- Compose through `Invoke-ChatqReplyPoll -Force` with `$script:ChatqReplyPollSeam`: `list` ->
  a down `list` with handles and `picks` saved; `send` with that handle -> a job for that
  session, `Rule phone`, mode capped, `]\(` in its prompt, `JobHome` from the pick, ack `ok`,
  a `reply` push; wrong `id` -> refused ack; expired handle -> refused; `new` -> `Kind new` in
  the folder; a folder deleted since -> refused; replay -> nothing, silent; age 31 min ->
  refused; 21st send in an hour -> refused; refusal acks at most one a minute; `-Compose off`
  -> refused; a failed state save -> `'unsaved'`, nothing queued, done on the next poll.
- `read` on a live alert: a down `reply`, no push, a use counted.
- `Test-ChatqReplyOpen`: `listen always` + paired + `standing` -> true with no window;
  `Close-ChatqReplyWindow` clears it; not paired -> false. `Get-ChatqReplyPollSeconds` 6/15/20.
- `Save-ChatqReplyState` prunes `picks` and `compose`; an unreadable file still throws.
- `Set-ChatqNotifyConfig`: each new key, bad values save nothing.

**Page** (tests/reply-page-check.js): both vectors (open the down one, seal the compose one byte
for byte, `downTopic`); `openDown` refuses a wrong prefix, a wrong `did`, `ref` != `did`, a bad
MAC, a bad deflate, output over 4 MB; the attachment URL check (other origin, other path, over
2 MB); `parseFragment` `r`/`w`; `ACTS` includes `read` and the compose acts are
`list, status, send, new`; `filterChats` (Hangul, NFC vs NFD, word order); the renderer builds
code fences, inline code, tool folding; the file has no `innerHTML`/`outerHTML`/
`insertAdjacentHTML`/`document.write`; the CSP meta is unchanged.

**Live, by hand** (TESTING.md, a new S entry): with the real ntfy.sh - a `done` alert on the
phone shows the whole answer; an answer over 4 KB goes as an attachment and shows; after 3 h
**Ask the PC for it** brings it back; the bare page URL from a home-screen shortcut lists chats
within 30 s with `-Listen always`; a send queues and both the ack and the push arrive; a new
chat starts in a listed folder; with `-Listen alerts` and no alert out, the page gives the
no-answer card at 45 s; Hangul title and answer render; the page on an iPhone (Safari 16.4+) and
Android Chrome.

---

## 11. Out of scope

- Approving a permission prompt mid-run (FUTURE_WORK "Approve permission prompts from the phone").
- More than the last turn: no transcript history, no scrolling back through a chat.
- Files, images or voice from the phone; choosing a mode or model from the phone (the PC
  decides; nothing in a message picks a mode).
- Deleting, renaming, archiving chats, or editing and removing queued jobs from the phone.
- A PWA manifest, service worker, offline cache or web push; the page is not subscribed to
  anything when closed.
- A streaming ntfy connection in the watcher (FUTURE_WORK, section 7).
- Standing listening off Windows beyond the shell-start line (no overlay there to start it).
- Codex chats' live state (the live registry is Claude's); Codex chats are listed and queued to.
- Several phones; an authenticated reply server (the page sends no `Authorization`).
- Folders the phone types in, or any path from the phone.

## 12. Docs, when implemented

README: under "Reply from the phone", two subsections, **The whole answer** and **Any chat,
from the phone** (bookmark, list, new chat, `-Listen always` and its cost, the 10- and 30-minute
windows); the `chatnotify` switch table and the config table gain the new keys; "What passes
through whose servers" gains the down topic. CHANGELOG 0.9.0 with the user-facing behaviour and
the ntfy.sh limits it lives within. TESTING.md the new S entry. FUTURE_WORK: the streaming
listener, a manifest for the home-screen shortcut, and the list from the macOS/Linux side.
Code comments cite the ntfy limits where the thresholds are set (`Send-ChatqDown`,
`Get-ChatqReplyPollSeconds`).

---

# Addendum to spec-down.md: the phone dashboard (the overlay, on the phone)

The user asked: "if I can open a browser and use it, why not display the whole overlay on it?
- on the phone". So the compose home of spec-down.md section 5 becomes a phone-sized overlay:
everything the Windows overlay shows, plus the actions its chips and the console offer. Every
rule of spec-down.md still holds (sealed PC->phone `chatq3d.`, MAC-verified phone->PC
`chatq3c.`, handles instead of ids or paths, reply.maxMode cap, rate limits, durable before act,
nothing readable through ntfy.sh or Join). Where this addendum and spec-down.md differ, this wins.

## What the page shows (home = the board)
Opened from the bookmark / home-screen shortcut (bare URL, paired phone), or "Other chats" /
"Board" from an alert page. Sections in the overlay's own order and colours (amber waiting,
green working, orange cut off, purple queued, grey idle, faint recent), mobile-first:

```
+-----------------------------------------+
| chatq on DESKTOP-M15B07E   23:42  Refresh|
| Claude  5h [#####-----] 37%  resets 02:10|
|         week [##--------] 18%            |
| Codex   week [----------] 3%   (Fri 16:38)|
| WAITING ON YOU                           |
|  * Radar viewer  - permission (Bash)     |
|    as_viewer - VS Code - 3m              |
| WORKING                                  |
|  * Parser rewrite  "fix the tokenizer.." |
|    parser - VS Code - 12m    #14 queued  |
| CUT OFF                                  |
|  * Plugin unification  auto-continues 02:11|
| QUEUE                                    |
|  #14 Parser rewrite     sends after run  |
|  #15 Docs pass          sends 02:11      |
| OPEN, IDLE                               |
|  * Notify feature   new turn  2m         |
| RECENT                                   |
|  Chat open investigation         3h      |
| + New chat          Listens all the time |
+-----------------------------------------+
```
- Usage: one line per provider as the overlay's collapsed/lines view has it (percent, window,
  reset time when limited, "as of" time when older than 1 h - stale), with a thin bar each.
- Open chats: from the overlay's own rows - state (waiting / working / idle), the blue "new turn"
  dot, where it runs (VS Code / terminal), the newest prompt's first line, age, jobs riding on it.
- Cut off: "cut off - resets 13:00" / "529 - waits for Claude" / "auto-continues 13:01" (once
  auto-continue lands; show whatever the PC sends).
- Queue: #n, chat, state and "sends" time as chatqlist computes it (Get-ChatqEta).
- Recent: the overlay's Recent list.
- Tap any chat row -> the chat view (spec-down's compose view, extended): title, folder, where
  it runs, state line, mode chip, the newest prompt (first 300 chars), the last answer via the
  whole-answer channel when available ("Read the last answer" -> act `read` by handle), the
  textarea + Send (act `send`), and per-state actions:
  - a queued job of it: **Send now** (act `now`, = chatqrun <n> -Now semantics for that lane),
    **Skip** (act `skip`, second tap); running: **Stop** (act `stop`, second tap);
  - needs-input job: **Continue**, **Allow edits & continue** (Claude), same caps as alerts;
  - cut off with an auto-continue queued: **Don't continue** (= skip that job);
  - cut off with nothing queued: **Continue at reset** (queues a `-Continue` job).
  Every one is a compose act bound to a board handle (never a session id or path from the
  phone), with the reply.maxMode cap, the rate limits of spec-down (count them with send/new),
  and an `ack` + the usual `reply` push for anything that changed the queue.

## The PC side
- New compose act `board` (replaces `list` as what the home asks for; keep `list` working for
  the folder picker). Answer: a sealed down message kind `board`:
  `{"v":3,"kind":"board","ref":cid,"ts":..,"host":..,"cap":..,"listen":..,"until":..,
    "usage":[{"p":"Claude","parts":[{"w":"5h","pct":37,"reset":"<iso|null>","limited":false}],"asof":"<iso>","stale":false}],
    "open":[{"h":..,"id8":..,"t":..,"f":..,"where":"vscode|terminal","state":"waiting|busy|idle",
             "what":"permission (Bash)","prompt":"first 120 chars","new":true,"age":"<iso>","jobs":[14]}],
    "cut":[{"h":..,"t":..,"f":..,"why":"limit|overloaded","reset":"<iso>","auto":"<iso|null>","job":15}],
    "queue":[{"h":..,"seq":14,"t":..,"state":"queued|running|needs-input|failed","sends":"after #13|02:11|next"}],
    "recent":[{"h":..,"t":..,"f":..,"age":"<iso>"}],"more":14}`
  Titles 60 chars, prompts 120, compressed then sealed as spec-down's down messages (attachment
  if > 4 KB after deflate - unlikely).
- Source of truth: build it from what the overlay already computes when the overlay runs -
  data/overlay.json is rewritten by the overlay each pass (read it; check its shape in
  src/overlay-data.ps1 / overlay-windows.ps1: the macOS panel reads it too) - projected to the
  board shape; handles minted into replies.json `picks` in the same locked block. When no
  overlay runs or overlay.json is older than 2 minutes: fall back to Get-ChatqLiveSessions +
  Get-ChatqJobs + Get-ChatqEta + Get-ChatqUsage + Get-ChatqCutOffChats (bounded reads, as
  spec-down's list does), and set `"from":"scan"` so the page can say "the overlay is not
  running - some rows may be missing".
- Refresh budget: the page asks on open, on the Refresh button, and every 30 s while the page is
  visible for at most 10 minutes (then "Paused - tap Refresh"); never in the background. The PC
  answers at most one `board` per 10 s (a second within 10 s gets the same board again from a
  memory cache, no new build - 40 s for a board built from a scan, with no overlay running,
  which reads every live chat and the cut-off transcripts: kept past the page's own 30 s, and
  its cut-off look kept by transcript between builds) and counts board answers against
  spec-down's `downPerDay`; when
  the day's budget is near, the page says "few refreshes left today (ntfy.sh's free limit)".
- Listening: the dashboard is only useful when the watcher listens. The setup window's replies
  section gains **Listen all the time (the phone board and new chats)** = reply.listen always,
  with its cost line from spec-down section 7; chatnotify -Listen always|alerts. The board
  footer says which. When the PC does not answer within 45 s: spec-down's `nolisten` card.

## Tests (in addition to spec-down's)
- PS: the board projection from a fixture overlay.json and from the scan fallback; handles minted
  and honoured; each board act (send, now, skip, stop, retry, allow, noauto/continue-at-reset)
  through Receive-ChatqCompose with the cap and rate limits; a board answer cached within 10 s;
  downPerDay counted.
- Page: render a board fixture (all sections, empty sections hidden, Hangul titles, stale usage);
  tap -> chat view -> each action seals the right act with the row's handle; auto-refresh stops
  after 10 minutes and when hidden (visibilitychange); the nolisten card; no raw D anywhere.
