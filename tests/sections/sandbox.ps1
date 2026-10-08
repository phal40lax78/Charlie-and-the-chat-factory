# tests/sections/sandbox.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

# --- sandbox -----------------------------------------------------------------
$claudeHome = Join-Path $sb 'claude'
$codexHome = Join-Path $sb 'codex'
$work = Join-Path $sb 'work'
$projA = Join-Path $work 'projA'
$projM = Join-Path $work 'projA-Mobile'
foreach ($d in $claudeHome, $codexHome, $projA, $projM, (Join-Path $sb 'tool')) { $null = New-Item -ItemType Directory -Path $d -Force }
Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')
Copy-Item -LiteralPath (Join-Path $root 'src') -Destination (Join-Path $sb 'tool') -Recurse

$env:CLAUDE_CONFIG_DIR = $claudeHome
$env:CODEX_HOME = $codexHome
# Copilot's store too: an index sync without -Provider would otherwise read
# this machine's real Copilot chats into the sandbox
$codeUser = Join-Path $sb 'code-user'
$env:CHAT_CODE_USER = $codeUser
$env:CHATQ_CLAUDE = Join-Path $here 'fake-claude.cmd'
$env:CHATQ_CODEX = Join-Path $here 'fake-claude.cmd'
$env:CHATQ_WATCHER = '1'      # no auto-start from the load below
# all 25 parts, the overlay's own among them, which a shell's load leaves
# out - for this run and every child it starts
$env:CHATQ_ALLPARTS = '1'
# gh's login is this machine's, whatever the sandbox: no run - child
# processes included - ever reaches it
$env:CHATQ_GH = Join-Path $here 'no-such-gh.exe'
# nor does any run - its STA children included, which inherit this - ever
# bring a real window to the front: the overlay's calls for it refuse, and
# their type is never compiled (Invoke-ChatOverlayRaise)
$env:CHATQ_NOFRONT = '1'
foreach ($n in 'FAKE_RECORD', 'FAKE_SCENARIO', 'FAKE_LAND', 'FAKE_STDERR', 'FAKE_SLEEP', 'FAKE_AGENTS', 'FAKE_AGENTS_SEEN', 'FAKE_VERSION', 'FAKE_APPSERVER', 'FAKE_APPSERVER_NOMETHOD', 'CHATQ_CODE') { Remove-Item "env:$n" -EA SilentlyContinue }

function Get-Slug([string]$Path) { $Path.TrimEnd('\', '/') -replace '[^A-Za-z0-9]', '-' }

function New-FakeChat {
    # one Claude transcript: a prompt and a reply per entry in $Prompts, the
    # title record, and optionally the synthetic limit record at the end -
    # its uuid -LimitUuid, which names that cut-off (Get-ChatqCutKey)
    param([string]$Proj, [string]$Id, [string]$Title, [double]$HoursAgo, [string[]]$Prompts,
        [string]$Mode = 'auto', [switch]$CutOff, [int64]$ResetsAt, [int]$PadBytes = 0, [switch]$ModeFarBack,
        [switch]$Overloaded, [string]$LimitType = 'five_hour', [string]$HomeDir = $claudeHome, [string]$LimitUuid = [guid]::NewGuid().ToString())
    $dir = Join-Path (Join-Path $HomeDir 'projects') (Get-Slug $Proj)
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path $dir "$Id.jsonl"
    $t = (Get-Date).ToUniversalTime().AddHours(-$HoursAgo)
    $sbuf = [System.Text.StringBuilder]::new()
    $k = 0
    foreach ($p in $Prompts) {
        $k++
        $ts = $t.AddMinutes(-10 + $k).ToString('o')
        $u = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = $p }
            uuid = [guid]::NewGuid().ToString(); timestamp = $ts; permissionMode = $Mode; cwd = $Proj; sessionId = $Id }
        [void]$sbuf.AppendLine(($u | ConvertTo-Json -Compress -Depth 6))
        $a = [ordered]@{ parentUuid = $null; isSidechain = $false; message = [ordered]@{ model = 'claude-opus-5'; id = 'msg_1'; type = 'message'; role = 'assistant'
                content = @([ordered]@{ type = 'text'; text = "reply $k" }); stop_reason = 'end_turn' }
            type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = $ts; cwd = $Proj; sessionId = $Id }
        [void]$sbuf.AppendLine(($a | ConvertTo-Json -Compress -Depth 8))
    }
    if ($PadBytes) {
        # a long tool result after the last mode record: pushes it far back
        $pad = [ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; content = ('y' * $PadBytes) }) }
            uuid = [guid]::NewGuid().ToString(); timestamp = $t.ToString('o'); sessionId = $Id }
        [void]$sbuf.AppendLine(($pad | ConvertTo-Json -Compress -Depth 8))
    }
    [void]$sbuf.AppendLine(([ordered]@{ type = 'ai-title'; aiTitle = $Title; sessionId = $Id } | ConvertTo-Json -Compress))
    if ($CutOff) {
        $s = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'assistant'; uuid = $LimitUuid; timestamp = $t.ToString('o')
            message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = "You've hit your session limit" }) }
            quotaLimits = [ordered]@{ status = 'rejected'; resetsAt = $ResetsAt; rateLimitType = $LimitType }
            error = 'rate_limit'; isApiErrorMessage = $true; cwd = $Proj; sessionId = $Id }
        [void]$sbuf.AppendLine(($s | ConvertTo-Json -Compress -Depth 8))
    }
    if ($Overloaded) {
        # the 529 turn exactly as Claude Code writes it
        $s = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = $t.ToString('o')
            message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'API Error: 529 Overloaded. This is a server-side issue, usually temporary - try again in a moment. If it persists, check https://status.claude.com.' }) }
            error = 'server_error'; isApiErrorMessage = $true; apiErrorStatus = 529; cwd = $Proj; sessionId = $Id }
        [void]$sbuf.AppendLine(($s | ConvertTo-Json -Compress -Depth 8))
    }
    [System.IO.File]::WriteAllText($path, $sbuf.ToString(), $utf8)
    (Get-Item -LiteralPath $path).LastWriteTime = $t.ToLocalTime()
    return $path
}

