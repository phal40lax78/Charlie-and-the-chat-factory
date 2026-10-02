# Spec: approve a permission prompt from the phone mid-run

Status: built for 0.9.0 (src/permit.ps1, tests/sections/permit.ps1), with
the S35 spike's answers recorded under section 12. It closes FUTURE_WORK.md's
"Approve permission prompts from the phone" for chatq's own headless Claude
runs, and leaves the rest of that entry (VS Code chats, the console) open.
Every security choice of phone-spec v1-v4 and review/review2/review4 stands:
no key in any push, every act MAC-verified, `reply.maxMode` unchanged,
pairing by code, rate limits. The command is `chatnotify` (`chatqnotify`
stays an alias).

## 0. What is true today (read from the code)

- **How a run goes.** [Invoke-ChatqRun](src/queue.ps1) starts
  `claude -p --resume <id> --output-format stream-json --verbose
  --permission-mode <mode> --permission-prompts none` through
  [Invoke-ChatqProcess](src/queue.ps1), prompt on stdin. The mode is
  `job.mode`, else `job.modeAtQueue`, else `default`.
- **`--permission-prompts none`** (CLI 2.1.259+): anything that would prompt
  is denied, Claude is told nobody can approve it and not to retry, and
  `AskUserQuestion` is removed. With the default `host`, prompts go to the
  SDK host or the `--permission-prompt-tool` tool, and the run waits for it.
- **"Needs input" today.** [Get-ChatqClaudeOutcome](src/queue.ps1) makes a
  job `needs-input` when the result has `permission_denials` (reason
  `denied Bash(git push), ...`), when a plan-mode run ends (`plan ready -
  approve it in VS Code`), or at `error_max_turns`.
  [Invoke-ChatqJob](src/watcher.ps1) then sends `needs input` (priority 2).
  From the phone, **Allow edits & continue** requeues it in `acceptEdits`
  capped by `reply.maxMode` ([Invoke-ChatqReply](src/phone.ps1), act
  `allow`) - after the fact, for a mode, not for the one call. For a chat
  you run yourself, `needs input` is the overlay's 20 s wait
  ([Update-ChatqLiveAlerts](src/phone.ps1)); nothing answers it from away.
- **The watcher mid-run.** `$onTick` in [Invoke-ChatqJob](src/watcher.ps1)
  runs from [Invoke-ChatqProcess](src/queue.ps1)'s `$check`: every 5 s while
  stdout is silent, and at most every 5 s while it streams. It polls the reply
  topic every 30 s (`Invoke-ChatqReplyPoll -TimeoutSec 5 -MinSeconds 30
  -MaxMessages 2 -Quick`). While Claude waits on a permission its stdout is
  silent, so `$onTick` comes round every 5 s.
- **Codex.** chatq runs `codex exec`, whose approval policy is `never`: a
  call that would need approval is refused and the model gets the error
  back, so a Codex job never asks mid-run. That is how chatq runs it, not a
  wall: codex-cli 0.159.2 has a `PermissionRequest` hook event and, in its
  app server, approval requests of its own. Codex is left out of this spec
  until a spike picks a way in (section 11).

## 1. The contract we build on (Claude Code docs, read 2026-09-26)

Sources: code.claude.com/docs/en/cli-reference, /headless,
/agent-sdk/user-input, /env-vars, /mcp; `claude --help` of the bundled
2.1.283, where `--permission-prompt-tool` is a hidden flag.

- `--permission-prompt-tool mcp__<server>__<tool>`: an MCP tool that handles
  permission prompts in `-p`. Claude Code waits for the server to connect
  before the first turn, up to `MCP_TIMEOUT` (30 s). It cannot approve an MCP
  tool marked as requiring user interaction (2.1.199+).
- Only prompts reach it. Deny rules, allow rules, the mode, and the `auto`
  classifier decide first. `dontAsk` and `bypassPermissions` never prompt.
- **The tool is called with** `{ "tool_name": "Bash", "input": { ... },
  "tool_use_id": "toolu_..." }`.
- **It answers with** one text content block holding JSON:
  `{"behavior":"allow","updatedInput":{...}}` or
  `{"behavior":"deny","message":"..."}`. Since 2.1.207 an allow may leave
  out `updatedInput`, and the tool then runs with the input Claude asked for.
  We never send `updatedPermissions` ("always allow") or a changed input.
