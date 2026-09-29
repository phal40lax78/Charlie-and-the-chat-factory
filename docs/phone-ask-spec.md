# Spec: see and answer Claude's questions from the phone

Status: built, 2026-09-29 (src/ask.ps1, src/ask-hook.ps1,
tests/sections/ask.ps1). It comes in two parts:
- **Part A** (section 4) shows the question on the phone. It rests only on
  data chatq already reads.
- **Part B** (sections 5-6) answers it from the phone. It rests on CLI
  behaviour that is undocumented. It was built once the S46 part 2 items a
  script can run had passed (section 11). It stays off by default
  (`ask.on`). The items only a person can check (1, 2 and 4: the VS Code
  dialog closing, a hook picked up by open chats, the terminal) are S47's,
  before `chatnotify -Ask on` is recommended.

The investigation behind both is recorded in section 11 as S46 part 1. It
covered the docs, the extension's code, and five tests against the real
CLI. Both parts build on two shipped specs and change neither of their
rules: [phone-board-spec.md](phone-board-spec.md) (the board, and the sealed
PC -> phone channel) and [phone-permit-spec.md](phone-permit-spec.md)
(request and answer files, and an answer believed only on the phone's MAC).
Those rules stand: no key in any push, every phone -> PC message
MAC-verified, spent nonces durable before acting, `reply.maxMode`, pairing
by code, and rate limits.

"A question" here is Claude's `AskUserQuestion` tool. In VS Code it is the
dialog with a header chip, one to four questions, two to four options each
(a label and a description), an **Other** box, **Submit answers** and **Esc
to cancel**. Today the board and the overlay only say `input needed`.

## 0. The answer in short

- **Seeing it: yes, from data chatq already reads.** While the dialog is
  open, the chat's transcript holds the whole pending call: every question,
  header and option, with each option's description. Part A puts that on
  the board and on the `needs input` alert's page. It needs no hook, no new
  setting, and no new act.
- **Answering it: yes, for a question asked while a hook of chatq's is
  loaded - on CLI 2.1.283, as tested.** A Claude Code `PermissionRequest`
  hook with matcher `AskUserQuestion` runs beside the dialog, not in front
  of it. If it answers first with `allow` plus `updatedInput: {questions,
  answers}`, the CLI takes that answer and withdraws the dialog. If the PC
  answers first, the hook's answer is dropped. A hook that times out is
  killed, and the dialog stays. Part B is that hook, fed by the phone. It is
  off by default.
- **What cannot be answered:**
  - A question already open before the hook was loaded, like the one that
    started this. It is shown, not answered.
  - Questions in chatq's own queued runs: the CLI refuses their MCP
    `--permission-prompt-tool` for this tool (section 9).
- **The risk.** The docs say `AskUserQuestion` needs no permission, and
  several GitHub issues say no hook fires for it. The spike on 2.1.283 shows
  otherwise, but nothing documents it. So:
  - Part B waits for S46 part 2.
  - Every failure of the hook must leave the dialog exactly as it was.
  - The watcher checks that each answer landed, and says so when it did not
    (section 5.3).

## 1. What is true today (read from the code, the extension and the CLI)

- **The registry.** `~/.claude/sessions/<pid>.json` for a chat on a question
  says `"status":"waiting","waitingFor":"input needed"`, with
  `"entrypoint":"claude-vscode"` and `"version":"2.1.283"`. The tool is not
  named.
  - [Get-ChatOverlayRows](../src/overlay-data.ps1) makes that string a
    waiting row's `detail`.
  - [ConvertTo-ChatqPhoneBoard](../src/phone-board.ps1) passes it on as the
    `open` row's `what`. The page shows it as one line
    ([rowView](reply.html)).
  - [Read-ChatqSessionRegistry](../src/live-chats.ps1) reads `entrypoint`,
    but not `version`.
- **The transcript.** The last assistant record holds the pending call:
  ```json
  {"type":"tool_use","id":"toolu_...","name":"AskUserQuestion","input":{"questions":[
    {"question":"stability.log is the only always-on record (...). Which way?","header":"Stability log",
     "multiSelect":false,"options":[{"label":"Integrate (recommended)","description":"The always-on sink ..."},
     {"label":"Just delete it","description":"..."},{"label":"Leave it alone","description":"..."}]}]}}
  ```
  - It has no `tool_result` while the dialog is open.
  - Once answered, the next `user` record's `toolUseResult` has
    `"answers":{"<question text>":"<label, or the text typed in Other>"}`.
  - Records carry `permissionMode`.
  - Real descriptions run past 300 characters: 4 of about 52 calls in this
    user's transcripts.
- **What chatq reads of it: only the tool's name.**
  [Get-ChatqLiveWaitWhat](../src/phone.ps1) regexes the tail for the last
  `tool_use` name and says `a question`, for the live alert's push text. It
  cannot tell a side chain's record from the chat's own.
- **Queued runs.** Without permits, `--permission-prompts none` removes
  `AskUserQuestion`. With permits, the run's own settings deny it, and so
  does [Get-ChatqPermitRule](../src/permit.ps1): "make the most reasonable
  choice ... and go on".
- **The VS Code extension** (2.1.283, `extension.js` and `webview/index.js`):
  - It spawns `claude.exe --output-format stream-json --verbose
    --input-format stream-json ... --permission-prompt-tool stdio`.
  - The dialog is a `can_use_tool` control request for `AskUserQuestion`
    with `"requires_user_interaction":true`.
  - On Submit, the webview answers `{behavior:"allow", updatedInput:
    {questions, answers}}`. Each value is the chosen labels joined with
    `", "`; with **Other**, the typed text replaces the word `Other` in that
    list.
  - A `control_cancel_request` from the CLI aborts the pending request. The
    extension then sends the webview a `cancel_request`, which should close
    the dialog. That is read from the code, not seen on screen (S46 item 1).
  - On a reload, the webview shows an unanswered question again from the
    transcript (`maybeReplayUnansweredQuestion`).
- **The CLI** (2.1.283, read from the bundle):
  - `AskUserQuestion.requiresUserInteraction()` returns true.
  - A hook's allow with `updatedInput` "satisfies user interaction" when the
    tool's `admitCardAnswer` accepts it. The code reads as if it must not
    change a field the card showed, but 2.1.283 took an edited label
    (S46 item 7). chatq splices the questions back byte for byte all the
    same: that is its own rule, not one the CLI checks.
  - An allow from an MCP `--permission-prompt-tool` for a tool that
    requires interaction is turned into a deny ("not supported via
    --permission-prompt-tool").
- **Away.** [Test-ChatqUserAway](../src/alerts.ps1) is true after no input
  for `quietMinutes` (5). [Get-ChatqIdleSeconds](../src/alerts.ps1) measures
  that with `GetLastInputInfo`.

## 2. Words used

- **The chat's transcript.** The path chatq resolves from the session id:
  [Get-ChatqRowById](../src/commands.ps1) `-Id <sid> -Provider claude -Cwd
  <cwd>`, or a live alert's `path`. It is **never** a path read from a
  request file (section 5.3 says why).
- **The pending call.** `Get-ChatqPendingAsk` on the chat's transcript
  (4.1).
- **Equal** (two sets of questions). The same number of questions, and of
  options in each, compared position by position. Each question's text,
  header and multiSelect must match, and each option's label and
  description. Order counts: the phone answers by index.
- **Request** (Part B). `data/ask/<rid>.req.json`, written by the hook.
- **Open** (Part B). The request's `state` is `open`, and it is before its
  `until`. Its `hookPid` must also be alive as that hook: a `powershell.exe`
  whose start time is within the two minutes before the request's `at`, and
  whose command line names `ask-hook.ps1`. That process test is
  `Test-ChatqAskHookAlive`. It checks start time and command line together,
  because Windows reuses pids within minutes
  ([Test-ChatqSessionAlive](../src/live-chats.ps1) says so).
- **The digest `qh`** (Part B).
  `b64url(SHA-256(UTF8("chatq-ask`n" + rid + "`n" + session_id + "`n" + questionsRaw))[0..15])`.
  - `questionsRaw` is the raw JSON text of `tool_input.questions` from the
    hook's stdin. It is cut out by [Get-ChatqJsonRaw](../src/permit.ps1) and
    never re-serialized.
  - The digest binds an answer to one chat, one call, and the exact
    questions shown.

## 3. Shape (Part B; Part A is the right-hand half without the hook)

```
VS Code chat (claude.exe)
   |  the question: can_use_tool -> the dialog shows at once
   |  and, beside it, the PermissionRequest hook (matcher AskUserQuestion)
   v
hook: powershell.exe -File src/ask-hook.ps1 -> Start-ChatqAskHook
   |  writes data/ask/<rid>.req.json, then waits (1 s steps) for:
   |    <rid>.ans.json (the phone's sealed answer, as posted)
   |    the transcript showing the call answered at the PC
   |    its deadline, or claude gone
   v
   prints {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
            "decision":{"behavior":"allow","updatedInput":{questions, answers}}}}
   -> the CLI takes it and withdraws the dialog

overlay pass: needs input, away, 20 s -> outbox -> Send-ChatqAlert -> push, plus a
                                          sealed `reply` down message carrying `ask`
board request (compose `board`)       -> the `open` row carries `ask`
phone: Send answer -> sealed `answer` act -> watcher (the one poller)
   -> Invoke-ChatqReply / Invoke-ChatqCompose -> Invoke-ChatqAskReply
   -> writes <rid>.ans.json; later checks the answer landed
```

The hook follows the bridge's rules:
- **One poller.** The watcher alone polls the reply topic, keeps the nonce
  ledger, and sends pushes. The hook does no network I/O.
- **The files are not trusted.** A chat can write into `data/`, so the hook
  never reads its own request back. It opens the phone's sealed message
  itself and believes only that (5.4). The watcher never takes a transcript
  path, or anything else it acts on, from a request without checking it
  against the chat itself (5.3).
- **Every failure is silence.** The hook prints nothing and exits 0, so the
  dialog carries on as if no hook existed. It never denies, never adds a
  permission, and never interrupts.

## 4. Part A - see the question (release 1, no hook)

### 4.1 Reading it: `Get-ChatqPendingAsk -Path` (src/ask.ps1)

It returns `@{ ToolUseId; At; Mode; Questions; More; Cut }`, or `$null`.
- **Reading.**
  - It reads the tail with [Read-ChatqTail](../src/queue.ps1): 1 MB first,
    then 4 MB if no assistant record turns up.
  - The first line of a partial tail is dropped, as
    [Get-ChatqTurnText](../src/phone-down.ps1) does.
- **Finding the call.**
  - It walks back to the newest record that is not `isSidechain` and holds a
    `tool_use` named `AskUserQuestion`.
  - It parses that line with `ConvertFrom-Json`. That is fine here, since
    this copy is only shown, and nothing is sent back to Claude from it.
- **Pending.**
  - The call counts only while no later line is a `user` record with a
    `tool_result` for its id, and no later line is a real prompt
    ([Test-ChatqRealPrompt](../src/phone-down.ps1)).
  - `Mode` is the newest non-sidechain record's `permissionMode`.
- **Display caps.** They apply to this copy only. What Claude gets is never
  cut: Part B splices the raw input.
  - 4 questions and 4 options each, the tool's own limits. `More` counts
    anything past that.
  - Question 2000 characters, header 60, label 300, description 2000. A cut
    never splits a surrogate pair.
  - Once all its questions pass 16 KB, the longest descriptions are cut
    first, down to 300. Each cut sets `Cut`, and the page says `(cut - the
    whole text is at the PC)`.
  - An option's `preview` is never carried; the page says `a preview is
    shown at the PC`.
- **Shape.** A question is `@{ t; h; m; o = @(@{ l; d; x }) }`: the text,
  the header, multiSelect, and each option's label, description, and a cut
  mark.
- **Cache.** `$script:ChatqAskCache` is keyed by path, length and write
  time, so a board built every 10 s does not parse again.
- **Waiting chats only.** It runs only for a chat the registry calls
  `waiting`. Part B adds chats with an open request (5.1, S46 item 9).

### 4.2 The view: `Get-ChatqAskView -SessionId -Path` (src/ask.ps1)

The board and the alert page carry the same view. It returns `$null` when
nothing is pending.

**Part A shape:**
```json
{ "k": "<the tool_use id's last 12>", "at": "<iso>", "more": 0, "cut": false,
  "q": [ { "h": "Stability log", "t": "stability.log is ... Which way?", "m": false,
           "o": [ { "l": "Integrate (recommended)", "d": "The always-on sink ..." }, ... ] } ] }
```

Part B adds either:
- `"can": true, "rid", "qh", "until"`, or
- `"can": false, "why"` (the table in 5.1).

The page treats a view with no `can` as Part A: read-only, `Answer it at the
PC.`

### 4.3 The board

- [Get-ChatqPhoneBoard](../src/phone-board.ps1) builds `-Asks` (session id
  -> view) for the waiting session rows, and hands it to
  [ConvertTo-ChatqPhoneBoard](../src/phone-board.ps1).
  - `-Asks` is a new, optional parameter. The function stays pure, and its
    present tests and callers are untouched.
  - The transcript is the chat's (section 2). Session rows carry no path,
    and board picks for `open` rows pass none.
- **The `open` row** gains `ask`. Its `what` becomes `a question: Stability
  log`, or `2 questions: Reach, Repoint`, in place of `input needed`. That
  text is sealed on the down topic, as every board field is.
- **Size.** One question with three ordinary options is about 1 KB raw, and
  under 600 bytes deflated. A board over the inline cap goes as an
  attachment, as [Send-ChatqDown](../src/phone-down.ps1) already does.

### 4.4 The `needs input` alert's page

[Send-ChatqReplyText](../src/phone-down.ps1) returns early today: first when
`reply.full` is off, then when the turn has no parts, and it always counts
`full`. It is reordered:
1. When the event is `needs input` and the job shape has `sessionId` and
   `path`, it computes `$ask = Get-ChatqAskView` first.
   - A live alert from [Update-ChatqLiveAlerts](../src/phone.ps1) comes
     through the outbox, and its job shape carries the transcript as
     `path`.
   - A queued job's alert never gets one: its runs cannot ask.
2. **Full off, no `$ask`:** today's return, unchanged.
3. **Full off, `$ask` set:** the body goes with `parts = @()`, `cut = 0`
   and `ask`. It is counted `other` in
   [Add-ChatqDownCount](../src/phone-down.ps1) and recorded in `downSent`.
4. **Full on:** today's path, plus `ask`.
5. **`-Again`** (act `read`, from
   [Invoke-ChatqReadAct](../src/phone-board.ps1) and the alert page)
   follows the same rules, so a page that asks again gets the question
   back.

The link's `f=1` ([Update-ChatqReplyFull](../src/phone-down.ps1)) follows the
return value as now. The page waits for the body.

**The push text is unchanged**: `<chat> · waiting on you: input needed (a
question) · <folder>`. The question and its options travel only sealed.
Join logs its GETs, and others may read an ntfy alert topic
([phone-permit-spec.md](phone-permit-spec.md) section 6 keeps commands out
of pushes for the same reason).

### 4.5 The page (docs/reply.html)

- **`askView(ask, nowMs)`** is a pure function. It returns the lines, the
  controls and the footer, and is tested in `reply-page-check.js`.
  `renderAsk` builds the view with `createElement` and `textContent` only;
  the page check that forbids `innerHTML` stays.
- **Where it shows.** The card goes above the whole answer and the Send box
  in both places, because the question is what the chat waits on:
  - In the board's chat view, for an `open` row with `ask`.
  - On the alert page, for a `reply` body with `ask`. `settlePanel` shows
    only the card when `parts` is empty.
- **Part A** is one read-only card per question: `1 of 2`, the header chip,
  the question, then the options, each a label with its description below
  it.
  - A multiple choice says `choose any`.
  - The footer reads `Answer it at the PC.`
  - The Send box below keeps its present words: `Prompt for after it is
    answered`.
- **Part B, answerable (`can: true`):**

```
+-----------------------------------------+
| CLAUDE ASKS                    1 of 1   |
| [Stability log]                         |
| stability.log is the only always-on     |
| record (...). Which way?                |
| (o) Integrate (recommended)             |
|     The always-on sink starts ...       |
| ( ) Just delete it                      |
|     Remove the sink, the menu item ...  |
| ( ) Leave it alone                      |
|     Keep both files as they are ...     |
| ( ) Other [ your own answer          ]  |
| [ Send answer ]                         |
| The PC's dialog stays open too - the    |
| first answer wins. Until 14:02.         |
+-----------------------------------------+
```

  - A single choice is a radio group, and a multiple choice is checkboxes.
    **Other** is always offered, as in VS Code, and typing in it selects it.
  - **Send answer** turns on only when every question has an answer. It
    takes a second tap (`Tap again to send`), as Skip and Stop do.
  - The byte counter covers the whole payload (`MAX_PAYLOAD` 2900), as the
    prompt box's does.
  - A draft is kept per request in `sessionStorage` under
    `chatq-adraft:<rid>`: the choices and the Other text only.
  - **After Send:** `Sent - the PC reads it within about 20 s.` Then comes
    the ack or push, and later the landed check's word if it did not land
    (5.3).
  - Past `until`, the card turns read-only with `late`, on a one-minute
    tick.
- **Part B, not answerable (`can: false`):** the Part A card, with the
  `why` line from 5.1 in place of the footer.
- **Nothing decrypted is stored.** The question lives in memory, as the
  board does.

## 5. Part B - answer it from the phone (release 2)

**Built after S46 part 2 items 3, 5, 6, 7, 9 and 10 passed** (2026-09-29,
section 11). Items 1, 2 and 4 need a person at VS Code, and are S47's.

### 5.1 When the phone may answer, and what the page says when not

The hook works through these gates in order. The first one that fails
decides. A **silent** failure writes nothing and exits 0. A **declined**
failure also writes a request with `state: 'declined'` and a `why`, so the
page can say it.

| gate | fails as | `why` | the page says |
|---|---|---|---|
| stdin reads, the event is `PermissionRequest`, the tool is `AskUserQuestion`, and `questions` is found | silent (logged) | `hook` | - |
| `ask.on`; replies on and a phone paired ([Get-ChatqReplyConfig](../src/phone.ps1) `.Links`); a link channel ([Test-ChatqLinkChannel](../src/phone.ps1)) | silent | `off` | `Answer it at the PC. To answer from the phone: chatnotify -Ask on (a phone paired, and Join or ntfy over https to carry the link).` |
| a registry entry for `session_id`, read from `$env:CLAUDE_CONFIG_DIR`'s `sessions/`, else `~/.claude/sessions/` (the hook inherits the CLI's environment), alive by [Test-ChatqSessionAlive](../src/live-chats.ps1) | silent (logged): a session chatq cannot find there. A `-p` run registers too, and takes its entrypoint from the environment it inherits (S46 item 9), so the entrypoint gate below is what keeps other hosts out, not this one | `hook` | - |
| its `entrypoint` is `claude-vscode` | declined | `term` | `Answer it in the terminal.` This gate is dropped only once S46 item 4 passes |
| its `version` is `$script:ChatqAskMin` (`2.1.283`) or newer | declined | `cli` | `Answer it at the PC - Claude Code 2.1.2xx is too old for answers from the phone.` |
| `permission_mode` from stdin is at or below `reply.maxMode` on `$script:ChatqModeLadder`, as [Limit-ChatqPhoneMode](../src/phone.ps1) judges | declined | `mode` | `Answer it at the PC - that chat runs in bypassPermissions, above the phone's limit (acceptEdits).` |
| fewer than `ask.maxOpen` (5) open requests, and fewer than 30 made in the last hour (counted from every request's `at`, whatever its state, since they are kept 1 h after `until`) | declined | `busy` | `Answer it at the PC - too many questions wait on the phone right now.` |

The view uses two more `why` values of its own:
- `hook`: the view was on, and no request matched the pending call. The page
  says `Answer it at the PC - no chatq hook holds this question (it was
  asked before the hook was loaded in that chat, or the hook did not start;
  see data/logs/ask.log).`
- `late`: the matching request is `timeout`, `gone` or `off`, or it is open
  but past `until` or its hook is dead. The page says `Answer it at the PC -
  the phone could answer until 14:02.`

**Why the mode gate.** An answer is your word to a chat, and the chat then
acts on it in its own mode.
- chatq has never let the phone drive a turn above `reply.maxMode`. A phone
  prompt to a live chat queues a job capped there
  ([Invoke-ChatqReply](../src/phone.ps1), act `prompt`).
- A question in a `bypassPermissions` chat would be the one way round that.
  Raise `reply.maxMode` to allow it.
- The mode is the one stdin gives as the question comes. There is nothing
  to check it against later: the transcript writes the mode on typed
  prompts only, so while a question waits it holds the last prompt's mode,
  not the chat's. A switch at the PC while a question is held (say to
  `bypassPermissions`) is not seen. That is FUTURE_WORK, until the registry
  or a hook carries the live mode.

**There is no size gate.** The hook splices `questionsRaw` as it came, so
no length stops an answer. Only the display is capped (4.1).

**Which chats Part B looks at.** The board and the alert show a question for
a session the registry calls `waiting`, or one with an open request. While
a hook holds a question the registry says `waiting`, `input needed`,
unchanged (S46 item 9), so the open request is only a belt.

**Matching a request to the pending call** (`Get-ChatqAskView`, and 5.3):
- The request's `session` is the chat's.
- The request's questions (`questionsRaw`, parsed) equal the pending call's.
- The request's `toolUseId`, when set, is the pending call's id. When it is
  not set, the request's `at` must be at or after the call's timestamp.
- Of several matches, the newest `at` wins, whatever its state:
  - `open` with its hook alive gives `can: true`.
  - `declined` gives its own `why`.
  - The rest give `late`.
- No match gives `hook` when `ask.on`, and `off` when not.

### 5.2 The hook: `Start-ChatqAskHook` (src/ask.ps1)

**The launcher.** `src/ask-hook.ps1` is not a `$chatParts` part:
```powershell
$ProgressPreference = 'SilentlyContinue'; $env:CHATQ_OVERLAY = '1'
try {
    . (Join-Path $PSScriptRoot '..\VS-code-chat-manager.ps1') *> $null
    Remove-Item env:PSExecutionPolicyPreference, env:CHATQ_OVERLAY -EA 0
    $null = Start-ChatqAskHook
}
catch { try { <append the error to data/logs/ask.log beside the script> } catch {} }
exit 0
```
- **`*> $null`, not `| Out-Null`.** It drops every stream, as the bridge's
  load does ([Get-ChatqPermitLaunch](../src/permit.ps1)). `Write-Host` and
  warnings would otherwise reach stdout when claude redirects it, ahead of
  the decision.
- **Always `exit 0`.** A non-zero exit is at best an error line in the chat,
  and exit 2 means *block* for most hook events. The decision goes out only
  through `Start-ChatqAskHook`'s own raw stdout write, and its whole body is
  wrapped so that a throw leaves stdout empty.
- **The command** in the hook is `"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
  "<chatq>/src/ask-hook.ps1"`, in that form because Claude Code runs a hook
  command through Git bash (S46 item 10). Forward slashes are needed: bash
  would eat backslashes.
  - The hook's parent is that bash, not claude. That is why the hook finds
    claude through the registry, never its parent.
  - A kill at the timeout takes the whole tree, `powershell.exe` included.
  - stdout held the decision line and nothing else.
- Errors go to `data/logs/ask.log`, rolled at 1 MB.

**Steps:**
1. **Read stdin.** Read it to the end on `[Console]::OpenStandardInput()`,
   decoded as UTF-8, 256 KB at most. Drop one leading U+FEFF, as
   [Read-ChatqMcpLine](../src/permit.ps1) does: a .NET Framework parent
   writes a BOM first.
   - Parse it for `session_id`, `transcript_path`, `cwd`,
     `permission_mode`, `hook_event_name` and `tool_name`.
   - Take `questionsRaw` with `Get-ChatqJsonRaw $text
     'tool_input.questions'`.
   - Its stdin has no `tool_use_id` (S46 T5).
2. **Set up.**
   - `rid = New-ChatqRandomName 10`.
   - `at = now`.
   - `qh` as in section 2.
   - These live **in the hook's memory** with `session_id` and
     `questionsRaw`. The hook writes its request file, and never reads it
     back. `Test-ChatqAskAnswer` takes the in-memory record.
3. **Check the gates** (5.1). A declined gate writes the request (step 5)
   with `state: 'declined'` and `why`, then exits 0 silently.
4. **Find its own call.**
   - Resolve the chat's transcript from `session_id` and the registry's
     `cwd` (section 2). Compare it with stdin's `transcript_path`, full
     path, ignoring case; if they differ, log it and use the resolved one.
   - Run `Get-ChatqPendingAsk` on it every 1 s, for up to 10 s, since the
     line may land just after the hook starts (S46 item 3).
   - A pending call whose questions equal `questionsRaw` gives its
     `ToolUseId`. With none found, the hook goes on with `toolUseId: null`.
5. **Write** `data/ask/<rid>.req.json` through
   [Save-ChatqJson](../src/queue.ps1), atomic:
   `{ v:1, rid, state, why, session, cwd, mode, questionsRaw, toolUseId, qh,
   at, until, hookPid, cliPid, cliStart }`.
   - `until = at + ask.waitMinutes` (default 240; 5-720).
   - `cliPid` and `cliStart` are the registry entry's `pid` and
     `procStart`. There is no parent-process fallback, since the parent may
     be a shell that lives exactly as long as the hook.
   - The hook rewrites this file only to change `state` (with
     `answeredAt`, or `badAnswer`).
6. **Wait**, one step each second:
   - **`<rid>.ans.json` is there.** Check it with `Test-ChatqAskAnswer`
     (5.4). If it verifies, go to step 7. If not, log it, set `badAnswer`,
     and keep waiting. A forged file changes nothing.
   - **Every 5 s: is the call gone?** With a `toolUseId`, that means a
     `tool_result` for it. Without one, it means no call equal to
     `questionsRaw` is pending. Either way, a real prompt after the call
     also counts. Then set `state: 'pc'` and exit silently.
     - This covers **Esc to cancel** too, and `askUserQuestionTimeout`
       ending the dialog by itself.
     - The registry's `status` is **not** used for this: what it says while
       a hook runs is unknown (S46 item 9).
   - **The CLI is gone** (`cliPid` not alive with `cliStart`): `state:
     'gone'`, exit.
   - **Past `until`:** `state: 'timeout'`, exit silently. The dialog stays.
   - **Every 10 s: did `config.json` change?** A change to its write time
     means it is read again. If `ask.on` is off or the pairing changed,
     set `state: 'off'` and exit.
7. **Answer.**
   - Write one line to stdout, as raw UTF-8 bytes, with
     `questionsRaw` spliced in byte for byte:
     ```json
     {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
      "updatedInput":{"questions":<questionsRaw>,"answers":{"<question text>":"<answer>"}}}}}
     ```
     - The keys and values of `answers` are written by
       `ConvertTo-ChatqJsonString`, a new escaper. It escapes only `"`,
       `\` and U+0000-U+001F, and leaves the rest as it is. So Hangul and
       `<>&'` come out as themselves. `ConvertTo-ChatqMcpJson` is not
       used: it is `ConvertTo-Json -Compress`, which escapes `<>&'` under
       5.1.
     - Never `behavior: deny`, never `updatedPermissions`, and never
       `interrupt`.
   - Then flush, set `state: 'answered'` with `answeredAt`, and exit 0.

**Cost** (S46 item 10).
- **Memory.** Each open request is one hidden Windows PowerShell, 124-137 MB
  once chatq is loaded. It sleeps between its 1 s looks. `ask.maxOpen` caps
  them at 5, about 0.65 GB at most.
- **Load time.** Loading chatq takes the hook 4-8 s. The hook starts beside
  the dialog, so that delays nothing at the PC: T4 and T4b saw
  `can_use_tool` go out before the hook started.
- **An answer at the PC in the first seconds.** It simply wins. The request
  is written after the load, so there is nothing for the phone to answer
  until then.
- **A lighter launcher**, one that loads only what the hook needs, is
  FUTURE_WORK.

### 5.3 The watcher's part

**The acts.** There are two, one per wire:
- **Alert-bound:** `chatq1`, act `answer`, from the `needs input` page.
  [Invoke-ChatqReply](../src/phone.ps1) gains an `answer` case. The alert
  entry gives the session and the transcript `path`.
- **Board-bound:** `chatq3c`, act `answer`, `Kind` `chat`, class `change`,
  age 1800 s, added to `$script:ChatqComposeActs`.
  - [Receive-ChatqCompose](../src/phone-board.ps1)'s `id` check covers
    `answer` as it covers `send`: `{ $_ -in 'send', 'answer' }`.
  - [Invoke-ChatqCompose](../src/phone-board.ps1) gains an `answer` case.
  - The pick gives the session. The transcript is resolved from it.

**`Invoke-ChatqAskReply -Payload -SessionId -Transcript -Raw -Via`.** Both
acts call it. It runs these checks in order, and says the first that fails:

| check | say |
|---|---|
| `ask.on` is off | `nothing answered - the PC takes no answers from the phone (chatnotify -Ask on)` |
| `rid` has the wrong shape, or `<rid>.req.json` is missing | `that question is no longer held - answer it at the PC` |
| the request's `session` is not this session | same as above, and logged |
| `state` is `pc` | `already answered at the PC` |
| `state` is `answered` | `already answered - from the phone at 14:02` |
| `state` is `declined` | its `why` text from 5.1 |
| `state` is `timeout`, `gone` or `off`, or it is past `until` | `too late - the phone could answer until 14:02; answer it at the PC` |
| the hook is not alive (`Test-ChatqAskHookAlive`) | the same `too late` line, and the request is rewritten `gone` |
| `qh` is not the digest remade from the request's `rid`, `session` and `questionsRaw` | `that question changed after it was shown - nothing sent`, and logged |
| the pending call in **the chat's transcript** (the `-Transcript` resolved from the session, never the request's) is missing, or does not match the request (5.1) | `that chat is not waiting on that question any more` |
| the answer's shape fails against the questions (5.4) | `answer every question - nothing sent` |

When every check passes:
1. It writes `<rid>.ans.json` = `{ v:1, rid, via, raw: <the message as
   posted>, at }`, atomic.
2. It remembers `@{ Rid; At; ToolUseId = <the pending call's id, from its
   own read>; Answers = <the answer text per question, 5.4> }` in
   `$script:ChatqAskSent` for 10 minutes.
3. It answers `sent your answer to <chat> - it goes on, unless it was
   answered at the PC first`. On the alert path that is the usual `reply`
   push, `-Quick`. On the board path it is the `ack`.

A push names the chat only, never the answer.

**What a request file can and cannot do.**
- The watcher takes nothing it acts on from a request without checking it
  against the chat:
  - the transcript comes from the session;
  - the questions are matched with that transcript's own pending call;
  - the hook is checked by process.
- So a request written by some other process cannot put a question on the
  phone that the chat did not ask.
- At worst, a process that can write into `data/ask/` makes a genuine
  phone answer go nowhere: it posts a copy of a real question under a rid
  of its own. The landed check below then says so.

**Landed, or not: `Test-ChatqAskLanded [-Now]`.** For each entry in
`$script:ChatqAskSent` at least 20 s old, it finds the `tool_result` for
`ToolUseId` in the chat's transcript. There are four outcomes:
- **None yet.** The answer did not land. It pushes `<chat> did not take the
  answer from the phone - answer it at the PC`, and logs `ask <rid> not
  taken`.
- **Present, and its `toolUseResult.answers` equals `Answers`.** Logged
  `landed`. Nothing is pushed.
- **Present, with other answers.** The PC answered first. Logged only.
- **Present, with no `answers`, or an error.** The CLI took the allow and
  dropped the answers. It pushes `<chat> went on without your answer - check
  it at the PC`.

This is the net under the undocumented behaviour. A later CLI that ignores
or mangles the hook's answer costs a push, not a silent loss.

It runs in two places:
- In the main loop, right after `Invoke-ChatqReplyPoll`, before the
  listening branch's `continue`.
- In [Invoke-ChatqJob](../src/watcher.ps1)'s `$onTick`, after its poll.

Each entry is dropped once it is checked, or after 10 minutes. The watcher
keeps running while the reply window is open, and an answer came through an
open window, so a watcher is there to check.

**Listening.** There is no new rule.
- The `needs input` alert opens the reply window, as every answerable alert
  does ([Test-ChatqReplyOpen](../src/phone.ps1)).
- The board works while the watcher listens, as now.
- An answer is read within the poll interval: 15 s while an alert is out,
  and 6 s for the 2 minutes after a board act
  ([Get-ChatqReplyPollSeconds](../src/phone-down.ps1)).

**Cleanup: `Remove-ChatqAskLeftovers`.** It runs at the watcher's start and
with each board it builds.
- An `open` request whose hook is dead becomes `gone`. One past `until`
  becomes `timeout`. Both are rewritten, not deleted.
- A request and its `.ans.json` are deleted only once they are not `open`,
  and are an hour past both `until` and their last change.
- So every `why`, every "already answered" line, the hourly count, and the
  landed check still have their file while it matters.

**Logs.** Each answer and each refusal goes to `data/logs/replies.log` as
`ask <rid> <chat>: sent|refused <why>|landed|not taken|dropped`. The hook
logs its side to `data/logs/ask.log`.

### 5.4 The answer, and `Test-ChatqAskAnswer`

**Payloads, both wires:**
- **`chatq1`** is made by `buildAnswerPayload(nonce, ts, x)` in the crypto
  block, and sealed by `sealAnswer(k, aid, x, fixed)`. It uses
  `buildPayload`'s layout with `act` `answer` and `text` empty, and adds
  `rid`, `qh`, `a` and `o` last, in that order, as a permit's `h` is added.
  So `reply-vector.json` stays byte for byte. `tests/fixtures/ask-vector.json`
  holds both wires. The page is held to it in `board-page-check.js` and
  `reply-page-check.js`, and the hook's check in `tests/sections/ask.ps1`.
- **`chatq3c`** goes through the existing `compose()`. `fieldsFor` gains
  `if (act === 'answer') return [['h', x.h], ['id', x.id], ['rid', x.rid],
  ['qh', x.qh], ['a', x.a], ['o', x.o]];` (its key order is the wire
  format). `buildComposePayload` then gives `{"v":3,"act":"answer","h":...,
  "id":...,"rid":...,"qh":...,"a":...,"o":...,"nonce":...,"ts":...}`.
- **`a`** has one array per question: the chosen options' indexes, 0-based,
  ascending, no repeats. **`o`** has one string per question: the Other
  text, `""` for none.
- **The phone never sends a label.** The hook takes the labels from its own
  `questionsRaw`, so the only free text that reaches Claude is Other.
- **Page ACTS.** Both `ACTS` lists gain `answer`.
  [Test-ChatqReplyMessage](../src/phone.ps1) takes an empty `text` for
  `answer`, as it does for a permit.

**The shape.** For each question:
- A single choice has exactly one index, or no index and a non-empty `o`.
- A multiple choice has at least one index or a non-empty `o`.
- Every index is within that question's options.
- `o` has its control and format characters (`\p{Cc}\p{Cf}`) made spaces,
  is trimmed, and is capped at 500 characters without splitting a surrogate
  pair, as a permit's refuse note is.

**The answer text** per question follows the webview's own rule: the chosen
labels in option order, then the Other text, joined with `", "`. So a single
choice is its label, or its Other text alone.

**`Test-ChatqAskAnswer $Req $Ans $Master $State`** is the hook's own check,
as [Test-ChatqPermitAnswer](../src/permit.ps1) is the bridge's.
- `$Req` is the hook's in-memory record, never the file.
- It opens `raw` with the phone's key D as it is now: `chatq1` through
  [Unprotect-ChatqReplyMessage](../src/phone.ps1), and `chatq3c` through
  [Unprotect-ChatqComposeMessage](../src/phone-down.ps1).
- It requires all of these:
  - `act` is `answer`.
  - `rid` is its own, and `qh` is its own digest.
  - `ts` is within [at - 1 min, until + 1 min].
  - The nonce has not been taken.
  - The shape is valid against its own questions.
- It returns `@{ Ok; Answers; Why }`, `Ok` only when all hold.

### 5.5 What an answer can do

- **It is text.** It goes to Claude as your answer: `Your questions have
  been answered: "<q>"="<a>". You can now continue with these answers in
  mind.` (S46 T1). No tool runs because of it, no permission is added, and
  no mode changes. Claude then acts on it in the chat's own mode, which is
  why the mode gate exists. It is checked as the question comes, and only
  then (5.1).
- **It is believed only on the phone's MAC, checked by the hook itself.**
  - The watcher only relays the message as posted.
  - A file written into `data/ask/` without the key does nothing.
  - D is stored DPAPI-protected for this Windows user, so malware running
    as you could open it. The boundary is the permit bridge's: the MAC
    stops a chat that writes files, not a process that already runs as you.
- **It is bound to one question.**
  - The `rid` and the digest name the session and the exact questions.
  - `ts` must fall within the request's time.
  - One answer per request: the hook exits after the first.
  - The watcher's cross-checks (5.3) come before any relay.
- **Nothing readable passes through anyone's servers.**
  - The question and its options go only on the sealed down topic.
  - The answer goes only as a sealed reply.
  - Pushes name the chat, and never the question or the answer.
- **The page's shared origin.** A script on another `phal40lax78.github.io`
  page could post an answer with the phone's key while a question is held.
  This is the permits' exposure (FUTURE_WORK, "The reply page on an origin
  of its own by default"). The setup window's tooltip says to serve the page
  from a site of your own first (`chatnotify -ReplyPage`).
- **Rate limits.**
  - On the board, `answer` is a `change` act: 20 an hour, shared with send
    and the job acts.
  - On an alert, it counts against the alert's 20 uses.
  - In the hook: 5 open at once, 30 an hour.
  - Refusals are rate-limited as every reply's are.

### 5.6 Who wins

The first answer wins:
- **The PC first.** The CLI takes the dialog's answer and drops the hook's
  later output (S46 T4). The hook sees the `tool_result` within 5 s and
  exits `pc`. A phone answer after that is told `already answered at the
  PC`.
- **The phone first.** The CLI takes the hook's answer and sends the host a
  `control_cancel_request` (S46 T4b). VS Code should close the dialog; S46
  item 1 checks that on screen. `Test-ChatqAskLanded` confirms the answer.
- **Both at once.** Whichever decision the CLI sees first counts, and the
  other is dropped. `Test-ChatqAskLanded` reads the recorded answers, and
  logs which one won.

Only `needs input` is pushed. It goes after 20 s of waiting while you are
away ([Update-ChatqLiveAlerts](../src/phone.ps1), unchanged). While you are
at the PC, nothing goes to the phone. The hook still holds the question,
and the board can still answer it if you look.

## 6. Install (Part B): a Claude Code plugin of chatq's own

**Why not edit `~/.claude/settings.json`:**
- chatq has never written the user's Claude settings (FUTURE_WORK, "Approve
  permission prompts: what 0.9.0 left out").
- The file is often kept by hand.
- 5.1's `ConvertTo-Json` re-escapes and reformats it.
- pwsh 7's `ConvertFrom-Json` turns ISO date strings into dates. That is the
  reason the bridge never re-serializes.

**Why a plugin:**
- Claude Code's own CLI installs and removes it, with `claude plugin
  marketplace add <path>` and `claude plugin install`, both present in
  2.1.283.
- The CLI writes its own `enabledPlugins` and `extraKnownMarketplaces`
  entries.
- It shows under `/plugin`, and in VS Code's Customize > Hooks.
- One command removes it.

**Files.** `Install-ChatqAskHook` writes these into `data/claude-plugin/`,
runtime files kept next to chatq in `data/`:
```
data/claude-plugin/.claude-plugin/marketplace.json
  {"name":"chatq-local","owner":{"name":"chatq"},
   "plugins":[{"name":"chatq-ask","source":"./chatq-ask","description":"chatq: answer Claude's questions from your phone"}]}
data/claude-plugin/chatq-ask/.claude-plugin/plugin.json
  {"name":"chatq-ask","version":"<$script:ChatVersion>-<first 8 hex of SHA-256 of the hook command>","description":"..."}
data/claude-plugin/chatq-ask/hooks/hooks.json
  {"hooks":{"PermissionRequest":[{"matcher":"AskUserQuestion","hooks":[{"type":"command",
    "command":"\"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"<chatq>/src/ask-hook.ps1\"",
    "timeout":43260,"statusMessage":"chatq: your phone can answer this too"}]}]}}
```
- **`timeout`** is 720 minutes, the most `ask.waitMinutes` allows, plus
  one. The hook's own deadline always comes first. A hook killed at its
  timeout changes nothing (S46 T5); whether that holds for `powershell.exe`
  is S46 item 10.
- **The version carries the command's hash.** A chatq that moved folders
  gives a new version, so the update below always runs.

**Which config dir.** The commands run with `CLAUDE_CONFIG_DIR` set to the
Claude home chatq's overlay watches (`$script:ChatClaudeHome`). That is the
one the VS Code chats use. `chatnotify` says which dir it installed into.

**Commands.** Run with [Find-ChatqExe](../src/queue.ps1) `'claude'`, and each
one's exit code checked.
- **On:**
  1. `claude plugin marketplace list --json`. If `chatq-local` is listed
     with a source other than `<data>/claude-plugin`, run `marketplace
     remove chatq-local` first. If it is not listed, run `claude plugin
     marketplace add "<data>/claude-plugin" --scope user`.
  2. `claude plugin install chatq-ask@chatq-local --scope user --json`.
  3. If it is already installed at another version: `claude plugin
     marketplace update chatq-local`, then `claude plugin update
     chatq-ask@chatq-local`.
- **Off:** `claude plugin uninstall chatq-ask@chatq-local`, then `claude
  plugin marketplace remove chatq-local`. `ask.on` becomes `false`.
- **A failure** prints what the CLI printed, and leaves `ask.on` as it was.

**`-Manual`** prints the `hooks` block for you to paste into your settings
yourself, and sets `ask.on`.
- `Get-ChatqAskHookState` reads the settings files (it never writes them)
  for a `PermissionRequest` entry with matcher `AskUserQuestion` that names
  `ask-hook.ps1`. Status then says `on (a hook you added)`, or `on, but no
  hook found`.
- A policy that allows only managed hooks (`allowManagedHooksOnly`) blocks
  both routes, and chatq does not write managed settings. When
  `Get-ChatqAskHookState` finds that setting:
  - `-Ask on` refuses, and changes nothing: `your Claude Code policy allows
    only managed hooks - the phone can show questions, not answer them`.
  - The status line says the same.
  - An administrator can add the `hooks` block that `-Manual` prints to
    the managed settings. That is the only route, and the README says so.

**Open chats.** A chat started before the install may not have the hook
until it is reloaded (S46 item 2). The line after install says: `new chats
can be answered from the phone; reload a VS Code window for the chats open
in it`. The exact words wait for S46.

**Uninstall.** chatq's uninstall runs `-Ask off` first. If that fails, it
stops and says so, rather than removing the launcher from under a live
plugin: every question would then start a PowerShell pointed at a missing
file. The README's "## Uninstall" says so.

## 7. Settings, commands, window (Part B)

`data/config.json`:

| key | default | |
|---|---|---|
| `ask.on` | `false` | the phone may answer Claude's questions in chats you run yourself |
| `ask.waitMinutes` | `240` | 5-720: how long the hook holds a question for the phone. The dialog stays either way |
| `ask.maxOpen` | `5` | config only: questions held at once, one hidden PowerShell each |

**[Set-ChatqNotifyConfig](../src/phone.ps1)** takes `Ask` (`on`/`off`) and
`AskWait` (5-720). Both are checked before anything is saved, as every key
there is.
- It saves every other key first. Only then does it run
  `Install-ChatqAskHook` or `Uninstall-ChatqAskHook`, and it sets `ask.on`
  only if that succeeds.
- `on` says: `questions from the phone on - a chat you run yourself that
  asks a question can be answered from the board or its alert; the PC's
  dialog stays open too`.
- With no phone paired it adds, in yellow: `no phone is paired - the
  questions only show at the PC`.

**`chatnotify -Ask on|off [-Manual]`, `-AskWait <min>`.** The status print
gains a line from `Get-ChatqAskStatusText`:
- `questions    off - the phone shows them, you answer at the PC`
- `questions    on - the phone can answer them for 240 min (plugin chatq-ask, C:\Users\me\.claude)`
- `questions    on, but the hook is not installed - chatnotify -Ask on`
- `questions    on, but the hook points at an old copy - chatnotify -Ask on`
- `questions    on, but no phone is paired - you answer at the PC`
- `questions    the last answer from the phone did not land - see data/logs/replies.log`

**The setup window** ([Show-ChatqPhoneSetup](../src/phone-setup.ps1)), in
REPLIES under **Approve tool calls from the phone**:
- **The checkbox.** `CheckBox AskBox`, "Answer Claude's questions from the
  phone". It is enabled only while `ReplyBox` is checked, and uses the same
  dirty/snapshot path as `PermitBox`.
- **Saving.** The install runs in the background runspace job the pairing
  uses, with the note `installing the question hook...`, so the window
  does not freeze on the `claude plugin` commands.
- **Hint:** "A question in a chat you run yourself shows on the phone with
  its choices; answer there or at the PC - the first answer counts. Adds a
  small hook to Claude Code, as a plugin."
- **Tooltip:** "This lets the phone answer for you in a chat. Serve the
  reply page from a site of your own first (chatnotify -ReplyPage)."

## 8. Failure paths

- **The hook fails to load, or throws.** No output and exit 0, so the
  dialog is as it was. `data/logs/ask.log` says why, and the view says
  `hook`.
- **The hook is killed at its timeout.** The dialog is untouched (S46 T5).
- **No watcher is listening.** No answer reaches the hook. It holds the
  question until `until`, and the dialog is there all along.
- **The pairing changed, or asks were turned off mid-wait.** The hook sees
  `config.json` change and exits `off`. An answer sealed under the old key
  would fail its check anyway.
- **The CLI does not take the hook's answer.** Either the call stays
  pending, or the CLI takes the allow and drops or changes the answers.
  `Test-ChatqAskLanded` pushes one of its two lines, and `chatnotify` says
  `the last answer from the phone did not land`. The dialog is unaffected
  where the call is still pending.
  - **The second case happens.** 2.1.283, given answers keyed to no
    question, closes the dialog and tells Claude `The user did not answer
    the questions.` (S46 item 7).
  - chatq keys its answers only by the questions' own texts, so it should
    never cause that. If it does, the landed check sees a question with no
    answer and pushes `went on without your answer`.
- **VS Code reloads while a question is held.**
  - The webview shows the question again from the transcript.
  - If the same claude process lives on, the hook goes on.
  - If not, `cliPid` is gone, and the hook exits `gone`. The question then
    shows `late`, and is answered at the PC.
- **The PC sleeps.** The hook sleeps with it. An answer read after wake,
  before `until`, still goes in.
- **The same chat is open in two windows.** Either window, the hook or the
  phone may answer, and the CLI takes the first. The landed check reports
  which won.
- **A new CLI changes any of this.** S46 is run again when a new CLI comes
  out, and TESTING.md records the result. The landed check catches what it
  missed.

## 9. Out of scope

- **A question open before the hook was loaded** - the case that started
  this. It is shown, with `hook`. Driving the webview from outside with UI
  automation would move your mouse or focus, and break on any change to the
  extension.
- **Questions in chatq's queued runs.** The MCP permit bridge cannot answer
  them: the CLI turns an allow for a tool that requires interaction into a
  deny. A run-scoped `PermissionRequest` hook might work, but those runs
  deny the tool by design today. That needs S46 item 8 and a design of its
  own (FUTURE_WORK).
- **Terminal chats** (`claude` in a console) are shown in Part A. In Part B
  they are declined `term` until S46 item 4 shows the TUI takes the hook's
  answer and closes its own prompt.
- **Codex** has no question tool.
- **Previews** (an option's `preview`, markdown or html), `annotations`,
  and the SDK's free-form `response`.
- **Declining or cancelling from the phone** (Esc). The hook never denies;
  to say "none of these", use Other.
- **Plan approval** (`ExitPlanMode`) is likely the same kind of card, and a
  candidate for the same hook later (FUTURE_WORK). It is not checked.
- **The desktop overlay** showing the question: the dialog is on that
  screen already.
- **macOS and Linux.** The launcher is written for pwsh there, but never
  run. There are no live alerts off Windows, and the board works as it does
  now.

## 10. Functions, by file

As built.

**Part A:**
- **[src/ask.ps1](../src/ask.ps1)** is a new part, after `'permit'` in
  `$chatParts`:
  - `Get-ChatqPendingAsk`, `ConvertTo-ChatqAskQuestions`,
    `Test-ChatqAskSame`.
  - `Get-ChatqAskShown`, `ConvertTo-ChatqAskCut`, `Get-ChatqAskView`,
    `Get-ChatqAskWhat`, `Get-ChatqAskTranscript`.
- **[ConvertTo-ChatqPhoneBoard](../src/phone-board.ps1):** gains the
  optional `-Asks`.
- **[Get-ChatqPhoneBoard](../src/phone-board.ps1):** builds `-Asks`.
- **[Send-ChatqReplyText](../src/phone-down.ps1):** reordered, as in 4.4.
- **docs/reply.html:**
  - `askView` (the board block).
  - `drawAsk` and `askBoxOf`, and the `#ask` and `#cAsk` boxes.
  - `settlePanel` and `openChat` draw the card.
- **claude-codex-chat-manager.ps1:** `$chatParts` gains `ask`.

**Part B:**
- **[src/ask.ps1](../src/ask.ps1):**
  - The config: `Get-ChatqAskConfig`, `Read-ChatqAskChanges`,
    `Set-ChatqAskChanges`.
  - The request: `Get-ChatqAskDigest`, `Get-ChatqAskQuestionsOf`,
    `Get-ChatqAskRequests`, `Get-ChatqAskMatch`, `Set-ChatqAskState`,
    `Test-ChatqAskHookAlive`.
  - The answer: `ConvertTo-ChatqJsonString`, `ConvertTo-ChatqAskAnswers`,
    `New-ChatqAskDecision`, `Test-ChatqAskAnswer`.
  - The hook: `Start-ChatqAskHook`, `Test-ChatqAskGates`,
    `Read-ChatqAskStdin`, `Write-ChatqAskStdout`, `Get-ChatqAskClaudeHome`,
    `Write-ChatqAskLog`.
  - The watcher's side: `Invoke-ChatqAskReply`, `Get-ChatqAskResult`,
    `Test-ChatqAskLanded`, `Get-ChatqAskMissed`, `Remove-ChatqAskLeftovers`.
  - Install: `Write-ChatqAskPlugin`, `Get-ChatqAskHookCommand`,
    `Get-ChatqAskHooksBlock`, `Get-ChatqAskPluginVersion`,
    `Invoke-ChatqAskCli`, `Get-ChatqAskHookState`, `Install-ChatqAskHook`,
    `Uninstall-ChatqAskHook`, `Get-ChatqAskStatusText`.
- **[src/ask-hook.ps1](../src/ask-hook.ps1):** the launcher (5.2). It is not
  a part, so [extension/build.js](../extension/build.js) ships it beside
  them. install.ps1 and the extension's setup copy every `src/*.ps1`.
- **Changed:**
  - [Read-ChatqSessionRegistry](../src/live-chats.ps1): `Version`.
  - `$script:ChatqComposeActs`: the `answer` act.
    [Receive-ChatqCompose](../src/phone-board.ps1): its `id` check, and it
    hands the raw message on.
  - [Invoke-ChatqCompose](../src/phone-board.ps1) (`-Raw`) and
    [Invoke-ChatqReply](../src/phone.ps1): the `answer` case each.
  - [Set-ChatqNotifyConfig](../src/phone.ps1): `Ask`, `AskWait`,
    `AskManual`.
  - `chatnotify` in [src/commands.ps1](../src/commands.ps1): `-Ask`,
    `-AskWait`, `-Manual`, and the status line.
  - [chatuninstall](../src/discoverability.ps1) `-All`: the plugin first.
  - [Show-ChatqPhoneSetup](../src/phone-setup.ps1): `AskBox` and its
    background install.
  - The watcher: [Repair-ChatqInterrupted](../src/watcher.ps1) runs
    `Remove-ChatqAskLeftovers`. The main loop and
    [Invoke-ChatqJob](../src/watcher.ps1)'s `$onTick` run
    `Test-ChatqAskLanded` after their polls.
  - docs/reply.html:
    - The crypto block: `buildAnswerPayload`, `sealAnswer`.
    - The board block: both `ACTS` lists, `fieldsFor`, and `askView`'s
      answerable state with its helpers.
    - The UI block: the controls, the drafts and `sendAnswer`.

## 11. Tests

**`tests/sections/ask.ps1`** is a new section after `phone-board.ps1`, run on both
CI legs.

**Part A:**
1. **`Get-ChatqPendingAsk`**, on synthetic transcripts:
   - A call pending, and one answered, which gives `$null`.
   - A side chain's call, which is skipped. Two questions.
   - A real prompt after the call, which gives `$null`.
   - A tail cut through a line.
   - Hangul in every field. Five options, shown as four with `More`.
   - A 2500-character description, cut at 2000 with no split pair.
   - Past 16 KB, the longest descriptions cut first, with `Cut`.
   - `Mode` from the newest record. The cache hit.
2. **`Test-ChatqAskSame`.** A changed label or description is not the same,
   and nor is a swapped pair of options.
3. **The board and the alert:**
   - `ConvertTo-ChatqPhoneBoard -Asks` gives the `open` row's `ask` and
     `what`. Without `-Asks`, the board is byte for byte as today.
   - `Send-ChatqReplyText` for a live `needs input`: full on, the body
     carries `parts` and `ask`. Full off, `parts: []` and `ask`, counted
     `other`. Full off with no question, today's refusal. `-Again` carries
     the ask.

**Part B:**
4. **The digest, and `Test-ChatqAskAnswer`**, with answers sealed by
   [Protect-ChatqReplyMessage](../src/phone.ps1) and
   [Protect-ChatqComposeMessage](../src/phone-down.ps1):
   - Valid on both wires.
   - Refused: the wrong `rid`, the wrong `qh`, a `ts` outside the window,
     a nonce reused, an unsealed `{"act":"answer"}`, and a message sealed
     under another key.
   - Shape errors refused: an index out of range, two indexes on a single
     choice, a multiple choice with nothing chosen.
   - Other text with control characters is cleaned, and capped at 500.
5. **`ConvertTo-ChatqAskAnswers`, `ConvertTo-ChatqJsonString`,
   `New-ChatqAskDecision`:**
   - A label; `"Red, Blue"`; Other alone; labels, then Other.
   - `questionsRaw` spliced byte for byte, with Hangul, `<>&'` and `\"`
     inside it.
   - `answers` with `<>&'` written as themselves, under 5.1 and 7.
   - The line parses as JSON.
6. **The hook as a real child.** The test plays claude.
   - **Set-up.**
     - A sandbox `CLAUDE_CONFIG_DIR` holds a `sessions/<pid>.json` for a
       started `node` child, with its real `procStart` and `entrypoint`
       `claude-vscode`, plus a transcript.
     - The test starts the launcher with redirected stdio. It writes a
       `PermissionRequest` stdin **behind a BOM**, as the bridge's test
       sends `initialize`.
   - **Seams.** `CHATQ_ASK_WAIT_SECONDS` and `CHATQ_ASK_STEP_MS` are
     environment variables, read by `Start-ChatqAskHook` for tests only.
   - **Answering and waiting:**
     - Stdout stays empty until an answer.
     - The request file appears, with Hangul intact.
     - A valid sealed `.ans.json` gives the decision within 2 s, then exit
       0.
     - A forged `.ans.json` gives nothing, and the hook keeps waiting.
     - A rewritten `.req.json` (another `questionsRaw`, another `qh`)
       changes neither the check nor the decision.
   - **Leaving without an answer:**
     - The transcript gains the `tool_result`: silent exit within 6 s,
       `pc`.
     - The node child killed: exit, `gone`.
     - The deadline: silent exit, `timeout`.
   - **Gates:**
     - `bypassPermissions` over a cap of `acceptEdits` is `declined`
       `mode`.
     - `entrypoint` `cli` is `declined` `term`.
     - No registry entry, or `ask.on` off, writes nothing.
     - A load failure (a missing part) still exits 0, with a line in
       `ask.log`.
   - The same loop runs once under pwsh 7 when present.
7. **`Get-ChatqAskView` and the matching:**
   - `can` with an open request whose hook is alive.
   - `late` when the hook pid is dead, or alive but another process's.
   - Each declined `why`.
   - `hook` with no request.
   - A request naming another transcript, or other questions, is never
     shown.
   - Of two matching requests, the newest wins.
8. **The acts**, through `Invoke-ChatqReplyPoll -Force` with
   `ChatqReplyPollSeam`:
   - `answer` from an alert and from the board writes `.ans.json` with the
     raw message, and answers with the push or the ack.
   - Each refusal in 5.3's table.
   - A board `answer` whose `id` does not match its handle is refused.
   - `answer` is counted as `change`.
9. **`Test-ChatqAskLanded -Now`:**
   - `did not take` when no `tool_result` comes.
   - Silent, `landed`, when the answers match.
   - Logged only, when the PC's answer won.
   - `went on without your answer` when the result has no `answers`.
10. **Cleanup.** A dead open request becomes `gone`, and is not deleted.
    Nothing is deleted before an hour past `until`. The hourly count
    includes settled requests.
11. **Install:**
    - `Install-ChatqAskHook` with an exe seam: the three files, the
      version's hash, and each `claude plugin` argv in order. That includes
      remove-then-add when the marketplace's source differs, and the update
      when the version changed.
    - A failed install leaves `ask.on` unchanged.
    - `-Manual` prints the block and runs nothing.
    - `Get-ChatqAskHookState` finds a hand-added hook.
    - The uninstall stops when `-Ask off` fails.

**Page** (`tests/reply-page-check.js`, `tests/board-page-check.js`):
- **`askView`:**
  - A Part A view (no `can`) is read-only with `Answer it at the PC.`
  - Covered: single, multiple, Other, `more`, `cut`, each `why`, and `late`
    after `until`.
  - Send stays off until every question has an answer.
- **The wire.**
  - A new `tests/fixtures/ask-vector.json`, made by
    `tests/fixtures/make-ask-vector.js`: `buildAnswerPayload` and the
    compose `answer` sealed byte for byte, and opened in PowerShell by
    `Test-ChatqAskAnswer`.
  - `reply-vector.json` and `compose-vector.json` are unchanged.
  - Both `ACTS` lists hold `answer`, and each is an act the watcher knows.
- **The page's own rules.** No `innerHTML` or the rest. A draft is kept per
  `rid`. A `reply` body with empty `parts` and an `ask` shows the card
  alone.

**S46, spike against the real CLI and VS Code.**

Part 1 ran 2026-09-28:
- **Set-up.** `claude.exe` 2.1.283 from the VS Code extension, run with
  `--model haiku`, `--no-session-persistence` and `--tools
  AskUserQuestion`. A Node host script played the extension:
  `--permission-prompt-tool stdio`, `initialize`, `can_use_tool`.
- **Hooks.** Node scripts, not PowerShell.
- **Cost.** Six runs, about $0.20.

| test | set-up | seen |
|---|---|---|
| T1 | no hook; the host answers `{"Pick a color":"Blue"}` | `can_use_tool` for AskUserQuestion with `requires_user_interaction:true`; tool_result `Your questions have been answered: "Pick a color"="Blue"...`; Claude says Blue |
| T2 | PreToolUse hook: allow + `updatedInput{questions, answers:Red}` | **no `can_use_tool` at all**; Claude says Red |
| T3 | PreToolUse hook sleeps 15 s, prints nothing | `can_use_tool` only after the hook ends, 15.1 s late: a PreToolUse hook holds the dialog back |
| T4 | PermissionRequest hook answers Red; the host answers Blue at once | `can_use_tool` goes out ~3 ms **before** the hook starts; the host's Blue wins; the hook's later Red is dropped |
| T4b | the same; the host waits 10 s | the hook's Red at +0.1 s wins; the CLI sends `control_cancel_request` to the host; Claude says Red |
| T5 | PermissionRequest hook, `timeout` 5, sleeps 20 s; multiSelect; the host answers `Red, Blue` at 12 s | the hook is killed at ~5 s (`cancelled`, no output); the host's prompt stays open and its later answer works; `"Red, Blue"` reads as both |

- PermissionRequest stdin carries `session_id`, `transcript_path`, `cwd`,
  `scratchpad_dir`, `prompt_id`, `permission_mode`, `hook_event_name`,
  `tool_name` and `tool_input`. It has **no `tool_use_id`**. PreToolUse's
  stdin has one.
- **Why PermissionRequest, not PreToolUse.** A PreToolUse hook that waits
  holds the dialog back for as long as it waits (T3). A PermissionRequest
  hook runs beside it (T4, T4b).
- **Not seen in part 1:**
  - The registry (`-p`).
  - A transcript (`--no-session-persistence`).
  - A PowerShell hook.
  - The real VS Code UI.

Part 2 ran the items a script can, on 2026-09-29.
- **Set-up.** The same host, `--model haiku` and `--tools AskUserQuestion`.
  Item 3 ran with the session kept, so a transcript was written. The plugin
  was loaded with `--plugin-dir`.
- **Cost.** Ten runs.

| item | seen |
|---|---|
| 3 | the `tool_use` line was in the transcript 0.35 s before the hook read it; its id the `can_use_tool` one |
| 5 | a plugin's PermissionRequest hook fires for AskUserQuestion and answers - `control_cancel_request` to the host, Claude takes it; `timeout` 43260 raised no error; a hook with no `timeout` ran 75 s unkilled (so not 60 s; 600 or none not seen) |
| 6 | in `plan` and in `bypassPermissions` the hook fires, its stdin's `permission_mode` the real one, and `can_use_tool` still reaches the host |
| 7 | an edited label in `updatedInput.questions` is taken, and Claude is told `The user answered: ...` (other wording); answers keyed to no question close the dialog with `The user did not answer the questions.` |
| 9 | the registry says `waiting`, `input needed`, unchanged, all the while the hook holds the question; a `-p` run registers, its entrypoint from the environment |
| 10 | `powershell.exe -File` loads chatq in 4-8 s, 124-137 MB; its parent is Git bash (two `bash.exe`), not claude; a kill at the timeout ends the whole tree; stdout holds the decision line only, no BOM on stdin |

What only a person can check, S47's before `-Ask on` is recommended:
1. **In real VS Code, with the plugin installed:**
   - A new chat asks. Answer from the phone: does the dialog close?
   - What does the panel show while the hook runs: `statusMessage`, a
     spinner, or nothing?
   - Answer at the PC first: does the CLI end the hook, or does the hook's
     5 s look end it?
2. **A hook installed while a chat is open.** Is it picked up? Does
   `/reload-plugins` or a window reload do it? Record the words the install
   line must say.
4. **The terminal `claude` TUI.** Does the PermissionRequest hook run beside
   its prompt, and does the hook's answer close it? It must, before `term`
   is dropped.

Still open, for later: item 8 - a queued run with `--permission-prompts
host`, a run-scoped PermissionRequest hook, and the MCP prompt tool. Which
is asked first? Does `localDisplayOnly` deny before the hook can answer?

**S47, by hand with the phone** (Part A, then Part B after S46 part 2):
- **Part A.**
  - Make a chat ask, and leave the PC alone for 5 minutes.
  - The push says only `waiting on you: input needed (a question)`.
  - The page shows the question, every option with its whole description,
    and `Answer it at the PC.`
  - The board from the bookmark shows the same card.
- **Part B, one run each:**
  - `-Ask on`, and a new chat asks. Answer from the phone: within about
    20 s the dialog closes, and the chat goes on with that answer. The
    transcript's `answers` shows it, and `replies.log` says `landed`.
  - Two questions, one multiple choice and one answered with Other.
  - Answered at the PC first: the phone's Send is told `already answered
    at the PC`.
  - A `bypassPermissions` chat: read-only, `mode`.
  - A question open before `-Ask on`: read-only, `hook`.
  - A terminal chat: `Answer it in the terminal.`

## 12. Docs, when built

**Part A:**
- **README**, "Chats you run yourself": the `needs input` alert's page, and
  the board, show the question with its choices. It is answered at the PC.
- **CHANGELOG.**
- **TESTING.md**: the `ask.ps1` paragraph for Part A, and S47 Part A.

**Part B:**
- **README:**
  - "## Alerts" gets `### Answer Claude's questions from the phone`, after
    "Approve a tool call from the phone". It covers what answers, the mode
    gate, the first answer winning, and the landed check.
  - "Not covered" in the permit section loses "answering a question".
  - The `chatnotify` switch table and the config table gain the keys.
  - "What passes through whose servers" gains a line: the question on the
    down topic, and the answer on the reply topic, both sealed.
  - "## Uninstall" gains `-Ask off`.
- **CHANGELOG.**
- **TESTING.md**: S46 part 2's results, and S47 Part B.
- **FUTURE_WORK.md:**
  - "Approve permission prompts: what 0.9.0 left out" loses
    `AskUserQuestion` from its last bullet.
  - New entries, each with why it is deferred and what would close it:
    questions in queued runs (S46 item 8), a question open before the hook,
    terminal chats until S46 item 4 passes, and plan approval through the
    same hook.