$now = [DateTimeOffset]::UtcNow
$future = $now.AddHours(2).ToUnixTimeSeconds()
$past = $now.AddHours(-3).ToUnixTimeSeconds()
$idFw = '11111111-1111-4111-8111-111111111111'
$idCard = '22222222-2222-4222-8222-222222222222'
$idTong = '33333333-3333-4333-8333-333333333333'
$idOld = '44444444-4444-4444-8444-444444444444'
$idMob = '55555555-5555-4555-8555-555555555555'
$idA = '66666666-6666-4666-8666-666666666666'
$idB = '77777777-7777-4777-8777-777777777777'
$idLong = '88888888-8888-4888-8888-888888888888'
$idFar = '99999999-9999-4999-8999-999999999999'
$tSel = U '\uC120\uD0DD'                 # "selection"
$tTong = U '\uD1B5\uD569'                # "integration"
$titleCard = "$tSel card UI redesign"
$titleTong = "card UI $tTong"
$longTitle = 'Investigate why the log viewer drops lines when the input pipe is saturated by a chatty build'

$pFw = New-FakeChat $projA $idFw 'Parser rewrite and plugin unification' 1 @('unify the parser entry points', 'now the plugins') -CutOff -ResetsAt $future
$pCard = New-FakeChat $projA $idCard $titleCard 2 @('redesign the selection card layout', 'level the card heights') -Mode 'acceptEdits'
$null = New-FakeChat $projA $idTong $titleTong 3 @("$tTong $tTong card merge", "$tTong UI merge the two cards") -CutOff -ResetsAt $past
$null = New-FakeChat $projA $idOld 'Old chat about gitignore rules' 72 @('write gitignore rules')
$null = New-FakeChat $projM $idMob 'Mobile only chat' 1.5 @('mobile layout')
$null = New-FakeChat $projA $idLong $longTitle 30 @('lines drop')
$pFar = New-FakeChat $projA $idFar 'Mode far back' 40 @('long one') -Mode 'plan' -PadBytes 1300000
$idOver = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$pOver = New-FakeChat $projA $idOver 'Overloaded mid task' 0.5 @('refactor the parser') -Overloaded

# a second account whose only limit is one model's weekly one
$claude2 = Join-Path $sb 'claude2'
$null = New-FakeChat $projA 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' 'Opus only' 1 @('x') -CutOff -ResetsAt $now.AddDays(4).ToUnixTimeSeconds() -LimitType 'seven_day_opus' -HomeDir $claude2
$statusFile = Join-Path $sb 'status.json'
function Set-FakeStatus([string]$State) {
    $j = @{ components = @(@{ name = 'claude.ai'; status = 'operational' }, @{ name = 'Claude Code'; status = $State }) } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($statusFile, $j, $utf8)
}