- **Timeouts.** `MCP_TOOL_TIMEOUT` defaults to 10 minutes (clamped 1 s to
  30 min). A stdio call with no response and no progress aborts after 30
  minutes of idle (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`). What a timed-out or
  failed permission call becomes (a deny, or a failed run) is not documented
  -> spike S35 item 2. Our own deadline always comes first (section 5).
- **`--mcp-config <file-or-json>`**: `{"mcpServers":{"<name>":{"type":"stdio",
  "command":"...","args":[...],"env":{...}}}}`. The flag is variadic, so it is
  always followed by another `--` flag.
- **stdio MCP** is JSON-RPC 2.0, one message per line, UTF-8, no embedded
  newline. It is `initialize` (answered with `protocolVersion`,
  `capabilities.tools`, `serverInfo`), then the notification
  `notifications/initialized`, then `tools/list` and `tools/call`, with
  `ping` at any time and `notifications/cancelled` for a call abandoned.
- **A PowerShell 5.1 server is practical**, with care:
  - Read and write the raw streams (`[Console]::OpenStandardInput()` /
    `OpenStandardOutput()`) as UTF-8. Never `Write-Output`, `Write-Host` or
    `[Console]::In`: the console code page here is 949.
  - Nothing else may reach stdout. The load is wrapped in `| Out-Null`,
    `$ProgressPreference = 'SilentlyContinue'`, and errors go to a log.
  - `ReadLineAsync` plus `Task.Wait(250)` keeps it answering `ping` while a
    call waits.
  - **Never re-serialize the tool input.** pwsh 7's `ConvertFrom-Json` turns
    ISO date strings into `[datetime]`, and 5.1 escapes `<>&'`. The bridge
    keeps the raw `input` text, cut out of the line by a string-aware brace
    matcher, and allows without `updatedInput`. Fallback, if S35 item 1
    shows an allow needs it after all: splice that raw text back as
    `updatedInput`, never a re-serialized copy.

## 2. Shape

```
watcher (PowerShell) --stdin/stdout--> claude -p --permission-prompt-tool mcp__chatqpermit__decide
     ^   | onTick, every 5 s                    |
     |   |                                      | stdio JSON-RPC
     |   v                                      v
     |  data/permit/<jobId>/  <--- files --->  bridge: powershell.exe running Start-ChatqPermitBridge
     |   <rid>.req.json   (bridge writes: what is asked)
     |   <rid>.sent.json  (watcher writes: the alert's aid and deadline, or "declined")
     |   <rid>.ans.json   (watcher writes: the phone's sealed answer, as posted)
     |
  ntfy.sh reply topic <--- the page posts the sealed permit / refuse
  Join / ntfy alert   ---> "chatq · permission" push with a sealed card in its link
```

**One poller.** The watcher stays the only process that polls the reply
topic, keeps the cursor and the nonce ledger, sends pushes, and judges acts.
It also does the rate limiting. The bridge does no network I/O and sends no
push. It never touches `replies.json`.

**Why a file, not the bridge polling itself:**
- Two pollers of one topic would fight over `lastId`.
- A `stop` or a prompt could land in the bridge, inside claude's process
  tree, and be acted on from there.
- The watcher's `$onTick` already runs every 5 s while Claude waits, and
  Claude is blocked on the call anyway. A few seconds of network in that
  tick holds up nothing but the wait itself.

**Why the file is not trusted:**
- A chat whose folder holds chatq's `data/` can write there in `acceptEdits`
  with no prompt, and so can any local process.
- So the bridge takes an allow only on the phone's own sealed message. It
  opens that message itself with the phone's key and checks that it names
  this request (section 6).
- A forged file can only deny.

## 3. When the bridge is used, and the fallback

`Test-ChatqPermitReady $Cfg $Job` returns `@{ Ok; Why }`. Ok only when all of
these hold:
- `permit.on` is true. The switch is **off by default**: it lets the phone
  run a command it could not run before (section 7).
- Replies are on and a phone is paired (`(Get-ChatqReplyConfig).Links`).
- A channel carries links ([Test-ChatqLinkChannel](src/phone.ps1)).
- The job is Claude's.
- The CLI is at `$script:ChatqPermitMin` (`2.1.259`) or later. Found with
  [Get-ChatqCliVersion](src/queue.ps1), which [Invoke-ChatqRun](src/queue.ps1)
  already calls.
- The run's mode is `default`, `manual`, `acceptEdits` or `auto`:
  - `dontAsk` and `bypassPermissions` never prompt.
  - `plan` keeps today's "plan ready - approve it in VS Code" exactly.
- The job does not have `permitOff` (section 9, a bridge that failed).

When any of these fails, the argv is today's, byte for byte:
`--permission-prompts none`, no `--mcp-config`. Every existing test keeps
holding.

When all hold, [Invoke-ChatqRun](src/queue.ps1) takes `-Permit $run` from
`New-ChatqPermitRun` and makes these changes:
- `--permission-prompts none` becomes `--permission-prompts host`.
- `--mcp-config <data/permit/<jobId>/mcp.json>` is added.
- `--permission-prompt-tool mcp__chatqpermit__decide` is added.
- `--settings <data/permit/<jobId>/settings.json>` is added. The files stay
  off the command line: `claude.cmd` runs through cmd.exe, which can be
  handed no `"` at all ([Get-ChatqCmdArgRefusal](src/queue.ps1)).
- `-SetEnv` gains `MCP_TOOL_TIMEOUT = (waitMinutes + 3) * 60000`.

`settings.json` (the run's own, merged over the user's by Claude Code):

```json
{ "permissions": { "deny": [
  "AskUserQuestion",
  "Edit(//c/Users/me/Tools/VS-code-chat-manager/data/**)",
  "Write(//c/Users/me/Tools/VS-code-chat-manager/data/**)",
  "NotebookEdit(//c/Users/me/Tools/VS-code-chat-manager/data/**)"
] } }
```

Notes on this file:
- `AskUserQuestion` is removed, as `none` removed it: nobody answers
  questions mid-run.
- The path rules are defence in depth. They keep a run from editing chatq's
  own data, reply state and permit files without a prompt. S35 item 5 checks
  the `//c/...` form on Windows. If the form does not work, the rules are
  dropped, and section 6 still holds on its own.

`mcp.json`, from `Get-ChatqPermitLaunch -JobId -RunId`. It is built the way
[Get-ChatqOutboxLaunch](src/phone.ps1) is:

```json
{ "mcpServers": { "chatqpermit": {
  "type": "stdio",
  "command": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  "args": ["-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-OutputFormat","Text","-EncodedCommand","<b64>"],
  "env": { "SystemRoot": "C:\\Windows", "USERPROFILE": "...", "APPDATA": "...", "LOCALAPPDATA": "...", "PSModulePath": "<5.1's own>" }
} } }
```

- The encoded command:
  `$ProgressPreference='SilentlyContinue'; $env:CHATQ_OVERLAY='1';
  . '<script>' | Out-Null; Remove-Item env:PSExecutionPolicyPreference,
  env:CHATQ_OVERLAY -EA 0; Start-ChatqPermitBridge -JobId '<id>' -RunId
  '<run>'`
- A failure to load goes to `data/logs/permit.log`, as the sender's does.
- `env` is there in case Claude Code hands a stdio server only a minimal
  environment (S35 item 4).
- Off Windows, `command` is the running PowerShell (`(Get-Process -Id
  $PID).Path`). That path is written, not run, like the rest of the Unix
  side.
- The server is named `chatqpermit`, not `chatq`, so it cannot clash with an
  MCP server of the user's that shares chatq's name.

## 4. The bridge: `Start-ChatqPermitBridge` (src/permit.ps1)

A new part, `src/permit.ps1`, goes into `$chatParts` in VS-code-chat-manager.ps1
right after `'phone'`. Its functions:

| function | does |
|---|---|
| `Start-ChatqPermitBridge -JobId -RunId` | the stdio loop; exits 0 when stdin closes |
| `Read-ChatqMcpLine` / `Write-ChatqMcpMessage` | UTF-8 line framing on the raw streams; one `Flush()` per message |
| `Invoke-ChatqMcpRequest $Msg $State` | dispatch by `method` |
| `Get-ChatqJsonRaw $Line 'params.arguments.input'` | the raw JSON text of one member, string-aware, `$null` when it cannot be found |
| `Get-ChatqPermitRule $Tool $Input $State` | `$null` (ask the phone) or the deny message |
| `Get-ChatqPermitDigest $Rid $Tool $InputRaw` | `b64url(SHA-256(UTF8("chatq-permit`n" + rid + "`n" + tool + "`n" + inputRaw))[0..15])` |
| `Test-ChatqPermitAnswer $Req $Ans $Master $State` | an allow is believed only here |

**Dispatch:**
- `initialize`: `result = { protocolVersion: <the client's own if in
  '2024-11-05','2025-03-26','2025-06-18','2025-11-25', else '2025-06-18'>,
  capabilities: { tools: {} }, serverInfo: { name: 'chatqpermit', version:
  $script:ChatVersion } }`.
- `notifications/*`: no reply. `notifications/cancelled {requestId}` drops
  that pending call, and writes `<rid>.req.json`'s `withdrawn: true`.
- `ping`: `result = {}`.
- `tools/list`: one tool, `decide`:
  - description: "chatq's own: routes this run's permission prompts to the
    user's phone. Never call it yourself."
  - `inputSchema`: `{type:'object', properties:{tool_name:{type:'string'},
    input:{type:'object'}, tool_use_id:{type:'string'}}, required:
    ['tool_name','input']}`.
- `tools/call` with `name = decide`: section 5. Any other name gets the
  error `-32602`.
- Anything else with an `id` gets `{code:-32601, message:'Method not found'}`.
- Any exception while a call is handled is answered as a deny ("chatq's
  permission bridge failed - denied"), logged, and the loop goes on.

**Its state, in memory for the life of the run:** the pending requests
(rid -> JSON-RPC id, tool, raw input, digest, deadline), the count asked this
run, `Missed` (a request that ran out unanswered), and the nonces and aids
already taken.

**The loop:**
- A `ReadLineAsync` is waited in 250 ms steps.
- Between steps, each pending request looks for `<rid>.sent.json` and
  `<rid>.ans.json` (`Test-Path`, then read) and checks its deadline.
- Several calls can wait at once. Their answers go out in whatever order
  they are settled.

## 5. One request, start to end

Bridge, on `tools/call`:
1. `tool_name` must be a string of 1-100 characters, `input` an object, and
   the raw input text found. Else it denies ("could not read the request").
2. `Get-ChatqPermitRule` denies at once, with no push, for:
   - `AskUserQuestion`: "Nobody can answer questions during this run. Make
     the most reasonable choice, say which, and go on."
   - `ExitPlanMode`: "The plan waits for approval in VS Code." (belt and
     braces: plan mode never gets the bridge).
   - a tool not in `permit.tools`. The default is `Bash, PowerShell, Edit,
     Write, MultiEdit, NotebookEdit, WebFetch`; `mcp__*` and anything else
     only when listed.
   - `Edit`/`Write`/`MultiEdit`/`NotebookEdit` whose `file_path` or
     `notebook_path` is under chatq's `data/`. So is a Claude settings or
     MCP file: a path ending `\.claude\settings.json`,
     `\.claude\settings.local.json`, `\.claude.json` or `\.mcp.json`, any
     case, either slash. A path is made canonical first
     (`ConvertTo-ChatqPermitPath`): Git Bash's `/c/...` (and `/cygdrive/c`,
     `/mnt/c`) and `~` read as Windows paths, a `\\?\` or `\\.\` prefix
     and `\\localhost\c$` taken off, an NTFS stream (`::$DATA`) and each
     part's trailing dots and spaces dropped, made full against where
     claude runs - which expands 8.3 short names - and held against
     `data/`'s long and short forms. A path that cannot be made full counts
     as under `data/`.
   - `Bash`/`PowerShell` whose command names chatq's `data/` folder
     (`Test-ChatqPermitCommandDir`): long or 8.3 short, either slash, any
     case; Git Bash's `/c/...`; under the home folder as `~`, `$HOME`,
     `${HOME}`, `$env:USERPROFILE` or `%USERPROFILE%`; any path-like word of
     the command made canonical as an edit's path is (so a relative
     `data\` run from chatq's own folder); and any command run inside
     `data/` itself. This is best effort, and the docs say so.
   - `permit.maxPerRun` (10) already asked this run; 3 already pending; or
     `Missed`.
   - A rule deny says: "chatq never lets the phone approve <what>. Do not
     retry it; finish what you can without it and say what is left."
3. Otherwise: `rid = New-ChatqRandomName 10`, `until = now + waitMinutes`.
   It writes `<rid>.req.json`: `{ v:1, rid, run, tool, inputRaw,
   toolUseId, at, until, digest }`, through `Save-ChatqJson`, atomic.
4. It waits:
   - **`.sent.json` says `declined`**: deny with its reason ("Nobody can
     approve this right now: <reason>. Do not retry it; finish what you can
     without it and say what is left.").
   - **`.ans.json` present**: `Test-ChatqPermitAnswer`.
     - A verified `permit` answers `{"behavior":"allow"}`.
     - A verified `refuse` answers `{"behavior":"deny","message":"The user
       denied this from their phone. Do not retry it.<note>"}`. `<note>` is
       ` Their note: "..."`, and only from the verified message.
     - An unverified `refuse` gets the same answer with no note.
     - Anything else that fails verification is logged, and the bridge
       keeps waiting until the deadline.
   - **The deadline passes**: deny "Nobody approved this on the phone
     within N minutes, so it was denied. Do not retry it; finish what you
     can without it and say what is left." `Missed` is set, so the rest of
     this run is denied without asking. `<rid>.req.json` gets
     `timedOut: true`.

Watcher, in `$onTick` (Invoke-ChatqJob): `Update-ChatqPermitRequests $Job
$Run` runs **first on every tick**. Then the reply poll runs, every 5 s
(`-MinSeconds 5`) while any request is open, else every 30 s as now.

For each new `<rid>.req.json`:
1. Its `run` must be this run, and its `until` no later than now +
   waitMinutes. Else it is declined.
2. **Tool-call cross-check.** [Update-ChatqClaudeState](src/queue.ps1) now
   also keeps `St.ToolIds` (tool_use id -> name) from assistant lines. The
   request's `toolUseId` must be a tool_use the stream showed, under the
   same `tool` and not `mcp__chatqpermit__decide`, within 10 s. If not, it
   is declined "not a tool call of this run's". This stops the model from
   calling `decide` itself to push a made-up request. S35 item 4 checks the
   order: tool_use line first, then the prompt. If S35 shows another order,
   the check becomes a 10 s grace, or is dropped (a model-made request can
   only ever allow text back to the model).
3. Readiness again (Test-ChatqPermitReady), and at most 20 asks per hour
   across runs (`$script:ChatqPermitAsked`, in memory, as this process
   judges them). Else it is declined.
4. `Send-ChatqPermitAlert $Job $Req` builds the card (section 6). It sends
   `Send-ChatqAlert 'permission' <text> 2 -Loud -Quick -Job $Job -Card
   $card -Permit @{ run; rid; digest; until } -Tag "chatq-p-$rid"`.
   - On success: `<rid>.sent.json` = `{ v:1, rid, aid, until, at }`. The
     job file gets `permitWaiting = @{ tool; until }`, so `chatqlist` and
     the board say `#12 running · asks the phone: Bash, until 10:17`.
   - When nothing went out: `.sent.json` = `{ declined: 'could not reach
     the phone - <ChatqLastAlertError>' }`.
5. At the deadline, and at `Close-ChatqPermitRun` after the run: the
   registry entry's `permit.state` becomes `timeout`, or `gone` for a run
   that ended first. Then the folder `data/permit/<jobId>/` is deleted.
   [Repair-ChatqInterrupted](src/watcher.ps1) also deletes any such folder
   whose job is not running.

Watcher, on a verified reply (Receive-ChatqReply -> Invoke-ChatqReply). Two
new acts, `permit` and `refuse`. `Invoke-ChatqReply` gains `-Raw` (the
message as posted, from Receive-ChatqReply's `$Message`). The checks, in
order, each with the push it answers with:
1. `Entry.permit` is missing: "that alert asks for no permission - nothing
   to allow".
2. `permit.state` is not `open`: "already answered - allowed at 10:02" /
   "too late - at 10:17 nobody had answered, so Claude was told no" / "that
   run is over - nothing to allow".
3. The time is past `permit.until`: set `timeout`, "too late ...".
4. `permit` only: `Payload.h` differs from `permit.digest`. Say "the
   request changed after it was shown - nothing allowed", and log it.
5. The job is still `running`, with `runId = permit.run`, and
   `<rid>.req.json` is still there. Else set `gone`.
6. `Write-ChatqPermitAnswer` writes `<rid>.ans.json` = `{ v:1, rid, aid,
   act, raw: <message>, at }`, atomic. `permit.state` becomes `allowed` or
   `refused`, and `answeredAt` is set.
7. It pushes -Quick, about the job: "allowed - Bash for #12, the run goes
   on", or "denied - Bash for #12; Claude was told (with your note)".

Every answer and every decline goes to `data/logs/replies.log` as
`permit <rid> #12 Bash: allowed|refused|timeout|declined <why>`. The bridge
logs its side to `data/logs/permit.log`, rolled at 1 MB.

**Outcome.** [Get-ChatqClaudeOutcome](src/queue.ps1) gains `-Refused`, the
tool_use ids the phone refused (from `Close-ChatqPermitRun`). S35 item 1
checks that `permission_denials` carries a `tool_use_id`.
- **Every denial was the user's own Deny**: the kind is `done`. The `done`
  alert adds ` · you denied Bash(git push)`.
- **Otherwise** (a timeout, a rule, a decline, or no bridge): `needs-input`
  as today. The reason reads `denied Bash(git push) - no answer from the
  phone` when it timed out.

## 6. The card: what the phone sees, sealed end to end

The push goes through Join, whose GETs are logged, and ntfy alert topics
others may read. So its **text names only the tool and the chat**, never the
command:

- Title `chatq · permission` (event `permission`, priority 2, always sent
  like `reply`/`test`, since there is no other way to answer it).
- Text by tool:
  - `Bash`/`PowerShell`: `<chat> · #12 asks to run a command - tap to see it
    and answer by 10:17`.
  - `Edit`/`MultiEdit`: `asks to edit a file`.
  - `Write`: `asks to write a file`.
  - `WebFetch`: `asks to fetch a web page`.
  - Anything else: `asks to use <tool>`.
- The desktop toast shows the same text, with ` (answer on the phone)`.

What there is to judge goes in the link as a **card**, sealed for the phone
by the PC. The PC holds the phone's key D. Neither Join nor ntfy can read or
change the card.

```
kc   = HMAC-SHA256(D, "chatq-card:" + aid)       ; not "chatq-alert:" - the other direction gets its own keys
encC = HMAC-SHA256(kc, "enc"), macC = HMAC-SHA256(kc, "mac")
head = "chatq1c." + aid + "." + b64url(iv) + "." + b64url(AES-256-CBC(encC, iv, json))
card = head + "." + b64url(HMAC-SHA256(macC, head))
json = {"v":1,"t":"Bash","w":"<what>","d":"<Claude's description>","f":"<folder leaf>",
        "c":"<chat title, 60>","n":12,"h":"<digest>","u":<until, epoch ms>,
        "x":1}                                  ; x only when w is not the whole call
```

- `Protect-ChatqPermitCard -Master -Aid -Card` seals it, in phone.ps1 beside
  [Protect-ChatqReplyMessage](src/phone.ps1). `Unprotect-ChatqPermitCard`
  opens it, for the tests only.
- The plaintext is capped at 600 UTF-8 bytes (`w` shrinks first), so the
  card stays under ~950 characters and the Join URL under 1900.
  [Get-ChatqJoinUrl](src/alerts.ps1) never cuts `r=`: it trims the text,
  then the icon, then `c=`, as now.
- [Get-ChatqReplyLink](src/phone.ps1) adds `r=<card>`, and `e=permission`.

**The excerpt** (`Get-ChatqPermitExcerpt $Tool $Input $Cwd` -> `@{ What;
Detail; Hidden }`):

| tool | shown |
|---|---|
| Bash/PowerShell | the command, first 8 lines, 400 characters; `description` as the detail, 80 |
| Edit/MultiEdit | the path relative to the chat's folder, `replaces 3 lines with 5`, and the new text's first 200 characters |
| Write | the path, `new file` or `overwrites` - `writes a network path` for a UNC path or a mapped network drive, which is never looked at - the size (`54 lines, 2.1 KB`), the first 200 characters |
| NotebookEdit | the path and the cell |
| WebFetch | the URL; `prompt` as the detail, 100 |
| other | compact JSON of the input, 300 |

Every one of these goes through `Hide-ChatqSecrets` first. It is a guard for
the screen, not a security boundary, since the card is sealed anyway - and
it must never hide what the call does: a value holding `$`, a backtick,
`(`, `)`, `|`, `;`, `&`, `<` or `>` is code, and is shown whole, so
`SESSION_TOKEN="$(curl ... | sh)"` reaches the phone as it is. `Hidden` is
true when anything was hidden or the call's words were cut (8 lines, 400
characters, or the card's 600 bytes); the card then carries `x: 1`, and the
page says *Not all of this call is shown - parts are hidden (\*\*\*) or
cut. If you cannot tell what it does, Deny.* Matches of these become
`***`:
- The value after a key word:
  `(?i)\b\w*(pass(word|wd)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth(orization)?|bearer|cookie|session)\w*\b(\s*[:=]\s*|\s+)("[^"]*"|'[^']*'|\S+)`.
- A flag's value: `(?i)(--?(password|passwd|token|secret|api-?key)(=|\s+))\S+`.
- A URL's user info: `(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@`.
- Known token prefixes: `sk-`, `ghp_`, `gho_`, `github_pat_`, `xoxb-`,
  `xoxp-`, `AKIA`, `AIza`, `glpat-`, then `\S+`.
- A run of 32 or more `[A-Za-z0-9_-]` holding both a letter and a digit,
  except pure hex of 7-40 characters (commit ids).

**Binding.**
- The digest includes the rid, so two identical commands have two digests.
- The page opens the card with the phone's key, and puts `h` into the
  sealed `permit` it sends back.
- The watcher checks `h` against the registry. The bridge checks it against
  the digest it made from the request in its own memory.
- The watcher makes the digest again from the file's `rid`, `tool` and
  `inputRaw` before it sends a card, and declines a request whose `digest`
  differs ("the request changed on disk after it was asked"); the card and
  the registry get the digest it made, never the file's. A `.req.json`
  whose input was changed but not its digest is never shown, and one whose
  input and digest were both changed gets a card whose `h` the bridge's
  own copy refuses - it runs out as a deny.

## 7. Security: what an Allow can do, and the caps

- **One call, as shown.** An Allow approves exactly the call on the card.
  It returns no `updatedPermissions` and never changes the input.
- **The mode is untouched.** An Allow never changes the job's mode, and no
  later call in the run is approved by it. It raises no job's mode, so
  `reply.maxMode` is not in play: that cap governs the mode a phone-made or
  phone-requeued job runs in, and still does.
- **Why no mode cap on single calls.** A person reading one exact command
  and approving it is less than any mode above `default` grants. Capping
  permits by `reply.maxMode` would forbid the very thing asked for: a cap
  such as `acceptEdits` does not cover a `git push` - and with none set
  (keep, the default) the cap is not in the way anyway.
- **The cap on permits is what can be asked at all.** It is
  `permit.tools`, the never-list in section 5, `permit.on` off by default,
  and the rate limits.
- **What is new.** With permits on, the paired phone can make a command run
  on the PC. With only a prompt, it could ask Claude, and Claude could only
  ask. So:
  - **Opt-in.** The setup window's line says it plainly.
  - **The allow is believed only on the phone's MAC.** The bridge opens the
    message the phone posted with D, as it is now (a new pairing kills
    every old answer). It requires `act = permit`, the aid the watcher
    wrote in `.sent.json`, `h` = its own digest, `ts` within [asked - 1
    min, until + 1 min], a nonce and an aid it has not taken before in this
    run. Nothing that could be written into `data/` without D passes.
    Unauthenticated files can only deny.
  - **The shared page origin is a bigger risk now.** A script on another
    `phal40lax78.github.io` page can post with the phone's key (FUTURE_WORK,
    "The reply page on an origin of its own"). It would also need a
    permission alert's aid (Join's logs have it) while that alert is open,
    for at most `waitMinutes`. The README says to use `chatnotify
    -ReplyPage` on a site of your own before turning permits on, and the
    setup window's tooltip says the same.
- **Rate limits:**
  - 10 asks per run.
  - 3 pending at once.
  - One unanswered request ends asking for the rest of the run.
  - 20 asks per hour across runs.
  - One answer per aid: the first one wins, the rest are told "already
    answered".
  - The existing 20 uses, the nonce ledger, and the refusal pushes (at most
    one per alert every 10 minutes) apply as for every reply.
- **Replays.** A permit copied from one rid to another fails on the digest
  (the rid is in it), on the aid, and on the bridge's nonce set.
- **Push text** carries no command (section 6). What passes through whose
  servers: Join and an ntfy alert topic get the tool's name, the chat's
  title, and a ciphertext card. The reply topic gets a sealed permit/refuse,
  as today.

## 8. The page (docs/reply.html)

**Crypto block:**
- `openCard(key, aid, card)` checks the MAC in constant time, then decrypts,
  and returns the object or `null`. It uses the kept non-extractable HMAC
  key: `hmac(key, "chatq-card:" + aid)`, then `deriveKeys`, then
  `importKey('raw', enc, 'AES-CBC', false, ['decrypt'])`.
- `buildPayload(act, text, nonce, ts, h)` adds `h` last, and only when
  given, so `reply-vector.json` stays byte for byte.

**Logic block:**
- `ACTS` gains `permit` and `refuse`.
- `parseFragment` reads `r` into `f.card`, as a string only when it matches
  `^chatq1c\.[a-z2-7]{10}\.[A-Za-z0-9_.-]+$`.
- `buttonsFor('permission', ...)` returns:
  `{ text: true, send: { act: 'permit', label: 'Allow once', confirm: 'Tap
  again to allow' }, more: [{ act: 'refuse', label: 'Deny' }, status],
  placeholder: 'A note for Claude, with Deny (optional)', hint: 'the note
  goes only with Deny', about: '' }`.
- Allow uses the second-tap guard Skip and Stop have (at least 500 ms after
  the first). Deny is one tap.

**What the page shows for a `permission` alert:**
- Card opened, before `u`:
  - kicker `#12 Parser rewrite…`
  - head `Allow this once?`
  - a monospace box with `w`
  - `Bash · in parser`
  - `d` in grey (`Claude: Run the release build`)
  - `answer by 10:17 - 12 min left` (ticking once a minute)
  - fine print `Allow runs this one call. It changes nothing else the run
    may do.`
- Card opened, after `u`: head `Too late`, body `At 10:17 the run went on
  without it.` Only Status stays.
- Card missing or not opening: head `Nothing to approve here`, body `This
  request cannot be read on this phone - it was sealed for another key, or
  changed on the way.` Deny and Status stay; there is no Allow.
- Sent: `Sent - the PC reads it within about 5 s.`
- A draft note is kept per alert, as prompts are.

An old page, still cached, shows the default Send/Status for an unknown
event. A prompt sent from it is queued behind the run, which is harmless. A
new page's `permit` sent to an old watcher is logged `unknown act`.

## 9. Failure paths

- **No phone paired, replies off, permits off, no link channel, Codex, an
  old CLI, or the mode `plan`/`dontAsk`/`bypassPermissions`**: today's run,
  `--permission-prompts none`.
- **Pairing changed or replies switched off mid-run**: the next tick
  declines new requests. An allow already written fails the bridge's check
  under the new key and times out, which denies.
- **The bridge fails to start.** S35 item 3 says how the run ends. The
  watcher looks at the run's stderr and result for `chatqpermit` or
  `permission prompt tool`. It sets `job.permitOff = $true`, logs it, and
  requeues the job once as it would after a network drop (as `continue`
  when the prompt landed). The retry runs without the bridge.
  `chatnotify` says `permissions: the last run could not start the bridge
  - see data/logs/permit.log`.
- **The bridge dies mid-wait.** The call errors. Per S35 item 2 that is a
  deny (the result is needs-input as today) or a failed run (handled as
  above).
- **The watcher dies mid-run.** The bridge denies at its deadline.
  [Repair-ChatqInterrupted](src/watcher.ps1) cleans the folder.
- **Stop from the phone or `chatqrun -Stop` while waiting.** `Stop-ChatqTree`
  takes the bridge with claude. `Close-ChatqPermitRun` marks the open entries
  `gone`, and a late Allow is told "that run is over".
- **The PC sleeps while waiting.** The deadline passes on wake; the call is
  denied and `Missed` is set. Nothing is allowed late.
- **The user is at the PC.** The phone is asked all the same (`-Loud`),
  since a headless run has no window to ask in. The toast says so. Answering
  from the PC itself is out of scope (section 11).

## 10. Settings, commands, window, docs

`data/config.json`:

| key | default | |
|---|---|---|
| `permit.on` | `false` | ask the phone when a queued run needs a permission |
| `permit.waitMinutes` | `10` | 1-25; then the call is denied. `MCP_TOOL_TIMEOUT` is set 3 min above it |
| `permit.tools` | `Bash, PowerShell, Edit, Write, MultiEdit, NotebookEdit, WebFetch` | what the phone may approve; `mcp__*` allowed as a pattern |
| `permit.maxPerRun` | `10` | asks per run |

- **[Set-ChatqNotifyConfig](src/phone.ps1)** takes `Permit` (`on`/`off`),
  `PermitWait` (1-25, else the error `-PermitWait takes 1 to 25 minutes`)
  and `PermitTools` (`default` or names). Each is checked before anything is
  saved, like every other key there.
  - `on` says: `permissions from the phone on - a queued run that needs one
    asks the phone and waits 10 min`.
  - With no phone paired it adds (Yellow): `no phone is paired, so runs deny
    as before - chatnotify -Pair`.
- **`chatnotify -Permit on|off`, `-PermitWait <min>`.** The status print
  gains a line from `Get-ChatqPermitStatusText`:
  - `permissions  off - a run that needs one stops as needs input`
  - `permissions  on - Bash, Edit, Write, ... asked on the phone, 10 min to
    answer`
  - `permissions  on, but no phone is paired - runs deny as before`
- **The setup window ([Show-ChatqPhoneSetup](src/phone-setup.ps1))**, in
  REPLIES under the pairing row:
  - A `CheckBox PermitBox` "Approve tool calls from the phone". It is
    enabled only while `ReplyBox` is checked, and it follows the same
    dirty/snapshot path as `LiveBox`
    ([Get-ChatqPhoneSetupSnapshot](src/phone-setup.ps1),
    [Get-ChatqPhoneSetupChanges](src/phone-setup.ps1)).
  - Hint: "A queued run that needs a permission asks the phone - Allow once
    or Deny - and waits 10 min. Off: it stops as needs input."
  - Tooltip: "This lets the phone make a command run on this PC. Serve the
    reply page from a site of your own first (chatnotify -ReplyPage)."
- **Docs:**
  - **README** "## Alerts": a new `### Approve a tool call from the phone`
    after "Reply from the phone". Also a new event row, `chatq · permission
    | 2 | chat, which tool - the rest sealed in the link`, the four keys,
    the two switches, and the Join row of "What passes through whose
    servers" (a sealed card).
  - **CHANGELOG** entry for the release that ships it.
  - **TESTING**: a `permit.ps1` paragraph, S35 and S36.
  - **FUTURE_WORK**: the entry is rewritten to what is left - VS Code chats
    through a `PermissionRequest` hook, answering at the PC (the console),
    and the page on an origin of its own, which is now more pressing.

## 11. Out of scope

- **Chats run straight in VS Code or a terminal.** They would need a
  `PermissionRequest` hook in the user's `~/.claude/settings.json`, which
  chatq has never written. That stays in FUTURE_WORK.
- **Codex: deferred until a spike, not out of scope by design.** As chatq
  runs it today, `codex exec` refuses by policy `never` and never asks
  mid-run. Two ways in exist in codex-cli 0.159.2, neither tried, since
  each needs a model turn:
  - **A hook under `exec`.** A run given `-c approval_policy=on-request`
    and a run-scoped `PermissionRequest` hook, built like
    [Start-ChatqAskHook](src/ask.ps1): the hook checks the phone's sealed
    answer itself, so no new trust is needed in `data/`.
  - **The app server's own requests.** On a runner that drives turns
    through `codex app-server` rather than `codex exec`:
    `item/commandExecution/requestApproval` and
    `item/fileChange/requestApproval` arrive on the stdout the watcher
    already reads and are answered on its stdin, `accept` or `decline`
    only, after the phone's MAC is checked. A permissions request and a
    `grantRoot` are declined unasked, as "always allow" is (section 1).

  The spike: does the hook fire under `exec`, and does its allow hold
  without a hook-trust bypass? If yes, the hook; if no, the app server,
  once that runner exists. Either way this spec gains a Codex section
  first, [Test-ChatqPermitReady](src/permit.ps1) lets Codex through except
  under `danger-full-access`, and a Codex ask left unanswered makes the job
  `needs-input`. FUTURE_WORK.md "Approve permission prompts: what 0.9.0
  left out" carries it.
- **Answering at the PC** (console, overlay, toast buttons). It would need a
  PC-side allow the bridge can trust - for example a per-run secret held by
  the watcher and handed to the bridge outside `data/` - which is its own
  design.
- **"Always allow"** (`updatedPermissions`), editing the command from the
  phone, answering `AskUserQuestion`, and approving a plan (`ExitPlanMode`).
- **Runs chatq did not start** (`claude -p` by hand).
- **Reading Claude's whole reply on the phone, and inline Tasker buttons**:
  separate ideas.
- **macOS and Linux.** Written for them (pwsh as the bridge), never run.

## 12. Tests

**`tests/sections/permit.ps1`**, a new section after `phone.ps1` in
`run-tests.ps1`, so it runs on both CI legs (5.1 and 7). The seams are
`ChatqJoinSeam`, `ChatqReplyPollSeam` and `$script:ChatqPermitWaitSeconds`,
a test-only override of the deadline, passed into the launch's encoded
command.

1. **Framing, in-process** (`Invoke-ChatqMcpRequest`):
   - `initialize` echoes a known protocol version and answers `2025-06-18`
     for an unknown one.
   - `tools/list` has exactly `decide` and its schema.
   - `ping` gives `{}`; an unknown method gives `-32601`; a notification
     gives no reply.
   - `Get-ChatqJsonRaw` handles braces and quotes inside strings, `\"`,
     Hangul, and nested objects.
2. **The bridge as a real child.** The test plays claude: it starts
   `Get-ChatqPermitLaunch`'s exe and args with redirected stdio, and hands
   over.
   - The first stdout byte is `{`. `initialize`, `initialized` and
     `tools/list` all answer, within the 30 s `MCP_TIMEOUT` (the time is
     logged).
   - `tools/call` for Bash `git push` writes `<rid>.req.json`, with the
     Hangul in the command intact.
   - The test writes `.sent.json`, then an `.ans.json` holding a sealed
     `permit` with the right `h`, made by `Protect-ChatqReplyMessage
     -Payload`. The answer is `{"behavior":"allow"}` with no `updatedInput`,
     within 2 s.
   - These each get a deny: a `refuse` with a note (the message carries the
     note); a permit with the wrong `h`; an unsealed `{"act":"permit"}`; a
     permit sealed under another key; the first rid's answer copied to a
     second rid of the same command; `.sent.json` saying declined.
   - The deadline runs out: a deny saying nobody approved it. The next call
     is denied at once.
   - Two calls pending, answered in reverse order: each answer goes to its
     own id. `notifications/cancelled` marks the request withdrawn.
     `ping` is answered while a call waits.
   - stdin closed: exit 0 within 2 s.
   - The same loop is run once more under pwsh 7 when present
     (`Start-ChatqPermitBridge` in a pwsh child), for off-Windows.
3. **The rules** (`Get-ChatqPermitRule`), table-driven: AskUserQuestion,
   ExitPlanMode, a tool not listed, `mcp__x__y` listed and not, Write to
   `data/config.json`, Edit of `.claude\settings.local.json` in either
   slash, Bash naming the data folder, the 11th ask, the 4th pending, after
   a miss.
4. **Excerpt and redaction** (`Get-ChatqPermitExcerpt`, `Hide-ChatqSecrets`):
   - `TOKEN=abc`, `--password hunter2`, `https://u:p@host`, `ghp_...`,
     `Authorization: Bearer x`, and a 40-hex commit id (kept).
   - 8 lines and 400 characters at most. An Edit's line counts. Hangul is
     never cut in half.
5. **The card.**
   - `tests/fixtures/card-vector.json`, made by
     `tests/fixtures/make-card-vector.js` (Node crypto, fixed D `0x00..0x1f`,
     aid `abcdefghij`, fixed IV): `Protect-ChatqPermitCard` matches it byte
     for byte, and a changed byte fails `Unprotect-ChatqPermitCard`.
   - The Join URL with a 600-byte card and Hangul text stays within 1900
     characters, with `r=` whole.
   - The push text never holds the command.
6. **End to end through `fake-agent.ps1`.** New variables:
   - `FAKE_PERMIT`: a JSON list of calls `{ tool_name, input, id }`. With
     `--permission-prompt-tool` and `--mcp-config` in argv, the fake reads
     the config and starts the server with its `command`, `args` and `env`.
     It hands over, emits an assistant `tool_use` line per call, sends each
     `tools/call`, and records each answer to `FAKE_RECORD/permit.jsonl`.
     Then it emits a `user` tool_result for an allow, or
     `system/permission_denied` plus a `permission_denials` entry (with
     `tool_use_id`) for a deny.
   - `FAKE_PERMIT_SELF`: the model calls `mcp__chatqpermit__decide` itself,
     with no tool_use of its own.

   With permits on and a paired test phone:
   - argv has `--permission-prompts host`, `--mcp-config`,
     `--permission-prompt-tool mcp__chatqpermit__decide` and `--settings`.
     It has no `none`. `env.txt` shows `MCP_TOOL_TIMEOUT`.
   - The permission push (ChatqJoinSeam) has `e=permission`, `r=` and a
     `chatq-p-<rid>` notification id. The seam's poll then returns a sealed
     `permit`: the job ends `done`, and `replies.log` has `allowed`.
   - `refuse` with a note: `done`, and its alert says `you denied Bash(...)`.
   - No answer: `needs-input`, `... - no answer from the phone`.
   - A late permit: the push says "too late". A second answer: "already
     answered".
   - `FAKE_PERMIT_SELF`: declined, with no push.
   - A phone `stop` while waiting: the bridge process is gone, the entry is
     `gone`, and `data/permit/<jobId>` is deleted.
   - With permits off, not paired, Codex, mode `plan`, or `bypassPermissions`:
     argv is exactly today's (`--permission-prompts none`, no
     `--mcp-config`).
   - A bridge that fails to start (a launch pointing at a missing exe): the
     job is requeued once with `permitOff`, and the retry's argv is today's.
