# VS-code-chat-manager, src/phone-board.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region phone: the board and any chat, from the phone ---------------------------
# The paired phone opens the reply page from a bookmark - no alert - and gets
# the overlay's board on it: usage, the chats waiting, working, cut off and
# idle, the queue and the recent ones (docs/phone-board-spec.md, and its
# addendum). It asks for it, and for everything it does there, with a sealed
# message of its own to the reply topic: "chatq3c." + cid, keyed from the
# phone's key D and the message's own id (Unprotect-ChatqComposeMessage), and
# bound to no alert. The PC answers on the down topic (Send-ChatqDown), under
# the request's cid, so the page asks ntfy.sh for exactly its answer.
#
# Nothing the phone sends names a session, a job or a folder: the board hands
# out handles - six random letters, kept in replies.json picks for
# reply.hours - and every act names one. A handle is bound to its kind (a
# chat takes send, read and continue; a job now, skip, stop, retry and allow;
# a folder new), and a send also carries the first 8 of the session id, a
# job act the job's number, so a handle that came to mean something else is
# refused, not acted on. Every job made or requeued here runs within
# reply.maxMode, as a reply's does; a new chat in reply.newMode, capped too.
#
# The order is Receive-ChatqReply's: a nonce seen before is dropped without a
# word; then what the message uses up - its nonce, how far polling got, the
# act counted for the hour - is saved, and only then is anything done. A
# refusal is answered (the MAC checked out, so it is the phone) at most once
# a minute. Nothing is sent or waited on inside the replies lock.

# per act: how old a message may be (seconds), what it counts against in an
# hour, and the kind of handle it names
$script:ChatqComposeActs = @{
    board = @{ Age = 600; Class = 'board'; Kind = $null }
    list = @{ Age = 600; Class = 'look'; Kind = $null }
    status = @{ Age = 600; Class = 'look'; Kind = $null }
    read = @{ Age = 600; Class = 'read'; Kind = 'chat' }
    send = @{ Age = 1800; Class = 'change'; Kind = 'chat' }
    continue = @{ Age = 1800; Class = 'change'; Kind = 'chat' }
    new = @{ Age = 1800; Class = 'change'; Kind = 'folder' }
    now = @{ Age = 1800; Class = 'change'; Kind = 'job' }
    skip = @{ Age = 1800; Class = 'change'; Kind = 'job' }
    stop = @{ Age = 1800; Class = 'change'; Kind = 'job' }
    retry = @{ Age = 1800; Class = 'change'; Kind = 'job' }
    allow = @{ Age = 1800; Class = 'change'; Kind = 'job' }
}
# how many of each in the last hour: a board is asked every 30 s while the
# page is up, a list or a status now and then; what changes the queue, and
# new chats above all, far less
$script:ChatqComposeLimits = @{ board = 120; look = 30; read = 20; change = 20; new = 5 }
# the last board built, and when: a second one asked within 10 s (40 s for
# one from a scan) is sent again rather than built again
$script:ChatqBoardCache = $null
# the scan's cut-off look by transcript, kept between boards
$script:ChatqBoardCutCache = @{}
# a chat's folder and mode as the list read them, by path and write time
$script:ChatqPhoneMetaCache = @{}

#region settings

function Get-ChatqDownChanges {
    <#
    Set-ChatqNotifyConfig's keys for the PC -> phone channel, checked before
    anything is saved: FullText (on/off/bool), FullMax (2000 to 200000),
    Compose (on/off/bool), NewMode (a mode on the ladder), Listen (alerts or
    always). @{ Error; Full; FullMax; Compose; NewMode; Listen } - a key not
    given is $null. -Say is the caller's way to say a line.
    #>
    param([hashtable]$Ch, $Say)
    $r = @{ Error = $null; Full = $null; FullMax = $null; Compose = $null; NewMode = $null; Listen = $null }
    $onOff = { param($v) if ($v -is [bool]) { $v } else { switch (([string]$v).Trim().ToLower()) { 'on' { $true } 'off' { $false } default { $null } } } }
    $given = { param($k) $Ch.ContainsKey($k) -and $null -ne $Ch[$k] -and '' -ne $Ch[$k] }
    if (& $given 'FullText') {
        $r.Full = & $onOff $Ch['FullText']
        if ($null -eq $r.Full) { & $Say "-FullText takes on or off, not '$($Ch['FullText'])'" 'Yellow'; $r.Error = 'bad full text value'; return $r }
    }
    if (& $given 'FullMax') {
        $n = $Ch['FullMax'] -as [int]
        if ($null -eq $n -or $n -lt 2000 -or $n -gt 200000) { & $Say "the whole answer's length: a whole number from 2000 to 200000, not '$($Ch['FullMax'])'" 'Yellow'; $r.Error = 'bad full max'; return $r }
        $r.FullMax = $n
    }
    if (& $given 'Compose') {
        $r.Compose = & $onOff $Ch['Compose']
        if ($null -eq $r.Compose) { & $Say "-Compose takes on or off, not '$($Ch['Compose'])'" 'Yellow'; $r.Error = 'bad compose value'; return $r }
    }
    if (& $given 'NewMode') {
        $want = ([string]$Ch['NewMode']).Trim()
        $r.NewMode = @($script:ChatqModeLadder | Where-Object { $_ -ceq $want })[0]
        if (-not $r.NewMode) { & $Say "a new chat's mode is one of: $($script:ChatqModeLadder -join ', ')" 'Yellow'; $r.Error = 'bad new mode'; return $r }
    }
    if (& $given 'Listen') {
        $l = ([string]$Ch['Listen']).Trim().ToLower()
        if ($l -notin 'alerts', 'always') { & $Say "-Listen takes alerts or always, not '$($Ch['Listen'])'" 'Yellow'; $r.Error = 'bad listen value'; return $r }
        $r.Listen = $l
    }
    return $r
}

function Set-ChatqDownChanges {
    # what Get-ChatqDownChanges let through, into config.json's reply block
    # (not saved here); $true when anything changed
    param($Cfg, $D, $Say)
    if (-not $D) { return $false }
    $any = $false
    $rp = if ($Cfg.PSObject.Properties['reply'] -and $Cfg.reply) { $Cfg.reply } else { [pscustomobject]@{} }
    $cap = (Get-ChatqReplyConfig $Cfg).MaxMode
    if ($null -ne $D.Full) {
        Set-ChatqProp $rp 'full' ([bool]$D.Full); $any = $true
        & $Say $(if ($D.Full) { 'the whole answer goes to the phone with done, needs input and failed - sealed, through ntfy.sh' } else { 'whole answers off - the phone gets the alert''s excerpt only' }) 'Green'
    }
    if ($null -ne $D.FullMax) { Set-ChatqProp $rp 'fullMax' ([int]$D.FullMax); $any = $true; & $Say "a whole answer is $($D.FullMax) characters at most - the end is kept" 'Green' }
    if ($null -ne $D.Compose) {
        Set-ChatqProp $rp 'compose' ([bool]$D.Compose); $any = $true
        & $Say $(if ($D.Compose) { "the phone's board can queue to any chat, act on the queue and start new chats - in $cap at most" } else { 'the phone takes no chats but its alerts''' }) 'Green'
    }
    if ($D.NewMode) {
        Set-ChatqProp $rp 'newMode' $D.NewMode; $any = $true
        $lim = Limit-ChatqPhoneMode $D.NewMode $cap
        & $Say "a chat started from the phone runs in $($lim.Mode)$(if ($lim.Capped) { " - $($D.NewMode) is above the phone's limit" })" 'Green'
    }
    if ($D.Listen) {
        Set-ChatqProp $rp 'listen' $D.Listen; $any = $true
        if ($D.Listen -eq 'always') { & $Say 'listening all the time while a phone is paired - a hidden PowerShell stays running and asks ntfy.sh every 20 s' 'Green' }
        else { & $Say 'listening only while an alert is out' 'Green' }
    }
    if ($any) { Set-ChatqProp $Cfg 'reply' $rp }
    return $any
}

function Update-ChatqReplyStanding {
    # After a save - chatnotify, the setup window: listening all the time
    # begins (-Listen always), with a watcher started to do it when none
    # runs, or ends (-Listen alerts), so the setting holds from now, not from
    # the next shell.
    param($D, $Cfg)
    try {
        if (-not $D -or -not $D.Listen) { return }
        if ($D.Listen -ne 'always') { $null = Stop-ChatqReplyStanding; return }
        if ((Start-ChatqReplyStanding $Cfg) -and $env:CHATQ_WATCHER -ne '1' -and -not (Test-ChatqWatcherAlive)) { $null = Start-ChatqWatcherProcess }
    }
    catch {}
}

function Get-ChatqBoardStatusParts {
    # Get-ChatqPhoneStatusText's words for this channel: listening all the
    # time, and whether whole answers go
    param($Rc, $State)
    $out = @()
    if ($Rc.Listen -eq 'always') {
        $out += if ($State -and $State.standing) { 'listening all the time' } else { 'listens all the time from the next shell (a stop ended it)' }
    }
    $out += if ($Rc.Full) { 'whole answers on' } else { 'whole answers off' }
    return $out
}