# two chats for the 5 h edge, in a folder of their own
$projE = Join-Path $work 'projE'
$null = New-Item -ItemType Directory -Path $projE -Force
$null = New-FakeChat $projE $idA 'Edge alpha tool' 1 @('alpha')
$null = New-FakeChat $projE $idB 'Edge beta tool' (1 + 4.98) @('beta')

# codex: one rollout with its thread name, sandbox and a full rate window
$cxId = '01900000-0000-7000-8000-000000000001'
$cxDir = Join-Path $codexHome 'sessions\2026\09\20'
$null = New-Item -ItemType Directory -Path $cxDir -Force
$cxPath = Join-Path $cxDir "rollout-2026-09-20T10-00-00-$cxId.jsonl"
$cxLines = @(
    ([ordered]@{ timestamp = $now.AddHours(-1).ToString('o'); type = 'session_meta'; payload = [ordered]@{ session_id = $cxId; id = $cxId; cwd = $projA; originator = 'codex_vscode' } } | ConvertTo-Json -Compress -Depth 6)
    ([ordered]@{ timestamp = $now.AddHours(-1).ToString('o'); type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'user'; content = @([ordered]@{ type = 'input_text'; text = 'add the codex gitignore' }) } } | ConvertTo-Json -Compress -Depth 6)
    ([ordered]@{ timestamp = $now.AddHours(-1).ToString('o'); type = 'turn_context'; payload = [ordered]@{ cwd = $projA; approval_policy = 'on-request'; sandbox_policy = [ordered]@{ type = 'workspace-write'; network_access = $true }; model = 'gpt-5.6' } } | ConvertTo-Json -Compress -Depth 6)
    ([ordered]@{ timestamp = $now.AddHours(-1).ToString('o'); type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; rate_limits = [ordered]@{ limit_id = 'codex'; primary = [ordered]@{ used_percent = 100.0; window_minutes = 300; resets_at = $future }; secondary = [ordered]@{ used_percent = 12.0; window_minutes = 10080; resets_at = $now.AddDays(3).ToUnixTimeSeconds() } } } } | ConvertTo-Json -Compress -Depth 6)
)
[System.IO.File]::WriteAllText($cxPath, ($cxLines -join "`n") + "`n", $utf8)
# a second thread, named in Hangul: the index is BOM-less UTF-8, which 5.1
# reads in the ANSI code page unless told otherwise
$cx2Id = '01900000-0000-7000-8000-000000000002'
$tHan = -join [char[]](0xD55C, 0xAE00, 0x20, 0xC2A4, 0xB808, 0xB4DC)   # "Hangul thread"
$cx2Lines = @(
    ([ordered]@{ timestamp = $now.AddHours(-2).ToString('o'); type = 'session_meta'; payload = [ordered]@{ session_id = $cx2Id; id = $cx2Id; cwd = $projA; originator = 'codex_vscode' } } | ConvertTo-Json -Compress -Depth 6)
    ([ordered]@{ timestamp = $now.AddHours(-2).ToString('o'); type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'user'; content = @([ordered]@{ type = 'input_text'; text = 'name me' }) } } | ConvertTo-Json -Compress -Depth 6)
)
[System.IO.File]::WriteAllText((Join-Path $cxDir "rollout-2026-09-20T09-00-00-$cx2Id.jsonl"), ($cx2Lines -join "`n") + "`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'),
    ((([ordered]@{ id = $cxId; thread_name = 'Codex gitignore thread'; updated_at = $now.ToString('o') } | ConvertTo-Json -Compress),
            ([ordered]@{ id = $cx2Id; thread_name = $tHan; updated_at = $now.ToString('o') } | ConvertTo-Json -Compress)) -join "`n") + "`n", $utf8)