7. **Registry.** `permit` survives
   [Get-ChatqReplyState](src/phone.ps1) / [Save-ChatqReplyState](src/phone.ps1)
   on both PowerShells. A refuse note is capped at 500 characters with its
   control characters stripped. The hourly cap is 20.
8. **Outcome.** [Get-ChatqClaudeOutcome](src/queue.ps1) with `-Refused`:
   all refused gives `done`; one refused plus one timed out gives
   `needs-input`.

**`tests/reply-page-check.js`:**
- The card vector opens under Node's WebCrypto with the kept CryptoKey, and
  a changed byte gives `null`.
- `buildPayload` without `h` still matches `reply-vector.json`; with `h`,
  the sealed permit opens in PowerShell with `h` intact (fixture-driven).
- `buttonsFor('permission')` gives Allow once (confirm), Deny, and Status.
- There is no Allow without a card, or after `u`.
- `ACTS` holds `permit` and `refuse`, and each is an act the watcher knows.
- The fake-DOM run checks: the double-tap guard on Allow, a note kept per
  alert, and the too-late card.

**S35, spike against the real CLI** (costs a little usage; run once, then
record in TESTING.md). Use `claude.exe` 2.1.283 from the VS Code extension,
a throwaway folder, and a stub server (the bridge, with its log turned up):
1. In `default`, a prompt that runs `git status && echo hi > x.txt`:
   - The tool gets `tool_name`/`input`/`tool_use_id`.
   - `{"behavior":"allow"}` with no `updatedInput` runs the command as
     asked.
   - A deny's message reaches Claude.
   - `permission_denials` lists the deny, with `tool_use_id`, and
     `system/permission_denied` streams.