function Write-ChatqBoardNotifyStatus {
    # chatnotify's lines for this channel, under the replies line
    param($Cfg)
    $rc = Get-ChatqReplyConfig $Cfg
    if (-not $rc.Wanted) { return }
    $d = $script:ChatqDot
    $parts = @("whole answers $(if ($rc.Full) { 'on' } else { 'off' })", "board and new chats $(if ($rc.Compose) { 'on' } else { 'off' })",
        "listen $(if ($rc.Listen -eq 'always') { 'always' } else { 'while an alert is out' })")
    Write-Host "    $($parts -join " $d ")" -ForegroundColor DarkGray
    if ($rc.Compose -and $rc.Listen -ne 'always') { Write-Host '    the board reaches the PC only while an alert is out - chatnotify -Listen always for any time' -ForegroundColor DarkGray }
}

#endregion

#region the phone's messages

function Test-ChatqComposeMessage {
    # Test-ChatqReplyMessage's answer for a "chatq3c." message: junk until
    # its MAC checks out under the phone's key, then Compose - what
    # Unprotect-ChatqComposeMessage made of it - for Receive-ChatqCompose
    param($Rc, [string]$Message)
    $r = [pscustomobject]@{ Junk = $false; Stage = $null; Error = $null; Reply = $null; Pair = $null; Compose = $null }
    $v = Unprotect-ChatqComposeMessage $Message $Rc.Master
    if (-not $v.Ok -and $v.Stage -ne 'decrypt') { $r.Junk = $true; $r.Stage = $v.Stage; $r.Error = $v.Error; return $r }
    $r.Compose = $v
    return $r
}

function Receive-ChatqCompose {
    <#
    One message from the phone about no alert, its MAC checked already
    (-Checked). In Receive-ChatqReply's order: a nonce this process or the
    file has seen is dropped in silence; then one Use-ChatqReplyState block
    records it - where polling got to, the nonce spent, the act counted for
    the hour, a message's worth of the day's down budget, the next 2
    minutes of faster polling (hotUntil) - and decides whether it is
    refused: compose off, sent too long ago (10 minutes for a look, 30 for
    a change), too many this hour, a handle unknown or of the wrong kind.
    A save that fails is 'unsaved': nothing done, the message comes back.
    A refusal is said to the phone on the down topic, at most once a minute.
    The rest goes to Invoke-ChatqCompose. Returns its answer, $null, or
    'unsaved'.
    #>
    param($Rc, [string]$Id, [string]$Message, $Checked, [switch]$Quick)
    $tag = "$($Rc.Topic)|$Id"
    $v = $Checked.Compose
    $pl = $v.Payload
    $nonce = if ($v.Ok) { [string]$pl.nonce } else { '' }
    if ($nonce -and $script:ChatqReplySeen.ContainsKey($nonce)) {
        $script:ChatqReplyHandled[$tag] = $true
        try { $null = Use-ChatqReplyState { param($st) $st.lastId = $Id } $Rc.Hours } catch {}
        return $null
    }
    $composeAct = if ($v.Ok) { [string]$pl.act } else { '' }
    $composeSpec = $script:ChatqComposeActs[$composeAct]
    $composeRc = $Rc
    try {
        $rec = Use-ChatqReplyState {
            param($st)
            $now = Get-Date
            $st.lastId = $Id
            $st.lastPolledAt = Get-ChatqStamp
            $seen = [bool]($nonce -and $st.seen.ContainsKey($nonce))
            if ($nonce -and -not $seen) { $st.seen[$nonce] = Get-ChatqStamp }
            $fail = $null
            $say = $null
            $pick = $null
            if ($seen) { $fail = 'seen before' }
            elseif (-not $v.Ok -or -not $nonce) {
                $fail = if ($v.Ok) { 'no nonce' } else { "$($v.Stage): $($v.Error)" }
                $say = 'a message came in that could not be read - nothing done'
            }
            elseif (-not $composeSpec) { $fail = "unknown act"; $say = "this PC does not know '$composeAct' - the page is newer than chatq here" }
            elseif (-not $composeRc.Compose -and $composeAct -ne 'status') { $fail = 'compose off'; $say = 'the PC does not take chats from the phone - chatnotify -Compose on' }
            else {
                $ts = $pl.ts -as [double]
                $age = if ($null -ne $ts) { ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts) / 1000 } else { $null }
                $hour = @(@($st.compose) | Where-Object { $_ -and $_.at -and (ConvertTo-ChatqDate $_.at) -gt $now.AddHours(-1) })
                $class = $composeSpec.Class
                $used = @($hour | Where-Object { $script:ChatqComposeActs[[string]$_.act] -and $script:ChatqComposeActs[[string]$_.act].Class -eq $class }).Count
                $newUsed = @($hour | Where-Object { [string]$_.act -eq 'new' }).Count
                if ($null -eq $age -or [Math]::Abs($age) -gt $composeSpec.Age) {
                    $fail = if ($null -eq $age) { 'no time in it' } else { "sent $([int]$age) s ago" }
                    $say = "that was sent too long ago, or the phone's clock is off - nothing done"
                }
                elseif ($used -ge $script:ChatqComposeLimits[$class] -or ($composeAct -eq 'new' -and $newUsed -ge $script:ChatqComposeLimits['new'])) {
                    $fail = "too many ($class)"
                    $say = 'too many from the phone this hour - nothing done'
                }
                elseif ($composeSpec.Kind) {
                    $h = [string]$pl.h
                    $p = if ($h -cmatch '^[a-z2-7]{6}$') { $st.picks[$h] } else { $null }
                    $x = if ($p) { ConvertTo-ChatqDate $p.expires } else { $null }
                    $idOk = switch ($composeAct) {
                        'send' { [bool]($p -and $p.sessionId -and ([string]$pl.id) -ceq ([string]$p.sessionId).Substring(0, [Math]::Min(8, ([string]$p.sessionId).Length))) }
                        { $_ -in 'now', 'skip', 'stop', 'retry', 'allow' } { [bool]($p -and $p.seq -and ($pl.n -as [int]) -eq [int]$p.seq) }
                        default { $true }
                    }
                    if (-not $p -or -not $x -or $x -lt $now -or [string]$p.kind -ne $composeSpec.Kind -or -not $idOk) {
                        $fail = "handle $h unknown, expired or not a $($composeSpec.Kind)"
                        $say = 'that list is out of date - refresh it'
                    }
                    else { $pick = $p.Clone() }
                }
            }
            # the answer's share of ntfy.sh's day: a whole answer's for read
            $budget = $false
            if (-not $fail -or $say) {
                $day = $now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                if (-not $st.down -or [string]$st.down.day -ne $day) { $st.down = @{ day = $day; full = 0; other = 0 } }
                $cap = [int]$composeRc.DownPerDay
                if (-not $fail -and $composeAct -eq 'read') {
                    if ([int]$st.down.full -lt $cap) { $st.down.full = [int]$st.down.full + 1; $budget = $true }
                }
                elseif ([int]$st.down.full + [int]$st.down.other -lt $cap + 50) { $st.down.other = [int]$st.down.other + 1; $budget = $true }
            }
            if (-not $fail) {
                $st.compose = @(@($st.compose) + @(@{ at = (Get-ChatqStamp); act = $composeAct }))
                $st.hotUntil = $now.AddMinutes(2).ToUniversalTime().ToString('o')
            }
            # one refusal a minute, decided here where the last is on record
            if ($say) {
                $last = ConvertTo-ChatqDate $st.composeRefusedAt
                if ($last -and ($now - $last).TotalSeconds -lt 60) { $say = $null }
                else { $st.composeRefusedAt = Get-ChatqStamp }
            }
            [pscustomobject]@{ Fail = $fail; Say = $say; Pick = $pick; Budget = $budget }
        } $Rc.Hours
    }
    catch {
        Write-ChatqReplyLog "compose $Id not acted on - the reply state could not be saved: $($_.Exception.Message)"
        return 'unsaved'
    }
    $script:ChatqReplyHandled[$tag] = $true
    if ($nonce) { $script:ChatqReplySeen[$nonce] = $true }
    $cid = [string]$v.Cid
    if ($rec.Fail) {
        if ($rec.Fail -ne 'seen before') { Write-ChatqReplyLog "compose $Id refused - $composeAct - $($rec.Fail)" }
        if ($rec.Say -and $rec.Budget) { $null = Send-ChatqComposeAck $Rc $cid $composeAct $false $rec.Say -Quick:$Quick }
        return $null
    }
    Write-ChatqReplyLog "compose $Id - $composeAct$(if ($pl.h) { " $($pl.h)" })"
    if (-not $rec.Budget) {
        Write-ChatqReplyLog "compose $Id - no answer: the day's down messages are used (reply.downPerDay)"
        if ($composeAct -in 'board', 'list', 'status', 'read') { return [pscustomobject]@{ Act = $composeAct; Ok = $false; Say = 'the day''s budget is used'; Job = $null } }
    }
    return (Invoke-ChatqCompose $pl $rec.Pick -Cid $cid -Rc $Rc -Quick:$Quick -NoAck:(-not $rec.Budget))
}