# Copilot: one chat in this project's folder, so a title can name it
$wsDir = Join-Path (Join-Path $codeUser 'workspaceStorage') 'ws1'
$null = New-Item -ItemType Directory -Path (Join-Path $wsDir 'chatSessions') -Force
[System.IO.File]::WriteAllText((Join-Path $wsDir 'workspace.json'), (@{ folder = ([Uri]$projA).AbsoluteUri } | ConvertTo-Json -Compress), $utf8)
$cpId = '15151515-1515-4151-8151-151515151515'
$cpJson = [ordered]@{ version = 3; requests = @([ordered]@{ message = [ordered]@{ text = 'explain the copilot tests' } })
    customTitle = 'Copilot chat about tests'; lastMessageDate = $now.AddHours(-1).ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::WriteAllText((Join-Path (Join-Path $wsDir 'chatSessions') "$cpId.json"), $cpJson, $utf8)

# find-and-delete: chats that get deleted, one with every leftover a Claude
# chat keeps beside its transcript
$idDoom1 = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$idDoom2 = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$pDoom1 = New-FakeChat $projA $idDoom1 'Doomed chat one' 2 @('delete me later', 'unique prompt phrase zebra')
$pDoom2 = New-FakeChat $projA $idDoom2 'Doomed chat two' 2 @('delete me too')
$side = Join-Path (Split-Path $pDoom1 -Parent) $idDoom1
$null = New-Item -ItemType Directory -Path (Join-Path $side 'subagents') -Force
[System.IO.File]::WriteAllText((Join-Path $side 'subagents\agent-1.jsonl'), '{}', $utf8)
foreach ($d in 'file-history', 'session-env') {
    $dd = Join-Path (Join-Path $claudeHome $d) $idDoom1
    $null = New-Item -ItemType Directory -Path $dd -Force
    [System.IO.File]::WriteAllText((Join-Path $dd 'x'), 'x', $utf8)
}
# the rest of claude-chats-delete's inventory, each named or found by the id
$left = @{
    Debug = Join-Path $claudeHome "debug\$idDoom1.txt"
    Tasks = Join-Path $claudeHome "tasks\$idDoom1\t.json"
    Sec = Join-Path $claudeHome "security\security_warnings_state_$idDoom1.json"
    SecLock = Join-Path $claudeHome "security\security_warnings_state_$idDoom1.lock"
    Tele = Join-Path $claudeHome "telemetry\evt-$idDoom1-1.json"
    Todo = Join-Path $claudeHome "todos\$idDoom1-agent-1.json"
    Job = Join-Path $claudeHome 'jobs\cccccccc\state.json'
    Plan = Join-Path $claudeHome 'plans\doom-slug.md'
    PlanAgent = Join-Path $claudeHome 'plans\doom-slug-agent-a1.md'
    Shared = Join-Path $claudeHome 'plans\shared-slug.md'
}
foreach ($p in $left.Values) {
    $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
    [System.IO.File]::WriteAllText($p, 'x', $utf8)
}
[System.IO.File]::WriteAllText($left.Job, ('{"sessionId":"' + $idDoom1 + '"}'), $utf8)
function Add-Slug([string]$Path, [string]$Slug) {
    [System.IO.File]::AppendAllText($Path, ('{"type":"system","subtype":"x","slug":"' + $Slug + '","sessionId":"s"}' + "`n"), $utf8)
}
Add-Slug $pDoom1 'doom-slug'
Add-Slug $pDoom2 'shared-slug'
# more prompts than the index previews, one of them only -Deep can see - and
# it shares doomed chat two's plan slug, so that plan must stay
$idDeep = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
$pDeep = New-FakeChat $projA $idDeep 'Many prompts chat' 3 @('p1', 'p2', 'p3', 'p4', 'needle-deep-xyz', 'p6', 'p7', 'p8')
Add-Slug $pDeep 'shared-slug'
# one to hold open while deleting, one to archive and bring back
$idLock = '16161616-1616-4161-8161-161616161616'
$pLock = New-FakeChat $projA $idLock 'Locked open chat' 8 @('hold me')
$lockHist = Join-Path $claudeHome "file-history\$idLock"
$null = New-Item -ItemType Directory -Path $lockHist -Force
[System.IO.File]::WriteAllText((Join-Path $lockHist 'x'), 'x', $utf8)
$idArch = '17171717-1717-4171-8171-171717171717'
$pArch = New-FakeChat $projA $idArch 'Archive me please' 9 @('archive this one')
$archHist = Join-Path $claudeHome "file-history\$idArch"
$null = New-Item -ItemType Directory -Path $archHist -Force
[System.IO.File]::WriteAllText((Join-Path $archHist 'x'), 'x', $utf8)
$idQuote = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
$null = New-FakeChat $projA $idQuote 'Say "hi" to it' 4 @('greet')
$idDead = '12121212-1212-4121-8121-121212121212'
$null = New-FakeChat $projA $idDead 'Deadline notes' 5 @('dates')
$idSmart = '13131313-1313-4131-8131-131313131313'
$tSmart = "Don$([char]0x2019)t break it"
$null = New-FakeChat $projA $idSmart $tSmart 6 @('careful')
# a subagent transcript: flagged on its first line, hidden from search and Tab
$idHid = '14141414-1414-4141-8141-141414141414'
$hidLines = @(
    ([ordered]@{ type = 'user'; isSidechain = $true; message = [ordered]@{ role = 'user'; content = 'sub task' }; uuid = [guid]::NewGuid().ToString()
            timestamp = $now.AddHours(-1).ToString('o'); cwd = $projA; sessionId = $idHid } | ConvertTo-Json -Compress -Depth 5)
    ([ordered]@{ type = 'ai-title'; aiTitle = 'Hidden subagent work'; sessionId = $idHid } | ConvertTo-Json -Compress)
)
[System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $projA)) "$idHid.jsonl"), ($hidLines -join "`n") + "`n", $utf8)