2. A permission call that errors, and one past `MCP_TOOL_TIMEOUT`: a deny,
   or a failed run? The exact text either way.
3. The bridge cannot start (a wrong `command`): does the run fail? With
   what, and on which stream?
4. The environment the stdio server gets (does `SystemRoot` arrive?).
   - Does the model see `mcp__chatqpermit__decide` among its tools?
   - Does a settings `deny` on it hide it from the model while it still
     serves prompts?
   - Is the assistant `tool_use` line on stdout before the prompt call?
5. A settings `deny` of `Edit(//c/<data path>/**)` stops an `acceptEdits`
   edit there. Record the path form that works.
6. With `host` and `AskUserQuestion` denied in settings: it never reaches
   the tool. An MCP server's elicitation under `host`: cancelled?
7. `acceptEdits` plus `git push` reaches the tool. In `auto`, a call the
   classifier sends back to a prompt reaches it. In `dontAsk`, none does.
8. Two tool calls in one message: two concurrent `tools/call`?
9. The bridge's start under 5.1, dot-sourcing the whole script: time to
   `initialize`.

**S35, what was seen** (2026-09-27, claude.exe 2.1.283 from the VS Code
extension, `--model haiku`, a one-line prompt asking to run `echo hi` with
Bash, in a throwaway folder outside every repo; five runs, the whole
budget). The run's own `settings.json` added `"ask": ["Bash(echo hi)"]`
so a harmless command would prompt at all.
1. **Item 1, answered.** Run 1 (`default`): the bridge got `tool_name`,
   `input` and `tool_use_id`; `{"behavior":"allow"}` with no `updatedInput`
   ran the command as asked (`tool_result` `hi`). Run 2: a sealed refuse
   with a note came back to Claude word for word as an `is_error`
   `tool_result`, and Claude quoted the note. `result.permission_denials`
   listed the deny **with `tool_use_id`**, so `-Refused` matches by id as
   planned. **No `system/permission_denied` line** streamed for a deny from
   the prompt tool - only the result's list, which is what the outcome
   reads anyway.