function Send-ChatqComposeAck {
    # the PC's word on an act, on the down topic under the request's cid
    param($Rc, [string]$Cid, [string]$Act, [bool]$Ok, [string]$Say, [int]$Seq = 0, [switch]$Quick)
    $body = [ordered]@{ v = 3; kind = 'ack'; ref = $Cid; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); act = $Act; ok = $Ok; say = $Say }
    if ($Seq) { $body['seq'] = $Seq }
    $r = Send-ChatqDown $Rc $Cid $body -Quick:$Quick
    return [bool]$r.Ok
}

function Invoke-ChatqCompose {
    <#
    One act from the phone's board, after Receive-ChatqCompose let it
    through. -Pick is the handle's record, a copy. Answers on the down topic
    under -Cid: the board, the list, the status, a chat's last answer, or an
    ack - and, for anything that changed the queue, the usual reply push as
    well, which reaches a phone whose page was closed and whose link answers
    the job. -NoAck: the day's budget is used, so nothing goes on the down
    topic. Returns @{ Act; Ok; Say; Job }.
    #>
    param($Payload, $Pick, [string]$Cid, $Rc, [switch]$Quick, [switch]$NoAck)
    $act = [string]$Payload.act
    $cap = if ($Rc.MaxMode) { $Rc.MaxMode } else { 'acceptEdits' }
    $ok = $false
    $say = $null
    # the push's words, when they must say less than the sealed ack's
    $push = $null
    $job = $null
    $seq = 0
    switch -Exact ($act) {
        'board' {
            $b = Get-ChatqPhoneBoardAnswer $Rc $Cid
            if (-not $b.Body) { $say = $b.Error; break }
            $r = Send-ChatqDown $Rc $Cid $b.Body -Quick:$Quick
            return [pscustomobject]@{ Act = $act; Ok = [bool]$r.Ok; Say = $(if ($r.Ok) { 'board sent' } else { $r.Error }); Job = $null }
        }
        'list' {
            $b = Get-ChatqPhoneListAnswer $Rc $Cid -Quick:$Quick
            if (-not $b.Body) { $say = $b.Error; break }
            $r = Send-ChatqDown $Rc $Cid $b.Body -Quick:$Quick
            return [pscustomobject]@{ Act = $act; Ok = [bool]$r.Ok; Say = $(if ($r.Ok) { 'list sent' } else { $r.Error }); Job = $null }
        }
        'status' { $ok = $true; $say = Get-ChatqPhoneStatusReport }
        'read' {
            # whole answers off means none on the phone, asked for by a
            # board's handle as much as sent with an alert
            if (-not $Rc.Full) { $say = 'whole answers are off on the PC - chatnotify -FullText on'; break }
            $row = Get-ChatqRowById -Id $Pick.sessionId -Provider $Pick.provider -Path $Pick.path -Cwd $Pick.cwd
            if (-not $row) { $say = 'that chat is gone'; break }
            if ($row.Provider -ne 'claude') { $say = 'the last answer is read from Claude chats only'; break }
            $turn = Get-ChatqTurnText ([string]$row.Path) $Rc.FullMax
            if (-not $turn -or -not @($turn.Parts).Count) { $say = 'that chat has no answer yet'; break }
            $body = [ordered]@{
                v = 3; kind = 'reply'; ref = $Cid; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); event = ''
                title = (Format-ChatTitle ([string]$row.Title) 60); at = $(if ($turn.At) { $turn.At.ToUniversalTime().ToString('o') } else { $null }); cut = [int]$turn.Cut; parts = @($turn.Parts)
            }
            if ($NoAck) { return [pscustomobject]@{ Act = $act; Ok = $false; Say = 'the day''s budget is used'; Job = $null } }
            $r = Send-ChatqDown $Rc $Cid $body -Quick:$Quick
            return [pscustomobject]@{ Act = $act; Ok = [bool]$r.Ok; Say = $(if ($r.Ok) { 'answer sent' } else { $r.Error }); Job = $null }
        }
        'send' {
            $row = Get-ChatqRowById -Id $Pick.sessionId -Provider $Pick.provider -Path $Pick.path -Cwd $Pick.cwd
            if (-not $row) { $say = 'that chat is gone - nothing queued'; break }
            $how = @{ Row = $row; Text = [string]$Payload.text; Cap = $cap }
            if ($Pick.ContainsKey('home')) { $how['JobHome'] = $Pick['home'] }
            $made = New-ChatqPhoneJob @how
            if ($made.Error) { $say = $made.Error; break }
            $job = $made.Job
            $ok = $true
            $seq = [int]$job.seq
            $say = "queued #$($job.seq) for $($job.title)$($made.Note)"
            # what it goes after, or waits on: a job of the chat's that needs
            # input is left alone - nothing says this answers it
            $others = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $job.sessionId -and $_.id -ne $job.id })
            $ni = @($others | Where-Object { $_.state -eq 'needs-input' })[0]
            $run = @($others | Where-Object { $_.state -eq 'running' })[0]
            $held = $false
            if ($row.Provider -eq 'claude') {
                try { $held = [bool]@(Get-ChatqLiveSessions $job.home -RegistryOnly | Where-Object { $_.SessionId -eq $job.sessionId -and $_.Status -eq 'waiting' }) } catch {}
            }
            if ($held) { $say = "queued #$($job.seq) - it goes once $($job.title) is free: it waits on a prompt at the PC$($made.Note)" }
            elseif ($run) { $say += " - it goes after #$($run.seq), running now" }
            if ($ni) { $say += " - #$($ni.seq) still needs input" }
        }
        'new' {
            $made = New-ChatqPhoneNewChat -Cwd $Pick.cwd -Name ([string]$Payload.name) -Text ([string]$Payload.text) -Rc $Rc
            if ($made.Error) { $say = $made.Error; break }
            $job = $made.Job
            $ok = $true
            $seq = [int]$job.seq
            $leaf = Split-Path ([string]$job.cwd).TrimEnd('\', '/') -Leaf
            $how = " - runs in $($made.Mode)$(if ($made.Capped) { ', the phone''s limit' })"
            $say = "new chat `"$($job.title)`" queued as #$($job.seq) in $leaf$how"
            # The push is not sealed: Join logs its GETs, and an ntfy alert
            # topic may be read by others. A title the phone typed, or the
            # prompt's first line standing in for one, came up sealed and
            # stays that way - the sealed ack carries it, the push does not.
            $push = "new chat queued as #$($job.seq)$how"
        }
        'continue' {
            $row = Get-ChatqRowById -Id $Pick.sessionId -Provider $Pick.provider -Path $Pick.path -Cwd $Pick.cwd
            if (-not $row) { $say = 'that chat is gone - nothing queued'; break }
            $busy = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $row.Id -and $_.state -in 'queued', 'running' })[0]
            if ($busy) { $say = "#$($busy.seq) is $($busy.state) for that chat already - nothing queued"; break }
            $how = @{ Row = $row; Text = ''; Cap = $cap; Kind = 'continue' }
            if ($Pick.ContainsKey('home')) { $how['JobHome'] = $Pick['home'] }
            $made = New-ChatqPhoneJob @how
            if ($made.Error) { $say = $made.Error; break }
            $job = $made.Job
            $ok = $true
            $seq = [int]$job.seq
            $say = "continue queued as #$($job.seq) for $($job.title) - it goes when the limit resets$($made.Note)"
            # the cut-off answered, as the ask's own answers mark it: the
            # automatic mode and the reset ask read this job - skipped later
            # from the phone - as declined, never as a cut-off nobody touched
            try {
                $lt = if ($row.Provider -eq 'claude' -and $row.Path) { Get-ChatqLastTurn ([string]$row.Path) } else { $null }
                if ($lt -and ($lt.Limit -or $lt.Overloaded)) {
                    $cut = [pscustomobject]@{ Id = [string]$row.Id; LimitUuid = $lt.Uuid; At = $lt.At; ResetsAt = $lt.ResetsAt }
                    $key = Get-ChatqCutKey $cut
                    if ($key) { $null = Save-ChatqAskAnswer -Keys @($key) -Answer continue -Source phone -Seqs @{ $key = @([int]$job.seq) } -Extra (Get-ChatqAskExtra @($cut) @($key)) }
                }
            }
            catch { Write-ChatqReplyLog "continue #$($job.seq): its cut-off not marked - $($_.Exception.Message)" }
        }
        default {
            $r = Invoke-ChatqJobAct $act $Pick -Cap $cap
            $ok = $r.Ok
            $say = $r.Say
            $job = $r.Job
            if ($job) { $seq = [int]$job.seq }
        }
    }
    Write-ChatqReplyLog "-> $say"
    # the queue changed: the page asks for its board again as it goes back,
    # often within the 10 s a board is sent again unbuilt
    if ($ok -and $act -ne 'status') { $script:ChatqBoardCache = $null }
    if (-not $NoAck) { $null = Send-ChatqComposeAck $Rc $Cid $act $ok $say $seq -Quick:$Quick }
    # a change to the queue gets the usual push too: about the job, so its
    # link answers it
    if ($ok -and $act -ne 'status') { [void](Send-ChatqAlert 'reply' $(if ($push) { $push } else { $say }) 1 -Loud -Job $job -Quick:$Quick) }
    return [pscustomobject]@{ Act = $act; Ok = $ok; Say = $say; Job = $job }
}

function Invoke-ChatqJobAct {
    <#
    now, skip, stop, retry or allow on a job the board named, as the alert
    replies do them (Invoke-ChatqReply) and within the same cap. now is
    chatqrun <n> -Now for that job: to the front of its lane, and the
    watcher told to stop waiting - it probes first, so nothing is sent while
    a limit still holds. Returns @{ Ok; Say; Job }.
    #>
    param([string]$Act, $Pick, [string]$Cap)
    $job = Find-ChatqJob ([string]$Pick.jobId) -Exact
    # the job the handle was made for, or none: never another under its id
    if ($job -and $Pick.seq -and [int]$job.seq -ne [int]$Pick.seq) { $job = $null }
    $n = "#$($Pick.seq)"
    $limitNote = { param($m) " - runs in $m, the phone's limit" }
    $fail = { param($t) [pscustomobject]@{ Ok = $false; Say = $t; Job = $job } }
    if (-not $job) { return (& $fail "$n is gone - nothing to $Act") }
    switch -Exact ($Act) {
        'now' {
            if ($job.state -ne 'queued') { return (& $fail "#$($job.seq) is $($job.state) - send now is for a queued job") }
            Set-ChatqJobFirst $job
            # the watcher that read this is the one told; nothing waits for it
            Send-ChatqWake 'now'
            if ($env:CHATQ_WATCHER -ne '1' -and -not (Test-ChatqWatcherAlive)) { try { $null = Start-ChatqWatcherProcess } catch {} }
            return [pscustomobject]@{ Ok = $true; Say = "#$($job.seq) goes next - a probe first, so nothing is sent while the limit still holds"; Job = $job }
        }
        'skip' {
            if ($job.state -eq 'running') { return (& $fail "#$($job.seq) is running - use stop") }
            if ($job.state -notin 'queued', 'failed', 'needs-input') { return (& $fail "#$($job.seq) is $($job.state) - nothing to skip") }
            Complete-ChatqJob $job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'skipped from the phone' }) 'skipped from the phone'
            return [pscustomobject]@{ Ok = $true; Say = "#$($job.seq) skipped"; Job = $job }
        }
        'stop' {
            if ($job.state -ne 'running') { return (& $fail "#$($job.seq) is $($job.state) - nothing to stop") }
            $r = Stop-ChatqJobRun $job
            $say = switch ($r) {
                'cancelling' { "#$($job.seq) stopping" }
                'failed' { "#$($job.seq) marked failed - its watcher was already gone" }
                default { "#$($job.seq) had already ended" }
            }
            return [pscustomobject]@{ Ok = ($r -ne 'not running'); Say = $say; Job = $job }
        }
        'retry' {
            if ($job.state -notin 'failed', 'needs-input') { return (& $fail "#$($job.seq) is $($job.state) - nothing to retry") }
            $note = ''
            $m = ''
            if ($job.provider -eq 'codex') {
                if ($job.sandbox -and [string]$job.sandbox -notin $script:ChatqSafeSandboxes) { Set-ChatqProp $job 'sandbox' 'workspace-write'; $note = & $limitNote 'workspace-write' }
            }
            else {
                $lim = Limit-ChatqPhoneMode $(if ($job.mode) { [string]$job.mode } else { [string]$job.modeAtQueue }) $Cap
                if ($lim.Capped) { $m = $lim.Mode; $note = & $limitNote $lim.Mode }
            }
            $r = Reset-ChatqJob $job $m
            if ($r.Error) { return (& $fail $r.Error) }
            return [pscustomobject]@{ Ok = $true; Say = "#$($job.seq) queued again ($(if ($r.Landed) { 'continue' } else { 'full prompt' }))$note"; Job = $job }
        }
        'allow' {
            if ($job.provider -ne 'claude') { return (& $fail 'allow is Claude only - use retry') }
            if ($job.state -ne 'needs-input') { return (& $fail "#$($job.seq) is $($job.state) - allow is for a job that needs input") }
            $eff = if ($job.mode) { [string]$job.mode } else { [string]$job.modeAtQueue }
            $want = if ((Get-ChatqModeRank $eff) -lt (Get-ChatqModeRank 'acceptEdits')) { 'acceptEdits' } else { $eff }
            $lim = Limit-ChatqPhoneMode $want $Cap
            $r = if ($lim.Mode -ceq $eff) { Reset-ChatqJob $job } else { Reset-ChatqJob $job $lim.Mode }
            if ($r.Error) { return (& $fail $r.Error) }
            return [pscustomobject]@{ Ok = $true; Say = "#$($job.seq) queued again in $($lim.Mode) ($(if ($r.Landed) { 'continue' } else { 'full prompt' }))$(if ($lim.Capped) { " - the phone's limit" })"; Job = $job }
        }
    }
    return (& $fail "nothing to $Act")
}

function New-ChatqPhoneJob {
    <#
    A job for a chat from the phone, as an alert reply's prompt makes one
    (Invoke-ChatqReply): the text checked (not empty, 8000 characters at
    most), the chat's own mode brought down to -Cap - a Codex chat's sandbox
    never wider than workspace-write - and queued as rule phone with its
    links left as text (-NoLinks). -JobHome: the chat's config dir, $null
    for the default one; left out, the environment's. -Kind continue: the
    words Claude Code itself sends after a limit, no text. Returns @{ Error;
    Job; Note } - Note the words about the cap, for the answer.
    #>
    param($Row, [string]$Text, [string]$Cap = 'acceptEdits', $JobHome, [ValidateSet('prompt', 'continue')][string]$Kind = 'prompt')
    $fail = { param($t) [pscustomobject]@{ Error = $t; Job = $null; Note = '' } }
    if ($Kind -eq 'prompt') {
        if (-not $Text.Trim()) { return (& $fail 'an empty message - nothing queued') }
        if ($Text.Length -gt 8000) { return (& $fail "that message is $($Text.Length) characters, 8000 at most - nothing queued") }
    }
    $info = Get-ChatqJobInfo $Row
    if ($info.Error) { return (& $fail "nothing queued: $($info.Error)") }
    $note = ''
    $mode = ''
    if ($Row.Provider -eq 'codex') {
        if ($info.Sandbox -and [string]$info.Sandbox -notin $script:ChatqSafeSandboxes) {
            $info.Sandbox = 'workspace-write'
            $info.Mode = 'workspace-write'
            $note = " - runs in workspace-write, the phone's limit"
        }
    }
    else {
        $lim = Limit-ChatqPhoneMode ([string]$info.Mode) $Cap
        if ($lim.Capped) { $mode = $lim.Mode; $note = " - runs in $($lim.Mode), the phone's limit" }
    }
    $how = @{ Row = $Row; Info = $info; Prompt = $Text; Kind = $Kind; Rule = 'phone'; Mode = $mode; NoLinks = $true }
    if ($PSBoundParameters.ContainsKey('JobHome')) { $how['JobHome'] = $JobHome }
    $r = New-ChatqJob @how
    if ($r.Error) { return (& $fail "nothing queued: $($r.Error)") }
    return [pscustomobject]@{ Error = $null; Job = $r.Job; Note = $note }
}

function New-ChatqPhoneNewChat {
    <#
    A new chat from the phone, in a folder its board or list offered - never
    a path the phone typed: the folder must still be there. -Name is the
    title (control and format characters out, 60 at most), else the text's
    first line. It runs in reply.newMode brought down to reply.maxMode, in
    the default config dir, as the console's new chat. Returns @{ Error;
    Job; Mode; Capped }.
    #>
    param([string]$Cwd, [string]$Name, [string]$Text, $Rc)
    $fail = { param($t) [pscustomobject]@{ Error = $t; Job = $null; Mode = $null; Capped = $false } }
    # one on another machine is not asked (Test-ChatOverlayFolder): a share
    # asleep would hold the watcher's tick
    if (-not $Cwd -or -not (Test-ChatOverlayFolder $Cwd)) { return (& $fail 'that folder is gone - nothing queued') }
    if (-not $Text.Trim()) { return (& $fail 'an empty message - nothing queued') }
    if ($Text.Length -gt 8000) { return (& $fail "that message is $($Text.Length) characters, 8000 at most - nothing queued") }
    $title = (([string]$Name) -replace '[\p{Cc}\p{Cf}]', ' ').Trim()
    if ($title.Length -gt 60) {
        $n = 60
        if ([char]::IsHighSurrogate($title[$n - 1])) { $n-- }
        $title = $title.Substring(0, $n).TrimEnd()
    }
    $cap = if ($Rc.MaxMode) { $Rc.MaxMode } else { 'acceptEdits' }
    $lim = Limit-ChatqPhoneMode $(if ($Rc.NewMode) { $Rc.NewMode } else { 'default' }) $cap
    $how = @{ Kind = 'new'; Cwd = $Cwd; Prompt = $Text; Mode = $lim.Mode; Rule = 'phone'; NoLinks = $true; JobHome = $null }
    if ($title) { $how['Title'] = $title }
    $r = New-ChatqJob @how
    if ($r.Error) { return (& $fail "nothing queued: $($r.Error)") }
    return [pscustomobject]@{ Error = $null; Job = $r.Job; Mode = $lim.Mode; Capped = [bool]$lim.Capped }
}

function Invoke-ChatqReadAct {
    <#
    An alert's act read: its chat's whole answer once more on the down topic
    (Send-ChatqReplyText -Again) - a job's, from its log, else the chat's
    transcript. Not counted against the day's whole answers twice for one
    alert; sent again within 3 hours only when the first went as an
    attachment, which ntfy.sh keeps 3 hours. No push: the page is open and
    waiting. What went wrong is an ack under the alert's id, so the page
    can say it. Returns @{ Act; Feedback; Job }.
    #>
    param($Entry, [string]$Aid, $Rc, [switch]$Quick)
    $job = if ($Entry.jobId) { Find-ChatqJob ([string]$Entry.jobId) -Exact } else { $null }
    if (-not $job -and $Entry.sessionId) {
        $job = ConvertTo-ChatqLiveJob $Entry
        if ($Entry.provider) { $job.provider = [string]$Entry.provider }
    }
    $sent = [bool](Send-ChatqReplyText $Rc $Aid ([string]$Entry.event) $job -Quick:$Quick -Again)
    $say = if ($sent) { 'the whole answer sent again' } elseif ($script:ChatqReplyTextWhy) { $script:ChatqReplyTextWhy } else { 'the whole answer could not be sent' }
    Write-ChatqReplyLog "-> read: $say"
    if (-not $sent -and (Add-ChatqDownCount $Rc 'other')) { $null = Send-ChatqComposeAck $Rc $Aid 'read' $false $say -Quick:$Quick }
    return [pscustomobject]@{ Act = 'read'; Feedback = $say; Job = $null }
}

#endregion

#region handles

function Get-ChatqFolderKey {
    # one folder, however it was written: d:/x and D:\x\ are the same one
    param([string]$Path)
    $p = ([string]$Path).Trim()
    try { $p = [System.IO.Path]::GetFullPath($p) } catch {}
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

function Get-ChatqPickKey {
    # what a handle stands for, one string: a chat, a job or a folder
    param($Pick)
    switch ([string](Get-ChatField $Pick 'kind')) {
        'chat' { return "chat|$(Get-ChatField $Pick 'sessionId')" }
        'job' { return "job|$(Get-ChatField $Pick 'jobId')" }
        'folder' { return "folder|$(Get-ChatqFolderKey ([string](Get-ChatField $Pick 'cwd')))" }
    }
    return $null
}

function Register-ChatqPicks {
    <#
    Handles for what a board or a list names, in one Use-ChatqReplyState
    block: -Items are @{ Key; Pick }, Pick a hashtable (kind, sessionId,
    provider, path, cwd, home, title, jobId, seq). A chat, job or folder
    that has a handle still good keeps it - its expiry moved on - so a page
    that asks every 30 s does not fill the 300 with the same chats, and a
    chat view left open keeps working. Returns key -> handle; throws when
    replies.json cannot be saved.
    #>
    param($Rc, [object[]]$Items)
    $pickItems = @($Items)
    $pickHours = if ($Rc -and $Rc.Hours) { [double]$Rc.Hours } else { 12 }
    return (Use-ChatqReplyState {
            param($st)
            $now = Get-Date
            $until = $now.AddHours($pickHours).ToUniversalTime().ToString('o')
            $byKey = @{}
            foreach ($e in @($st.picks.GetEnumerator())) {
                $x = ConvertTo-ChatqDate $e.Value.expires
                if (-not $x -or $x -lt $now) { continue }
                $k = Get-ChatqPickKey $e.Value
                if ($k) { $byKey[$k] = $e.Key }
            }
            $map = @{}
            foreach ($it in $pickItems) {
                if (-not $it -or -not $it.Key -or $map.ContainsKey($it.Key)) { continue }
                $h = $byKey[$it.Key]
                if (-not $h) { do { $h = New-ChatqRandomName 6 } while ($st.picks.ContainsKey($h)) }
                $p = @{}
                foreach ($k in $it.Pick.Keys) { $p[$k] = $it.Pick[$k] }
                $p['at'] = Get-ChatqStamp
                $p['expires'] = $until
                $st.picks[$h] = $p
                $map[$it.Key] = $h
            }
            $map
        } $pickHours)
}

function Set-ChatqBoardHandles {
    # the handles in place of the keys a board or list was built with
    param($Body, [hashtable]$Map)
    foreach ($section in 'open', 'cut', 'queue', 'recent', 'chats', 'folders') {
        if (-not $Body.Contains($section)) { continue }
        foreach ($row in @($Body[$section])) {
            if (-not $row) { continue }
            if ($row.Contains('h')) { $row['h'] = [string]$Map[[string]$row['h']] }
            if ($row.Contains('jobs')) { foreach ($j in @($row['jobs'])) { if ($j) { $j['h'] = [string]$Map[[string]$j['h']] } } }
        }
    }
}

#endregion

#region the board

function ConvertTo-ChatqIso {
    # epoch ms, a date or an ISO string as UTC ISO; $null for none
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return $null }
    try {
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
        $ms = $Value -as [int64]
        if ($null -ne $ms -and "$Value" -match '^\d{10,}$') { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime.ToString('o') }
        $d = ConvertTo-ChatqDate $Value
        if ($d) { return $d.ToUniversalTime().ToString('o') }
    }
    catch {}
    return $null
}

function Get-ChatqBoardLine {
    # one line of text, whitespace folded, cut to -Max without splitting an emoji
    param([string]$Text, [int]$Max)
    $t = ((([string]$Text) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) {
        $n = $Max - 1
        if ($n -gt 0 -and [char]::IsHighSurrogate($t[$n - 1])) { $n-- }
        $t = $t.Substring(0, $n).TrimEnd() + $script:ChatqEllipsis
    }
    return $t
}

function ConvertTo-ChatqPhoneBoard {
    <#
    The board the phone draws, from what the overlay computes: -Snap is
    data/overlay.json as the overlay wrote it (rows, recent, header.usage),
    or the same built by a scan (Get-ChatqBoardScan). -Jobs and -Eta are the
    queue as chatqlist reads it. Pure, for the tests. Returns @{ Body;
    Items } - Body the board with a key in every h, Items what each key
    stands for, for Register-ChatqPicks.
      open    chats open in VS Code or a terminal: waiting, working or idle,
              the newest prompt, the blue new-turn dot, the jobs riding on it
      cut     chats the limit or a 529 stopped: the overlay's own words, the
              reset when the scan knows it, a continue queued for it
      queue   jobs queued, running, needing input, and failed in the last
              12 hours, with "sends" as chatqlist has it
      recent  the overlay's Recent list
      folders where a new chat can start: the board's chats' folders, the
              console's, the queue's - 15 at most
    Titles 60 characters, prompts 120. -Home is the chats' config dir,
    $null for the default one. -CutInfo: session id -> reset time.
    #>
    param($Snap, [object[]]$Jobs, [hashtable]$Eta, [string]$From = 'overlay', [datetime]$Now = (Get-Date), $HomeDir, [hashtable]$CutInfo, [string[]]$Folders)
    $items = [System.Collections.Generic.List[object]]::new()
    $known = @{}
    $key = {
        param([string]$k, [hashtable]$pick)
        if (-not $known.ContainsKey($k)) { $known[$k] = $true; $items.Add(@{ Key = $k; Pick = $pick }) }
        $k
    }
    $iso = { param($v) ConvertTo-ChatqIso $v }
    $cutoff12 = $Now.AddHours(-12)
    $boardJobs = @(@($Jobs) | Where-Object {
            $_ -and ($_.state -in 'queued', 'running', 'needs-input' -or ($_.state -eq 'failed' -and (ConvertTo-ChatqDate $_.endedAt) -gt $cutoff12))
        })
    $jobKey = {
        param($j)
        & $key "job|$($j.id)" @{ kind = 'job'; jobId = [string]$j.id; seq = [int]$j.seq; sessionId = [string]$j.sessionId; title = [string]$j.title }
    }
    $sendsOf = {
        param($j)
        switch ([string]$j.state) {
            'queued' { $e = if ($Eta) { [string]$Eta[$j.id] } else { '' }; if ($e) { $e } else { 'next' } }
            'running' { 'running now' }
            'needs-input' { 'needs you' }
            default { [string]$j.state }
        }
    }
    $jobsOf = {
        param([string]$sid)
        @(foreach ($j in $boardJobs) {
                if ($sid -and [string]$j.sessionId -eq $sid) { [ordered]@{ h = (& $jobKey $j); n = [int]$j.seq; s = [string]$j.state; e = (& $sendsOf $j); k = [string]$j.kind } }
            })
    }
    $chatKey = {
        param([string]$sid, [string]$cwd, [string]$title, [string]$path)
        $p = @{ kind = 'chat'; sessionId = $sid; provider = 'claude'; cwd = $cwd; title = $title; home = $HomeDir }
        if ($path) { $p['path'] = $path }
        & $key "chat|$sid" $p
    }
    $more = 0
    $open = [System.Collections.Generic.List[object]]::new()
    $cut = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Snap.rows)) {
        if (-not $r) { continue }
        $kind = [string](Get-ChatField $r 'kind')
        $chat = [string](Get-ChatField $r 'chat')
        $sid = [string](Get-ChatField $r 'sessionId')
        if (-not $sid -or $kind -eq 'job') { continue }
        $title = Format-ChatTitle ([string](Get-ChatField $r 'title')) 60
        $cwd = [string](Get-ChatField $r 'cwd')
        $since = Get-ChatField $r 'since'
        if ($chat -eq 'cutoff' -or [string](Get-ChatField $r 'status') -eq 'cutoff') {
            if ($cut.Count -ge 10) { $more++; continue }
            $detail = [string](Get-ChatField $r 'detail')
            $reset = if ($CutInfo -and $CutInfo[$sid]) { & $iso $CutInfo[$sid] } else { $null }
            $cut.Add([ordered]@{
                    h = (& $chatKey $sid $cwd ([string](Get-ChatField $r 'title')) ([string](Get-ChatField $r 'path'))); id8 = $sid.Substring(0, [Math]::Min(8, $sid.Length)); t = $title
                    f = [string](Get-ChatField $r 'project'); where = [string](Get-ChatField $r 'where'); why = $(if ($detail -like '529*') { 'overloaded' } else { 'limit' })
                    d = $detail; reset = $reset; age = (& $iso $since); jobs = @(& $jobsOf $sid)
                })
            continue
        }
        if ($kind -ne 'session' -or $chat -notin 'waiting', 'busy', 'idle') { continue }
        if ($open.Count -ge 25) { $more++; continue }
        $open.Add([ordered]@{
                h = (& $chatKey $sid $cwd ([string](Get-ChatField $r 'title')) $null); id8 = $sid.Substring(0, [Math]::Min(8, $sid.Length)); t = $title
                f = [string](Get-ChatField $r 'project'); where = [string](Get-ChatField $r 'where'); state = $chat
                what = $(if ($chat -eq 'waiting') { [string](Get-ChatField $r 'detail') } else { '' })
                prompt = (Get-ChatqBoardLine ([string](Get-ChatField $r 'prompt')) 120); new = [bool](Get-ChatField $r 'unread')
                age = (& $iso $since); jobs = @(& $jobsOf $sid)
            })
    }
    $queue = [System.Collections.Generic.List[object]]::new()
    foreach ($j in $boardJobs) {
        if ($queue.Count -ge 30) { $more++; continue }
        $queue.Add([ordered]@{
                h = (& $jobKey $j); n = [int]$j.seq; t = (Format-ChatTitle ([string]$j.title) 60); s = [string]$j.state; e = (& $sendsOf $j)
                k = [string]$j.kind; p = [string]$j.provider; f = $(if ($j.cwd) { Split-Path ([string]$j.cwd).TrimEnd('\', '/') -Leaf } else { '' })
                id8 = $(if ($j.sessionId) { ([string]$j.sessionId).Substring(0, [Math]::Min(8, ([string]$j.sessionId).Length)) } else { '' })
            })
    }
    $recent = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Snap.recent)) {
        if (-not $r) { continue }
        $sid = [string](Get-ChatField $r 'sessionId')
        if (-not $sid) { continue }
        if ($recent.Count -ge 15) { $more++; continue }
        $recent.Add([ordered]@{
                h = (& $chatKey $sid ([string](Get-ChatField $r 'cwd')) ([string](Get-ChatField $r 'title')) $null); id8 = $sid.Substring(0, [Math]::Min(8, $sid.Length))
                t = (Format-ChatTitle ([string](Get-ChatField $r 'title')) 60); f = [string](Get-ChatField $r 'project'); age = (& $iso (Get-ChatField $r 'since'))
            })
    }
    # where a new chat can start: folders chatq already knows, never one the
    # phone names
    $fold = [System.Collections.Generic.List[object]]::new()
    $seenF = @{}
    $cands = @(@($Snap.rows | ForEach-Object { Get-ChatField $_ 'cwd' }) + @($Snap.recent | ForEach-Object { Get-ChatField $_ 'cwd' }) + @($Folders) + @($boardJobs | ForEach-Object { $_.cwd }))
    foreach ($c in $cands) {
        $c = ([string]$c).TrimEnd('\', '/')
        if (-not $c -or $fold.Count -ge 15) { continue }
        $k = Get-ChatqFolderKey $c
        if ($seenF[$k]) { continue }
        $seenF[$k] = $true
        $leaf = Split-Path $c -Leaf
        if (-not $leaf) { $leaf = $c }
        $fold.Add([ordered]@{ h = (& $key "folder|$k" @{ kind = 'folder'; cwd = $c; title = $leaf }); n = $leaf; w = $(Split-Path $c -Parent) })
    }
    $usage = @(foreach ($u in @($Snap.header.usage)) {
            if (-not $u) { continue }
            $at = Get-ChatField $u 'at'
            [ordered]@{
                p = [string]$u.provider
                parts = @(foreach ($w in @($u.windows)) {
                        if ($w) { [ordered]@{ w = [string]$w.label; pct = [int]$w.percent; reset = (& $iso (Get-ChatField $w 'resetsAt')); limited = [bool](Get-ChatField $w 'limited'); sev = [string](Get-ChatField $w 'severity') } }
                    })
                asof = (& $iso $at); stale = [bool](Get-ChatField $u 'stale'); st = [string](Get-ChatField $u 'status')
            }
        })
    $body = [ordered]@{
        v = 3; kind = 'board'; ref = ''; ts = 0; host = ''; cap = ''; newMode = ''; listen = ''; until = $null; compose = $true; from = $From; left = 0
        usage = @($usage); open = @($open.ToArray()); cut = @($cut.ToArray()); queue = @($queue.ToArray()); recent = @($recent.ToArray()); folders = @($fold.ToArray()); more = $more
    }
    return [pscustomobject]@{ Body = $body; Items = $items.ToArray() }
}

function Get-ChatqBoardScan {
    <#
    The overlay's rows with no overlay running, or its snapshot older than 2
    minutes: the registry of open chats, each one's title and newest prompt
    (Update-ChatOverlayText), the chats cut off in the last 12 hours, the
    queue and the Recent list, turned into rows by the overlay's own
    Get-ChatOverlayRows - and usage from the tools' own caches
    (Get-ChatqUsage), never the usage endpoint. Bounded reads only; the
    same shape as data/overlay.json, plus CutInfo (session id -> reset).
    #>
    param([datetime]$Now = (Get-Date))
    $ctx = New-ChatOverlayContext
    $ctx.RecentWhole = $true
    $entries = @(try { Read-ChatqSessionRegistry (Join-Path $ctx.ClaudeHome 'sessions') } catch { @() })
    $live = @($entries | Where-Object { $_.SessionId -and (-not $_.Kind -or $_.Kind -eq 'interactive') -and (Test-ChatqSessionAlive $_) })
    foreach ($e in $live) { try { Update-ChatOverlayText $ctx $e } catch {} }
    $jobs = @(Get-ChatqJobs | Where-Object { $_.state -in 'queued', 'running', 'needs-input' })
    $blocks = try { Get-ChatqBlocks } catch { @{} }
    $eta = if ($jobs) { Get-ChatqEta $jobs $blocks } else { @{} }
    $wrapped = @($jobs | ForEach-Object { [pscustomobject]@{ Job = $_; First = $(if ($_.kind -eq 'continue') { 'continue' } else { (Get-ChatqPromptStats ([string](Read-ChatqPrompt $_))).First }) } })
    $working = @($live | Where-Object { $_.Status -in 'busy', 'waiting' } | ForEach-Object { [string]$_.SessionId })
    # the cut-off look kept between boards, as the watcher's own scan keeps
    # its $W.CutCache: a transcript not written since is not read again
    if ($null -eq $script:ChatqBoardCutCache) { $script:ChatqBoardCutCache = @{} }
    $cutRows = @(try { Get-ChatqCutOffChats @() -Hours 12 -Skip $working -Cache $script:ChatqBoardCutCache } catch { @() })
    $cutInfo = @{}
    foreach ($c in $cutRows) { if ($c.ResetsAt) { $cutInfo[[string]$c.Id] = $c.ResetsAt } }
    $rows = @(Get-ChatOverlayRows -Sessions $live -Texts $ctx.Text -Jobs $wrapped -Eta $eta -Now $Now -CutOff $cutRows -Unread @{})
    try { Update-ChatOverlayRecent $ctx (@($live | ForEach-Object { [string]$_.SessionId }) + @($rows | ForEach-Object { [string]$_.sessionId })) $Now } catch {}
    $usage = @(foreach ($u in @(try { Get-ChatqUsage } catch { @() })) {
            $ws = @(foreach ($p in @($u.Parts)) {
                    if ([string]$p -match '^(.+?)\s+(\d+)%') { [pscustomobject]@{ label = $Matches[1]; percent = [int]$Matches[2]; resetsAt = $null; limited = ([int]$Matches[2] -ge 100); severity = $null } }
                })
            if (-not $ws) { continue }
            [pscustomobject]@{
                provider = $u.Provider; at = $(if ($u.AsOfAt) { ConvertTo-ChatOverlayMs $u.AsOfAt } else { $null }); windows = $ws
                stale = [bool]($u.AsOfAt -and ($Now - $u.AsOfAt).TotalHours -ge 1); status = $(if ($u.AsOf) { "as of $($u.AsOf)" } else { '' })
            }
        })
    return [pscustomobject]@{ rows = $rows; recent = @($ctx.Recent); header = [pscustomobject]@{ usage = $usage }; CutInfo = $cutInfo }
}

function Get-ChatqPhoneBoard {
    <#
    The board as it is now: from data/overlay.json while the overlay keeps
    it fresh (written within 2 minutes), else from a scan, which the page
    says ("from" scan: the overlay is not running - some rows may be
    missing). The queue always from the jobs themselves. Returns
    ConvertTo-ChatqPhoneBoard's @{ Body; Items }.
    #>
    param([datetime]$Now = (Get-Date), [switch]$Scan)
    $snap = $null
    $from = 'scan'
    $cutInfo = @{}
    if (-not $Scan) {
        $s = Read-ChatqJson $script:ChatOverlayPath
        $at = if ($s -and [int](Get-ChatField $s 'schema') -eq 1 -and (Get-ChatField $s 'at')) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.at).LocalDateTime } else { $null }
        if ($at -and [Math]::Abs(($Now - $at).TotalMinutes) -lt 2) { $snap = $s; $from = 'overlay' }
    }
    if (-not $snap) { $snap = Get-ChatqBoardScan $Now; $cutInfo = $snap.CutInfo }
    $jobs = @(Get-ChatqJobs)
    $blocks = try { Get-ChatqBlocks } catch { @{} }
    $eta = Get-ChatqEta $jobs $blocks
    $default = Join-Path $HOME '.claude'
    $homeDir = if ([string]::Equals(([string]$script:ChatClaudeHome).TrimEnd('\', '/'), $default.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $null } else { $script:ChatClaudeHome }
    $folders = @()
    try {
        $cs = Read-ChatqJson $script:ChatConsoleStatePath
        if ($cs -and $cs.PSObject.Properties['folders']) { $folders = @($cs.folders | Where-Object { $_ -and (Test-ChatOverlayFolder ([string]$_)) } | ForEach-Object { [string]$_ }) }
    }
    catch {}
    $b = ConvertTo-ChatqPhoneBoard -Snap $snap -Jobs $jobs -Eta $eta -From $from -Now $Now -HomeDir $homeDir -CutInfo $cutInfo -Folders $folders
    # a folder gone since is not offered; one on another machine is not
    # asked (Test-ChatOverlayFolder), a share asleep would hold the watcher
    $gone = @{}
    foreach ($it in @($b.Items)) { if ($it.Pick.kind -eq 'folder' -and -not (Test-ChatOverlayFolder ([string]$it.Pick.cwd))) { $gone[$it.Key] = $true } }
    if ($gone.Count) {
        $b.Body['folders'] = @(@($b.Body['folders']) | Where-Object { -not $gone[[string]$_.h] })
        $b = [pscustomobject]@{ Body = $b.Body; Items = @(@($b.Items) | Where-Object { -not $gone[$_.Key] }) }
    }
    return $b
}

function Complete-ChatqDownHeader {
    # what every board and list says about the PC: its name, the phone's
    # mode cap, a new chat's mode, whether it listens all the time or until
    # when, and how many messages today's budget has left
    param($Body, $Rc, [string]$Cid)
    $st = try { Get-ChatqReplyState } catch { $null }
    $h = [string][Environment]::MachineName
    if ($h.Length -gt 30) { $h = $h.Substring(0, 30) }
    $Body['ref'] = $Cid
    $Body['ts'] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $Body['host'] = $h
    $Body['cap'] = [string]$Rc.MaxMode
    $Body['newMode'] = [string](Limit-ChatqPhoneMode $Rc.NewMode $Rc.MaxMode).Mode
    $Body['listen'] = $(if ($Rc.Listen -eq 'always' -and $st -and $st.standing) { 'always' } else { 'alerts' })
    $u = if ($st) { ConvertTo-ChatqDate $st.openUntil } else { $null }
    $Body['until'] = $(if ($u -and $u -gt (Get-Date)) { $u.ToUniversalTime().ToString('o') } else { $null })
    $Body['compose'] = [bool]$Rc.Compose
    $Body['left'] = [int](Get-ChatqDownLeft $Rc $st)
}

function Get-ChatqPhoneBoardAnswer {
    <#
    The board for one request: built, its handles minted into replies.json
    (Register-ChatqPicks, a lock block of its own, outside the one that
    recorded the request), and its header filled in. One asked again within
    10 s is the last one sent again, handles and all, not built anew - the
    page refreshes every 30 s, and a double tap should cost nothing. One
    built from a scan (no overlay running) is kept 40 s: the scan reads
    every live chat and the registry, inside a run's tick too, and the
    page's refresh would otherwise never find one kept. An act that
    changes the queue drops it (Invoke-ChatqCompose). Returns @{ Body;
    Error }.
    #>
    param($Rc, [string]$Cid)
    $now = Get-Date
    $c = $script:ChatqBoardCache
    $keep = if ($c -and $c.Body -and [string]$c.Body['from'] -eq 'scan') { 40 } else { 10 }
    if ($c -and $c.Body -and [Math]::Abs(($now - $c.At).TotalSeconds) -lt $keep) {
        Complete-ChatqDownHeader $c.Body $Rc $Cid
        return [pscustomobject]@{ Body = $c.Body; Error = $null; Cached = $true }
    }
    try {
        $b = Get-ChatqPhoneBoard $now
        $map = Register-ChatqPicks $Rc $b.Items
        Set-ChatqBoardHandles $b.Body $map
    }
    catch {
        Write-ChatqReplyLog "board not built: $($_.Exception.Message)"
        return [pscustomobject]@{ Body = $null; Error = 'the PC could not build its board'; Cached = $false }
    }
    Complete-ChatqDownHeader $b.Body $Rc $Cid
    $script:ChatqBoardCache = @{ At = $now; Body = $b.Body }
    return [pscustomobject]@{ Body = $b.Body; Error = $null; Cached = $false }
}

#endregion

#region the list (the chats and folders, not as the overlay has them)

function Get-ChatqPhoneChatMeta {
    # A chat's folder and mode for the list, from a bounded read: the
    # transcript's first and last 256 KB, never the 64 MB walk the queue's
    # own mode lookup makes. Cached by path and write time.
    param($Row)
    $key = "$($Row.Path)|$($Row.Mtime)"
    $hit = $script:ChatqPhoneMetaCache[$key]
    if ($hit) { return $hit }
    $cwd = $null
    $mode = $null
    try {
        if ($Row.Provider -eq 'codex') {
            $m = Get-ChatqCodexMeta $Row.Path
            $cwd = $m.Cwd
            $mode = if ($m.Sandbox) { [string]$m.Sandbox } else { 'workspace-write' }
        }
        else {
            $c = Read-ChatChunk $Row.Path 262144
            if ($c) {
                $text = $c.Head + "`n" + $c.Tail
                $cm = [regex]::Matches($text, '"cwd":"((?:[^"\\]|\\.)*)"')
                if ($cm.Count) { $cwd = Convert-ChatJsonEscaped $cm[$cm.Count - 1].Groups[1].Value }
                $mm = [regex]::Matches($(if ($c.Tail) { $c.Tail } else { $c.Head }), '"permissionMode":"([A-Za-z]+)"')
                if ($mm.Count) { $mode = $mm[$mm.Count - 1].Groups[1].Value }
            }
        }
    }
    catch {}
    $r = [pscustomobject]@{ Cwd = $cwd; Mode = $mode }
    if ($script:ChatqPhoneMetaCache.Count -gt 500) { $script:ChatqPhoneMetaCache = @{} }
    $script:ChatqPhoneMetaCache[$key] = $r
    return $r
}