# --- load --------------------------------------------------------------------
. (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')
Set-Location -LiteralPath $projA
# nothing real leaves the sandbox: no desktop toast, no idle clock (as if
# nobody were at the PC), no push service, no ghost-watch events
$script:Toasts = [System.Collections.Generic.List[string]]::new()
$script:ChatqToastSeam = { param($t, $x) $script:Toasts.Add("$t|$x") }
# no alert footer: it reads this PC's real usage and chats (Get-ChatqAlertFooter)
$script:ChatqFooterSeam = { $null }
$script:ChatqIdleSeam = 99999
$script:Ntfys = [System.Collections.Generic.List[object]]::new()
$script:ChatqNtfySeam = { param($server, $body, $headers) $script:Ntfys.Add([pscustomobject]@{ Server = $server; Body = $body; Headers = $headers }) }
# nor to the phone's down topic (src/phone-down.ps1): the whole answer an
# alert sends ahead of its push lands here, from the first section on
$script:Downs = [System.Collections.Generic.List[object]]::new()
$script:ChatqDownSeam = { param($m, $u, $h, $b) $script:Downs.Add([pscustomobject]@{ Method = $m; Url = $u; Headers = $h; Body = $b }); $null }
$script:ChatNoGhostWatch = $true
# and no real background watcher: one would outlive the sandbox it runs in
$script:ChatqSpawn = { $true }
# Nothing a test does ever ends a process, starts code, reads a real
# window's title or starts the overlay's child: every chat process's parent
# is a VS Code window's, ending one only says it is gone, code always works.
# Sections that need otherwise set their own and put these back.
$script:ChatStopSeam = { param($e) 'gone' }
$script:ChatParentSeam = { param($e) @{ Pid = 4242; Name = 'Code'; StartTime = [datetime]::MinValue } }
$script:ChatCodeSeam = { param($f) [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false } }
$script:ChatWindowTitlesSeam = { @() }
$script:ChatCodeExesSeam = { @() }
$script:ChatCodeProfilesSeam = { @() }
$script:ChatShowSpawnSeam = { param($c) $null }
# nor which window is in front: none, so a chat that finishes is marked unread
$script:ChatForegroundSeam = { 0 }
# nor are VS Code's real windows listed for an open's end, any brought to
# the front, or VS Code's processes let do it (Start-ChatOverlayRaise,
# Grant-ChatOverlayFront): no window, every call a no-op
$script:ChatCodeWindowListSeam = { @() }
$script:ChatOverlayRaiseSeam = { param($c, $h, $o) $null }
$script:ChatOverlayGrantSeam = { param($p) @() }
# nor does any overlay pass start codex app-server for Codex's usage
# (Start-ChatqCodexUsageFetch): CHATQ_CODEX is the fake, and a pass would
# leave one behind per collector. Answered as a codex that is not there -
# quiet, the rollout's figure kept; 'codex usage live' sets its own.
$script:ChatOverlayCodexUsageSeam = { param($h) @{ Ok = $false; Why = 'no app-server in the tests'; Quiet = $true } }
# and no run waits out a window showing its chat: tests run one job after
# another into the same chat. 'show fresh' checks the wait itself.
$script:ChatShowHoldSeconds = 0
# nor asks a window to hand its tab over, and waits seconds for an answer
# no extension here gives: every chat's parent is a window (above), so every
# run into a live chat would. The 'handover' section turns it on.
$script:ChatHandoverOff = $true
$script:SeamsAtStart = @{ Stop = $script:ChatStopSeam; Parent = $script:ChatParentSeam; Code = $script:ChatCodeSeam; Titles = $script:ChatWindowTitlesSeam }