2. **Item 2, answered for a timeout.** Run 4, `MCP_TOOL_TIMEOUT=10000`: the
   call ended as a `tool_result` error `MCP server "chatqpermit" tool
   "decide" timed out after 10s`, **not a denial** - it is not in
   `permission_denials`, and the model simply asked again (a second
   request, timed out the same way), then gave up in words. Claude sent
   `notifications/cancelled` for each, and the bridge marked the request
   `withdrawn`. So `MCP_TOOL_TIMEOUT` stays 3 minutes above the bridge's own
   deadline, and the bridge always answers first, with a real deny.
3. **Item 3, answered.** Run 3, a `command` that does not exist: the run
   starts all the same, `init` lists `chatqpermit` as `"status":"failed"`,
   and the first prompt ends it - exit 1, no `result` line, and on stderr
   (and in the tool_result) `Error: MCP tool mcp__chatqpermit__decide
   (passed via --permission-prompt-tool) not found. Available MCP tools:
   ...`. [Test-ChatqPermitStartFailed](../src/permit.ps1) reads either.
4. **Item 4, answered in part.** `SystemRoot` arrived (the bridge logs it);
   the bridge was up 0.2-1.3 s after claude started it (item 9, 5.1
   dot-sourcing the whole script). **The model is never shown
   `mcp__chatqpermit__decide`**: `init`'s tool list leaves it out while the
   server is `connected`, so the self-call check is a belt over braces. The
   assistant `tool_use` line was on stdout 3-8 s before the bridge got the
   call, every time, so the cross-check holds as written.
   `AskUserQuestion` was not in the tool list either (the settings deny).