function Get-ChatqPhoneList {
    <#
    Chats and folders for the phone's list: the index's 30 newest Claude and
    Codex chats (synced first, but not with -Quick, inside a run), plus every
    chat open in VS Code or a terminal not among them; each with its folder,
    the mode a job for it would run in once capped, whether it is open and
    how, and its jobs. Folders chatq already knows, 15 at most. Returns
    @{ Body; Items } as the board does.
    #>
    param($Rc, [switch]$Quick)
    if (-not $Quick) { try { $null = Sync-ChatIndex -Provider claude, codex } catch {} }
    $cap = if ($Rc.MaxMode) { $Rc.MaxMode } else { 'acceptEdits' }
    $rows = @(Get-ChatIndex | Where-Object { $_.Id -and -not ($_.Hidden -eq $true -or [string]$_.Hidden -eq 'True') -and $_.Provider -in 'claude', 'codex' } |
            Sort-Object { [int64]$_.Mtime } -Descending | Select-Object -First 30)
    $live = @(try { Get-ChatqLiveSessions $script:ChatClaudeHome -RegistryOnly | Where-Object { -not $_.Kind -or $_.Kind -eq 'interactive' } } catch { @() })
    $state = @{}
    foreach ($e in $live) { if ($e.SessionId) { $state[[string]$e.SessionId] = if ($e.Status -in 'waiting', 'busy') { [string]$e.Status } else { 'idle' } } }
    $ids = @{}
    foreach ($r in $rows) { $ids[[string]$r.Id] = $true }
    foreach ($sid in @($state.Keys)) {
        if ($ids[$sid]) { continue }
        $r = try { Get-ChatqRowById -Id $sid -Provider claude } catch { $null }
        if ($r) { $rows += $r; $ids[$sid] = $true }
    }
    $jobs = @(Get-ChatqJobs)
    $default = Join-Path $HOME '.claude'
    $homeDir = if ([string]::Equals(([string]$script:ChatClaudeHome).TrimEnd('\', '/'), $default.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $null } else { $script:ChatClaudeHome }
    $items = [System.Collections.Generic.List[object]]::new()
    $chats = [System.Collections.Generic.List[object]]::new()
    $cwds = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $sid = [string]$r.Id
        $meta = Get-ChatqPhoneChatMeta $r
        if ($meta.Cwd) { $cwds.Add([string]$meta.Cwd) }
        $m = $cap
        $mc = $false
        if ($r.Provider -eq 'codex') { $m = if ($meta.Mode -and $meta.Mode -notin $script:ChatqSafeSandboxes) { $mc = $true; 'workspace-write' } elseif ($meta.Mode) { $meta.Mode } else { 'workspace-write' } }
        elseif ($meta.Mode) { $lim = Limit-ChatqPhoneMode $meta.Mode $cap; $m = $lim.Mode; $mc = [bool]$lim.Capped }
        $k = "chat|$sid"
        $pick = @{ kind = 'chat'; sessionId = $sid; provider = [string]$r.Provider; path = [string]$r.Path; cwd = [string]$meta.Cwd; title = [string]$r.Title }
        if ($r.Provider -eq 'claude') { $pick['home'] = $homeDir }
        $items.Add(@{ Key = $k; Pick = $pick })
        $mine = @($jobs | Where-Object { $_.sessionId -eq $sid })
        $ni = @($mine | Where-Object { $_.state -eq 'needs-input' })[0]
        $when = try { [datetime]::new([int64]$r.Mtime, [System.DateTimeKind]::Utc).ToString('o') } catch { $null }
        $chats.Add([ordered]@{
                h = $k; id = $sid.Substring(0, [Math]::Min(8, $sid.Length)); p = [string]$r.Provider; t = (Format-ChatTitle ([string]$r.Title) 60)
                f = $(if ($meta.Cwd) { Split-Path ([string]$meta.Cwd).TrimEnd('\', '/') -Leaf } else { '' }); w = $(if ($meta.Cwd) { Split-Path ([string]$meta.Cwd).TrimEnd('\', '/') -Parent } else { '' })
                m = $m; mc = $mc; known = [bool]$meta.Mode; a = $when; live = $(if ($state.ContainsKey($sid)) { $state[$sid] } else { '' })
                q = @($mine | Where-Object { $_.state -eq 'queued' }).Count; ni = $(if ($ni) { [int]$ni.seq } else { 0 })
            })
    }
    try {
        $cs = Read-ChatqJson $script:ChatConsoleStatePath
        if ($cs -and $cs.PSObject.Properties['folders']) { foreach ($f in @($cs.folders)) { if ($f) { $cwds.Add([string]$f) } } }
    }
    catch {}
    foreach ($j in $jobs) { if ($j.cwd) { $cwds.Add([string]$j.cwd) } }
    $folders = [System.Collections.Generic.List[object]]::new()
    $seenF = @{}
    foreach ($c in $cwds) {
        $c = $c.TrimEnd('\', '/')
        if (-not $c -or $folders.Count -ge 15) { continue }
        $fk = Get-ChatqFolderKey $c
        # a folder from a transcript can be a share, asleep: not asked
        if ($seenF[$fk] -or -not (Test-ChatOverlayFolder $c)) { continue }
        $seenF[$fk] = $true
        $leaf = Split-Path $c -Leaf
        $items.Add(@{ Key = "folder|$fk"; Pick = @{ kind = 'folder'; cwd = $c; title = $leaf } })
        $folders.Add([ordered]@{ h = "folder|$fk"; n = $leaf; w = (Split-Path $c -Parent) })
    }
    $total = @(Get-ChatIndex | Where-Object { $_.Id -and -not ($_.Hidden -eq $true -or [string]$_.Hidden -eq 'True') -and $_.Provider -in 'claude', 'codex' }).Count
    $body = [ordered]@{
        v = 3; kind = 'list'; ref = ''; ts = 0; host = ''; cap = ''; newMode = ''; listen = ''; until = $null; compose = $true; left = 0
        chats = @($chats.ToArray()); folders = @($folders.ToArray()); more = [Math]::Max(0, $total - $chats.Count)
    }
    return [pscustomobject]@{ Body = $body; Items = $items.ToArray() }
}

function Get-ChatqPhoneListAnswer {
    # the list for one request, its handles minted, its header filled in
    param($Rc, [string]$Cid, [switch]$Quick)
    try {
        $b = Get-ChatqPhoneList $Rc -Quick:$Quick
        $map = Register-ChatqPicks $Rc $b.Items
        Set-ChatqBoardHandles $b.Body $map
    }
    catch {
        Write-ChatqReplyLog "list not built: $($_.Exception.Message)"
        return [pscustomobject]@{ Body = $null; Error = 'the PC could not list its chats' }
    }
    Complete-ChatqDownHeader $b.Body $Rc $Cid
    return [pscustomobject]@{ Body = $b.Body; Error = $null }
}

#endregion

#region the setup window's part

function Initialize-ChatqBoardSetup {
    # the three boxes in the setup window's Replies: found, explained, wired
    # to the window's own dirty check (New-ChatqPhoneSetupWindow)
    param($U)
    foreach ($n in 'FullBox', 'ComposeBox', 'ListenBox', 'ListenNote') { $U[$n] = $U.Win.FindName($n) }
    if (-not $U.FullBox) { return }
    $U.FullBox.ToolTip = 'With done, needs input and failed: the reply page shows the whole answer, not the alert''s excerpt. Sealed; ntfy.sh keeps it 12 hours (3 for a long one).'
    $U.ComposeBox.ToolTip = 'The reply page opened from a bookmark shows the overlay''s board: queue to any chat, act on the queue, start a chat in a folder chatq knows.'
    $U.ListenBox.ToolTip = 'Without it the PC reads the phone only while an alert is out.'
    foreach ($b in $U.FullBox, $U.ComposeBox, $U.ListenBox) {
        $b.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    }
}

function Read-ChatqBoardSetupForm {
    # the three boxes from config.json, and what they were, for the dirty check
    param($U, $Cfg)
    if (-not $U.FullBox) { return }
    $rc = Get-ChatqReplyConfig $Cfg
    $U.FullWas = [bool]$rc.Full
    $U.ComposeWas = [bool]$rc.Compose
    $U.ListenWas = $rc.Listen -eq 'always'
    $U.FullBox.IsChecked = $U.FullWas
    $U.ComposeBox.IsChecked = $U.ComposeWas
    $U.ListenBox.IsChecked = $U.ListenWas
}

function Get-ChatqBoardSetupSnapshot {
    # the three boxes as one string, for the window's snapshot
    param($U)
    if (-not $U.FullBox) { return '' }
    return "$([bool]$U.FullBox.IsChecked)|$([bool]$U.ComposeBox.IsChecked)|$([bool]$U.ListenBox.IsChecked)"
}

function Add-ChatqBoardSetupChanges {
    # what Save hands Set-ChatqNotifyConfig for the three boxes: only what
    # differs from the file
    param($U, [hashtable]$C)
    if (-not $U.FullBox) { return }
    if ([bool]$U.FullBox.IsChecked -ne [bool]$U.FullWas) { $C.FullText = [bool]$U.FullBox.IsChecked }
    if ([bool]$U.ComposeBox.IsChecked -ne [bool]$U.ComposeWas) { $C.Compose = [bool]$U.ComposeBox.IsChecked }
    if ([bool]$U.ListenBox.IsChecked -ne [bool]$U.ListenWas) { $C.Listen = $(if ($U.ListenBox.IsChecked) { 'always' } else { 'alerts' }) }
}

#endregion

#endregion