5. **Run 5**, the whole path through the built watcher, in `acceptEdits`
   with a Join seam: the `started` push, then the `permission` push
   (`e=permission`, `r=chatq1c...`, `notificationId=chatq-p-<rid>`, no
   command in its text), a sealed permit fed through the poll seam, the
   `allowed - Bash for #1, the run goes on` push, `hi`. The account's
   session limit then ended the run (`limited`), which is chatq's own path.

**Not run, for want of budget** (items 5-8): the `//c/...` path form of the
data deny rules, elicitation under `host`, `auto`'s classifier sending a
call back to a prompt, and two tool calls in one message. The code holds
without them: the rules are defence in depth behind section 6, the bridge
answers several pending calls in any order (tested with a real child), and
`auto` and elicitation fall to the same bridge or to a deny. They stay in
TESTING.md's S35 as open.

**S36, by hand with the phone** (after S34):
- Permits on.
- Queue a prompt that needs `git push`, and leave the PC.
- The `chatq · permission` push names no command. The page shows the
  command, redacted where it should be.
- **Allow once** (two taps): the run goes on within about 10 s, and an
  `allowed` push follows.
- Again with **Deny** and a note: Claude's reply quotes the note, and the
  job is `done`.
- Again without answering: after 10 min, `needs input` saying no answer. A
  tap on Allow then says too late.
- Stop from a `started` alert while a request waits.
- At the PC: the toast and the phone both show it.
