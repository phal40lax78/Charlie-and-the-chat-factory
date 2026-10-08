# Claude's questions on the phone (docs/phone-ask-spec.md).
#
# Seen: a chat you run yourself that asks with AskUserQuestion shows the
# question, every option and its description on the board and on its needs
# input alert's page. The transcript holds the whole pending call while the
# dialog is open, so this reads nothing the overlay does not read already.
#
# Answered (ask.on, off by default): a Claude Code PermissionRequest hook of
# chatq's, matcher AskUserQuestion, installed as a plugin (Install-ChatqAskHook)
# - Start-ChatqAskHook. Claude Code runs it beside the dialog, not in front
# of it: whichever answers first, the dialog or the hook, is the answer, and
# a hook killed at its timeout changes nothing. It writes a request into
# data/ask/, waits for the phone's sealed answer the watcher drops beside it,
# opens that answer itself with the phone's key, and prints the one decision
# line. Every failure is silence: no output, exit 0, the dialog as it was. It
# never denies. This rests on CLI behaviour the docs do not describe (spec
# S46), so the watcher checks every answer landed (Test-ChatqAskLanded).

# the last look at each transcript, by path: its length and write time, and
# what was pending then - a board built every 10 s parses nothing new
$script:ChatqAskCache = @{}
# the hook's requests; one file each, <rid>.req.json, and the phone's answer
# beside it, <rid>.ans.json
$script:ChatqAskDir = Join-Path $script:ChatqData 'ask'
# the CLI answers were first seen taken on (spec S46 part 1); older says no
$script:ChatqAskMin = '2.1.283'
# the watcher's answers sent, by rid, until Test-ChatqAskLanded has looked
$script:ChatqAskSent = @{}
# Test-ChatqAskHookAlive's answer per pid and start: a command line from CIM
# costs a tenth of a second
$script:ChatqAskAliveCache = @{}
$script:ChatqAskAliveSeam = $null   # tests: { param($Req) $true|$false }
$script:ChatqAskCliSeam = $null     # tests: { param([string[]]$ArgList) @{ Code; Out } }
$script:ChatqAskPluginName = 'chatq-ask'
$script:ChatqAskMarketName = 'chatq-local'

# what the phone is shown of a question - never what Claude gets, which is
# not cut at all. A question's parts past 16 KB lose their longest
# descriptions first, down to 300 characters.
$script:ChatqAskCaps = @{ Question = 2000; Header = 60; Label = 300; Description = 2000; Total = 16384; Squeeze = 300 }

function ConvertFrom-ChatqAskJson {
    # a transcript line or a request's questions, parsed: in pwsh 7.5 and
    # later with -DateKind String, since pwsh 7 turns a label that looks like
    # a time into [datetime] and back into other text. 5.1 never does; pwsh
    # 7.0-7.4 have no way to stop it (the hook itself runs in 5.1)
    param([string]$Text)
    if ($null -eq $script:ChatqAskDateKind) { $script:ChatqAskDateKind = [bool]((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) }
    if ($script:ChatqAskDateKind) { return ($Text | ConvertFrom-Json -DateKind String) }
    return ($Text | ConvertFrom-Json)
}

function ConvertTo-ChatqAskCut {
    # a text cut to -Max characters, never through a surrogate pair:
    # @{ S; Cut }
    param([string]$Text, [int]$Max)
    $t = [string]$Text
    if ($t.Length -le $Max) { return @{ S = $t; Cut = $false } }
    $n = $Max
    if ($n -gt 0 -and [char]::IsHighSurrogate($t[$n - 1])) { $n-- }
    return @{ S = $t.Substring(0, $n).TrimEnd() + $script:ChatqEllipsis; Cut = $true }
}

function ConvertTo-ChatqAskQuestions {
    <#
    The questions of a call's input, whole and in order: @(@{ t; h; m; o =
    @(@{ l; d }) }). What the phone is shown and what an answer is checked
    against both start here - Test-ChatqAskSame compares these, before any
    cut.
    #>
    param($CallInput)
    $qs = Get-ChatField $CallInput 'questions'
    return @(foreach ($q in @($qs)) {
            if (-not $q) { continue }
            @{
                t = [string](Get-ChatField $q 'question'); h = [string](Get-ChatField $q 'header'); m = [bool](Get-ChatField $q 'multiSelect')
                o = @(foreach ($o in @(Get-ChatField $q 'options')) { if ($o) { @{ l = [string](Get-ChatField $o 'label'); d = [string](Get-ChatField $o 'description') } } })
            }
        })
}

function Test-ChatqAskSame {
    <#
    Two sets of questions the same: as many questions, as many options in
    each, compared place by place - text, header, multiSelect, every label
    and description. Order counts: the phone answers by index.
    #>
    param([object[]]$A, [object[]]$B)
    $a = @($A); $b = @($B)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        $x = $a[$i]; $y = $b[$i]
        if ([string]$x.t -cne [string]$y.t -or [string]$x.h -cne [string]$y.h -or [bool]$x.m -ne [bool]$y.m) { return $false }
        $xo = @($x.o); $yo = @($y.o)
        if ($xo.Count -ne $yo.Count) { return $false }
        for ($j = 0; $j -lt $xo.Count; $j++) {
            if ([string]$xo[$j].l -cne [string]$yo[$j].l -or [string]$xo[$j].d -cne [string]$yo[$j].d) { return $false }
        }
    }
    return $true
}

function Get-ChatqAskShown {
    <#
    The questions as the phone is shown them: 4 questions of 4 options at
    most, the tool's own limits (More counts the rest), each part capped, and
    once the whole passes 16 KB the longest descriptions cut first, to 300.
    @{ Questions; More; Cut } - a question @{ t; h; m; o = @(@{ l; d; x }) },
    x set on an option whose text was cut.
    #>
    param([object[]]$Questions)
    $caps = $script:ChatqAskCaps
    $more = 0
    $cut = $false
    $qs = @($Questions)
    if ($qs.Count -gt 4) { $more += $qs.Count - 4; $qs = @($qs[0..3]) }
    $shown = [System.Collections.Generic.List[object]]::new()
    foreach ($q in $qs) {
        $os = @($q.o)
        if ($os.Count -gt 4) { $more += $os.Count - 4; $os = @($os[0..3]) }
        $t = ConvertTo-ChatqAskCut $q.t $caps.Question
        $h = ConvertTo-ChatqAskCut $q.h $caps.Header
        if ($t.Cut -or $h.Cut) { $cut = $true }
        $opts = [System.Collections.Generic.List[object]]::new()
        foreach ($o in $os) {
            $l = ConvertTo-ChatqAskCut $o.l $caps.Label
            $d = ConvertTo-ChatqAskCut $o.d $caps.Description
            $x = [ordered]@{ l = $l.S; d = $d.S }
            if ($l.Cut -or $d.Cut) { $x['x'] = 1; $cut = $true }
            $opts.Add($x)
        }
        $shown.Add([ordered]@{ h = $h.S; t = $t.S; m = [bool]$q.m; o = @($opts.ToArray()) })
    }
    # past the total: the longest description first, each cut once, until it
    # fits or none is left to cut - every pass cuts one it has not, so it ends
    $size = { $n = 0; foreach ($q in $shown) { $n += $q.t.Length + $q.h.Length; foreach ($o in $q.o) { $n += $o.l.Length + $o.d.Length } }; $n }
    $squeezed = @{}
    while ((& $size) -gt $caps.Total) {
        $long = $null
        foreach ($q in $shown) { foreach ($o in $q.o) { if (-not $squeezed.ContainsKey($o) -and $o.d.Length -gt $caps.Squeeze -and (-not $long -or $o.d.Length -gt $long.d.Length)) { $long = $o } } }
        if (-not $long) { break }
        $squeezed[$long] = $true
        $long.d = (ConvertTo-ChatqAskCut $long.d ($caps.Squeeze - 1)).S
        $long['x'] = 1
        $cut = $true
    }
    return @{ Questions = @($shown.ToArray()); More = $more; Cut = $cut }
}

function Get-ChatqPendingAsk {
    <#
    The question a Claude transcript is waiting on: the newest AskUserQuestion
    call that is not a side chain's, with no tool_result for it and no real
    prompt (Test-ChatqRealPrompt) after it. The tail is read - 1 MB, then 4 MB
    when that holds no assistant record at all. @{ ToolUseId; At; Mode;
    Questions (whole, ConvertTo-ChatqAskQuestions); Raw (the call's input as
    parsed) } or $null. Kept by path, length and write time. Never throws.
    #>
    param([string]$Path)
    try {
        if (-not $Path) { return $null }
        $fi = [System.IO.FileInfo]::new($Path)
        if (-not $fi.Exists) { return $null }
        $c = $script:ChatqAskCache[$Path]
        if ($c -and $c.Len -eq $fi.Length -and $c.Mtime -eq $fi.LastWriteTimeUtc.Ticks) { return $c.Result }
        $result = $null
        foreach ($size in 1MB, 4MB) {
            $t = Read-ChatqTail $Path $size
            if (-not $t) { break }
            $lines = $t -split "`n"
            # the first line of a tail is cut in two
            $start = if ($size -lt $fi.Length) { 1 } else { 0 }
            $sawAssistant = $false
            $found = -1
            $call = $null
            $rec = $null
            for ($i = $lines.Count - 1; $i -ge $start; $i--) {
                $l = $lines[$i]
                if ($l.IndexOf('"type":"assistant"', [StringComparison]::Ordinal) -lt 0) { continue }
                $sawAssistant = $true
                if ($l.IndexOf('"AskUserQuestion"', [StringComparison]::Ordinal) -lt 0) { continue }
                $o = try { ConvertFrom-ChatqAskJson $l } catch { $null }
                if (-not $o -or [string]$o.type -ne 'assistant' -or $o.isSidechain -eq $true -or -not $o.message) { continue }
                foreach ($b in @($o.message.content)) {
                    if ($b -and $b.type -eq 'tool_use' -and [string]$b.name -eq 'AskUserQuestion') { $call = $b }
                }
                if ($call) { $found = $i; $rec = $o; break }
            }
            if (-not $call) {
                if (-not $sawAssistant -and $size -lt $fi.Length) { continue }
                break
            }
            $id = [string]$call.id
            $open = $true
            for ($i = $found + 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($id -and $l.IndexOf('"type":"tool_result"', [StringComparison]::Ordinal) -ge 0 -and $l.IndexOf("`"$id`"", [StringComparison]::Ordinal) -ge 0) { $open = $false; break }
                if (Test-ChatqRealPrompt $l) { $open = $false; break }
            }
            if ($open) {
                $result = [pscustomobject]@{
                    ToolUseId = $id; At = (ConvertTo-ChatqDate $rec.timestamp); Mode = (Get-ChatJsonString $t 'permissionMode')
                    Questions = @(ConvertTo-ChatqAskQuestions $call.input); Raw = $call.input
                }
            }
            break
        }
        $script:ChatqAskCache[$Path] = @{ Len = $fi.Length; Mtime = $fi.LastWriteTimeUtc.Ticks; Result = $result }
        return $result
    }
    catch { return $null }
}

function Get-ChatqAskView {
    <#
    What the board's open row and a needs input alert's page carry about a
    question the chat waits on: @{ k; at; more; cut; q } - k the call id's
    last 12, q the questions as Get-ChatqAskShown gives them - or $null when
    nothing is pending. Then whether the phone may answer it: can, with the
    request's rid, its digest qh and until; or can false and why (spec 5.1)
    - off, hook, term, cli, mode, busy, late - with what the words need.
    -Path is the chat's own transcript, found from its id: never one a
    request names. -Rc: the reply config, read when not given. -Requests:
    data/ask/ as read once for a whole board.
    #>
    param([string]$SessionId, [string]$Path, $Rc, $Cfg, [object[]]$Requests)
    $p = Get-ChatqPendingAsk $Path
    if (-not $p -or -not @($p.Questions).Count) { return $null }
    $s = Get-ChatqAskShown $p.Questions
    $id = [string]$p.ToolUseId
    $v = [ordered]@{
        k = $(if ($id.Length -gt 12) { $id.Substring($id.Length - 12) } else { $id })
        at = $(if ($p.At) { $p.At.ToUniversalTime().ToString('o') } else { $null })
        more = [int]$s.More; cut = [bool]$s.Cut; q = @($s.Questions)
    }
    try {
        if (-not $Cfg) { $Cfg = Get-ChatqConfig }
        if (-not $Rc) { $Rc = Get-ChatqReplyConfig $Cfg }
        if (-not (Get-ChatqAskConfig $Cfg).On -or -not $Rc.Links -or -not (Test-ChatqLinkChannel $Cfg)) { $v['can'] = $false; $v['why'] = 'off'; return $v }
        $req = Get-ChatqAskMatch $SessionId $p $Requests
        if (-not $req) { $v['can'] = $false; $v['why'] = 'hook'; return $v }
        $until = ConvertTo-ChatqDate $req.until
        $state = [string]$req.state
        if ($state -eq 'declined') {
            $v['can'] = $false; $v['why'] = [string]$req.why
            if ($req.why -eq 'mode') { $v['mode'] = [string]$req.mode; $v['cap'] = [string]$Rc.MaxMode }
            if ($req.why -eq 'cli') { $v['cli'] = [string]$req.cli }
            return $v
        }
        if ($state -eq 'open' -and $until -and $until -gt (Get-Date) -and (Test-ChatqAskHookAlive $req)) {
            $v['can'] = $true; $v['rid'] = [string]$req.rid
            $v['qh'] = Get-ChatqAskDigest ([string]$req.rid) ([string]$req.session) ([string]$req.questionsRaw)
            $v['until'] = $until.ToUniversalTime().ToString('o')
            return $v
        }
        $v['can'] = $false; $v['why'] = 'late'
        if ($until) { $v['until'] = $until.ToUniversalTime().ToString('o') }
    }
    catch { $v['can'] = $false; $v['why'] = 'hook' }
    return $v
}

function Get-ChatqAskWhat {
    # a waiting row's few words for a question: "a question: Stability log",
    # "2 questions: Reach, Repoint" - the headers, else the question cut short
    param($View)
    $qs = @($View.q)
    if (-not $qs.Count) { return '' }
    $names = @(foreach ($q in $qs) { if ($q.h) { [string]$q.h } else { Get-ChatqBoardLine ([string]$q.t) 40 } })
    if ($qs.Count -eq 1) { return "a question: $($names[0])" }
    return "$($qs.Count) questions: $($names -join ', ')"
}

function Get-ChatqAskTranscript {
    # where Claude Code keeps a chat's transcript, from its folder and id -
    # the chat's own, never a path something else named (-HomeDir: its
    # config dir, the default one when $null)
    param([string]$SessionId, [string]$Cwd, $HomeDir)
    if (-not $SessionId -or -not $Cwd) { return $null }
    $ch = if ($HomeDir) { [string]$HomeDir } else { $script:ChatClaudeHome }
    $p = Join-Path (Join-Path (Join-Path $ch 'projects') (Get-ChatSlug $Cwd)) "$SessionId.jsonl"
    if (Test-Path -LiteralPath $p) { return $p }
    try { return (Find-ChatOverlayTranscript $ch $Cwd $SessionId) } catch { return $null }
}

#region answering: the request, the answer, the decision

function Get-ChatqAskConfig {
    # config.json's ask block with its defaults: On (off unless switched on),
    # WaitMinutes (240; 5 to 720), MaxOpen (5; questions held at once, one
    # hidden PowerShell each)
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $a = if ($Cfg -and $Cfg.PSObject.Properties['ask'] -and $Cfg.ask) { $Cfg.ask } else { [pscustomobject]@{} }
    $g = { param($n) if ($a.PSObject.Properties[$n]) { $a.$n } else { $null } }
    $wait = (& $g 'waitMinutes') -as [int]
    if (-not $wait -or $wait -lt 5 -or $wait -gt 720) { $wait = 240 }
    $max = (& $g 'maxOpen') -as [int]
    if (-not $max -or $max -lt 1 -or $max -gt 20) { $max = 5 }
    [pscustomobject]@{ On = ((& $g 'on') -eq $true); WaitMinutes = $wait; MaxOpen = $max; Manual = ((& $g 'manual') -eq $true) }
}

function Write-ChatqAskLog {
    # data/logs/ask.log, rolled at 1 MB: the hook's side of every question
    param([string]$Text)
    try {
        Add-ChatqLogLine 'ask.log' "[$PID] $($Text -replace '[\r\n]+', ' ')"
    }
    catch {}
}

function Get-ChatqAskDigest {
    # what binds an answer to one question: b64url of the first 16 bytes of
    # SHA-256 over the request id, the chat and the questions as Claude sent
    # them - raw, never re-serialized
    param([string]$Rid, [string]$SessionId, [string]$QuestionsRaw)
    $u = New-Object System.Text.UTF8Encoding $false
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($u.GetBytes("chatq-ask`n$Rid`n$SessionId`n$QuestionsRaw")) } finally { $sha.Dispose() }
    return (ConvertTo-ChatqB64Url ([byte[]]$h[0..15]))
}

function ConvertTo-ChatqJsonString {
    # one JSON string: only the quote, the backslash and the control
    # characters escaped - Hangul, < > & and ' as they are. ConvertTo-Json
    # in 5.1 writes those four as \u escapes.
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($c in $Text.ToCharArray()) {
        switch ([int]$c) {
            0x22 { [void]$sb.Append('\"') }
            0x5C { [void]$sb.Append('\\') }
            0x0A { [void]$sb.Append('\n') }
            0x0D { [void]$sb.Append('\r') }
            0x09 { [void]$sb.Append('\t') }
            default { if ([int]$c -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) } }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-ChatqAskQuestionsOf {
    # the questions of a request's raw JSON, parsed as a transcript's are
    param([string]$QuestionsRaw)
    if (-not $QuestionsRaw) { return @() }
    $o = try { ConvertFrom-ChatqAskJson ('{"questions":' + $QuestionsRaw + '}') } catch { $null }
    if (-not $o) { return @() }
    return @(ConvertTo-ChatqAskQuestions $o)
}

function ConvertTo-ChatqAskAnswers {
    <#
    The phone's answer - a: one array per question of the options chosen, by
    index; o: one Other text per question - checked against the questions
    and turned into the answers Claude reads, as the VS Code dialog writes
    them: per question the chosen labels in option order, then the Other
    text, joined with ", ". The labels are taken from the questions, never
    from the phone. A single choice: exactly one option, or none and Other.
    A multiple choice: at least one of either. Other text: control and
    format characters made spaces, 500 characters at most. @{ Ok; Why;
    Answers } - Answers ordered, question text -> answer.
    #>
    param([object[]]$Questions, $A, $O)
    $r = [pscustomobject]@{ Ok = $false; Why = $null; Answers = $null }
    $qs = @($Questions)
    $aa = @($A)
    $oo = @($O)
    if (-not $qs.Count) { $r.Why = 'no questions'; return $r }
    if ($null -eq $A -or $aa.Count -ne $qs.Count) { $r.Why = 'not one answer per question'; return $r }
    if ($null -ne $O -and $oo.Count -ne $qs.Count) { $r.Why = 'not one Other per question'; return $r }
    # question texts that differ only in case are two questions: ordinal keys
    $out = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $qs.Count; $i++) {
        $q = $qs[$i]
        $n = @($q.o).Count
        $idx = [System.Collections.Generic.List[int]]::new()
        foreach ($x in @($aa[$i])) {
            if ($null -eq $x) { continue }
            if (-not ($x -is [int] -or $x -is [long] -or $x -is [int16] -or $x -is [byte])) { $r.Why = "question $($i + 1): an index that is not a number"; return $r }
            $k = [int]$x
            if ($k -lt 0 -or $k -ge $n) { $r.Why = "question $($i + 1): option $k is not there"; return $r }
            if ($idx.Count -and $k -le $idx[$idx.Count - 1]) { $r.Why = "question $($i + 1): options not in order, or twice"; return $r }
            $idx.Add($k)
        }
        $other = if ($null -ne $O -and $null -ne $oo[$i]) { (([string]$oo[$i]) -replace '[\p{Cc}\p{Cf}]', ' ').Trim() } else { '' }
        $other = Limit-ChatqText $other 500
        if ($q.m) {
            if (-not $idx.Count -and -not $other) { $r.Why = "question $($i + 1) has no answer"; return $r }
        }
        elseif (($idx.Count + [int][bool]$other) -ne 1) { $r.Why = "question $($i + 1) takes one answer"; return $r }
        $parts = @(foreach ($k in $idx) { [string]$q.o[$k].l })
        if ($other) { $parts += $other }
        $out[[string]$q.t] = ($parts -join ', ')
    }
    $r.Ok = $true
    $r.Answers = $out
    return $r
}

function New-ChatqAskDecision {
    # the one line the hook prints: allow, with the questions spliced back in
    # byte for byte as Claude sent them and the answers beside them - never a
    # deny, never a permission added
    param([string]$QuestionsRaw, [System.Collections.IDictionary]$Answers)
    $pairs = @(foreach ($k in $Answers.Keys) { (ConvertTo-ChatqJsonString ([string]$k)) + ':' + (ConvertTo-ChatqJsonString ([string]$Answers[$k])) })
    return '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"questions":' +
    $QuestionsRaw + ',"answers":{' + ($pairs -join ',') + '}}}}}'
}

function Test-ChatqAskAnswer {
    <#
    The phone's answer as the watcher dropped it (<rid>.ans.json), opened
    here with the phone's key as it is now: from an alert's page (chatq1) or
    the board (chatq3c). Believed only when it verifies - act answer, this
    request's own rid and digest, a time between the ask and the deadline
    (a minute's slack each side), a nonce not taken before, and an answer to
    every question. -Req is the hook's own record, in its memory - never the
    request file, which anything can write. @{ Ok; Answers; Why }.
    #>
    param($Req, $Ans, [byte[]]$Master, $State)
    $r = [pscustomobject]@{ Ok = $false; Answers = $null; Why = $null }
    $raw = [string](Get-ChatField $Ans 'raw')
    $v = if ($raw.StartsWith('chatq3c.')) { Unprotect-ChatqComposeMessage $raw $Master } else { Unprotect-ChatqReplyMessage $raw $Master }
    if (-not $v.Ok) { $r.Why = "not sealed by the phone ($($v.Stage): $($v.Error))"; return $r }
    $pl = $v.Payload
    if ([string]$pl.act -ne 'answer') { $r.Why = "act $($pl.act)"; return $r }
    if ([string]$pl.rid -cne $Req.Rid) { $r.Why = 'another question''s answer'; return $r }
    if ([string]$pl.qh -cne $Req.Digest) { $r.Why = 'the question changed after it was shown'; return $r }
    $ts = $pl.ts -as [double]
    $lo = [DateTimeOffset]::new($Req.At).ToUnixTimeMilliseconds() - 60000
    $hi = [DateTimeOffset]::new($Req.Until).ToUnixTimeMilliseconds() + 60000
    if ($null -eq $ts -or $ts -lt $lo -or $ts -gt $hi) { $r.Why = 'sent outside the question''s time'; return $r }
    $nonce = [string]$pl.nonce
    if (-not $nonce -or $State.Nonces.ContainsKey($nonce)) { $r.Why = 'a nonce used before'; return $r }
    $State.Nonces[$nonce] = $true
    $c = ConvertTo-ChatqAskAnswers $Req.Questions $pl.a $pl.o
    if (-not $c.Ok) { $r.Why = $c.Why; return $r }
    $r.Ok = $true
    $r.Answers = $c.Answers
    return $r
}

function Get-ChatqAskRequests {
    # every request in data/ask/, each with its file's Path; one that does not
    # read is left out
    if (-not (Test-Path -LiteralPath $script:ChatqAskDir)) { return @() }
    return @(foreach ($f in @(Get-ChildItem -LiteralPath $script:ChatqAskDir -Filter '*.req.json' -File -EA SilentlyContinue)) {
            $o = Read-ChatqJson $f.FullName
            if (-not $o -or -not $o.rid) { continue }
            Add-Member -InputObject $o -NotePropertyName 'Path' -NotePropertyValue $f.FullName -Force
            $o
        })
}

function Test-ChatqAskHookAlive {
    <#
    Is a request's hook still there to take an answer: a Windows PowerShell
    (or pwsh) with that pid, started in the two minutes before the request
    was made, whose command line names ask-hook.ps1. The start and the
    command line both: Windows reuses a pid within minutes. Kept per pid and
    start, since CIM is slow.
    #>
    param($Req)
    if ($script:ChatqAskAliveSeam) { return [bool](& $script:ChatqAskAliveSeam $Req) }   # tests
    $hp = (Get-ChatField $Req 'hookPid') -as [int]
    $at = ConvertTo-ChatqDate (Get-ChatField $Req 'at')
    if (-not $hp -or -not $at) { return $false }
    $pr = Get-Process -Id $hp -EA SilentlyContinue
    if (-not $pr -or $pr.ProcessName -notmatch '^(powershell|pwsh)$') { return $false }
    $st = try { $pr.StartTime } catch { $null }
    if (-not $st -or $st -gt $at.AddSeconds(5) -or $st -lt $at.AddMinutes(-2)) { return $false }
    $key = "$hp|$($st.Ticks)"
    if ($script:ChatqAskAliveCache.ContainsKey($key)) { return $script:ChatqAskAliveCache[$key] }
    # only a definite answer is kept: a CIM that failed once asks again next
    # time, never marks a live hook dead for the watcher's whole life
    $cim = try { Get-CimInstance Win32_Process -Filter "ProcessId=$hp" -EA Stop } catch { $null }
    if (-not $cim) { return $false }
    $ok = [bool](([string]$cim.CommandLine) -like '*ask-hook.ps1*')
    $script:ChatqAskAliveCache[$key] = $ok
    return $ok
}

function Get-ChatqAskMatch {
    <#
    The request that stands for a pending question, whatever its state: of
    this session, its questions equal the call's (Test-ChatqAskSame, place by
    place), its tool_use id the call's when it has one - else made at or
    after the call - the newest of them. $null when none.
    #>
    param([string]$SessionId, $Pending, [object[]]$Requests)
    if (-not $Pending) { return $null }
    if ($null -eq $Requests) { $Requests = @(Get-ChatqAskRequests) }
    $best = $null
    $bestAt = $null
    foreach ($q in @($Requests)) {
        if (-not $q -or [string]$q.session -ne $SessionId) { continue }
        $tid = [string](Get-ChatField $q 'toolUseId')
        $at = ConvertTo-ChatqDate $q.at
        if ($tid) { if ($tid -ne [string]$Pending.ToolUseId) { continue } }
        elseif ($Pending.At -and $at -and $at -lt $Pending.At.AddSeconds(-5)) { continue }
        if (-not (Test-ChatqAskSame (Get-ChatqAskQuestionsOf ([string]$q.questionsRaw)) $Pending.Questions)) { continue }
        if (-not $best -or ($at -and $bestAt -and $at -gt $bestAt)) { $best = $q; $bestAt = $at }
    }
    return $best
}

function Set-ChatqAskState {
    # a request's state moved on, written back: the hook's own changes, and
    # the watcher's gone and timeout. -From: only while the file still says
    # that - the watcher moves a request that is still open, never one the
    # hook has answered since it looked
    param($Req, [string]$State, [hashtable]$More, [string]$From)
    try {
        $p = [string](Get-ChatField $Req 'Path')
        if (-not $p) { $p = Join-Path $script:ChatqAskDir "$($Req.rid).req.json" }
        $o = Read-ChatqJson $p
        if (-not $o) { return }
        if ($From -and [string]$o.state -ne $From) { return }
        Set-ChatqProp $o 'state' $State
        Set-ChatqProp $o 'changedAt' (Get-ChatqStamp)
        if ($More) { foreach ($k in $More.Keys) { Set-ChatqProp $o $k $More[$k] } }
        Save-ChatqJson $p $o
    }
    catch {}
}

#endregion

#region the hook

function Read-ChatqAskStdin {
    # all of the hook's stdin, 256 KB at most, as UTF-8 - a byte-order mark
    # in front dropped: a parent on .NET Framework writes one first
    $in = [Console]::OpenStandardInput()
    $ms = [System.IO.MemoryStream]::new()
    $buf = [byte[]]::new(65536)
    while ($ms.Length -lt 262144) {
        $n = $in.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
    }
    return ([System.Text.Encoding]::UTF8.GetString($ms.ToArray())).TrimStart([char]0xFEFF)
}

function Write-ChatqAskStdout {
    # the decision, as UTF-8 bytes on the raw stream: nothing else ever goes
    # to stdout, and the console's code page has no say
    param([string]$Line)
    $b = (New-Object System.Text.UTF8Encoding $false).GetBytes($Line)
    $s = [Console]::OpenStandardOutput()
    $s.Write($b, 0, $b.Length)
    $s.Flush()
}

function Get-ChatqAskClaudeHome {
    # the config dir of the chat that ran the hook: the hook has claude's
    # own environment
    if ($env:CLAUDE_CONFIG_DIR) { return [string]$env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

function Test-ChatqAskGates {
    <#
    Whether the phone may answer this question (spec 5.1), in order, the
    first that fails deciding. @{ Ok; Silent; Why; Entry; Extra }: Silent -
    nothing is written, the dialog is all there is (off, a session chatq
    cannot see); else a declined request says Why to the page. -Stdin is
    the hook's input, parsed.
    #>
    param($Stdin, [string]$QuestionsRaw, $Cfg, [string]$ClaudeHome, [datetime]$Now = (Get-Date))
    $no = { param($w, [switch]$Silent, $Extra) [pscustomobject]@{ Ok = $false; Silent = [bool]$Silent; Why = $w; Entry = $null; Extra = $Extra } }
    if ([string]$Stdin.hook_event_name -ne 'PermissionRequest' -or [string]$Stdin.tool_name -ne 'AskUserQuestion' -or -not $QuestionsRaw) { return (& $no 'not a question' -Silent) }
    $ac = Get-ChatqAskConfig $Cfg
    $rc = Get-ChatqReplyConfig $Cfg
    if (-not $ac.On -or -not $rc.Links -or -not (Test-ChatqLinkChannel $Cfg)) { return (& $no 'off' -Silent) }
    $sid = [string]$Stdin.session_id
    $entry = @(Read-ChatqSessionRegistry (Join-Path $ClaudeHome 'sessions') | Where-Object { $_.SessionId -eq $sid -and (Test-ChatqSessionAlive $_) }) | Select-Object -First 1
    if (-not $entry) { return (& $no 'no registered session' -Silent) }
    $r = & $no $null
    $r.Entry = $entry
    if ([string]$entry.Entrypoint -ne 'claude-vscode') { $r.Why = 'term'; return $r }
    if (-not $entry.Version -or (Compare-ChatVersion ([string]$entry.Version) $script:ChatqAskMin) -lt 0) { $r.Why = 'cli'; $r.Extra = @{ cli = [string]$entry.Version }; return $r }
    $mode = [string]$Stdin.permission_mode
    if ((Get-ChatqModeRank $mode) -gt (Get-ChatqModeRank $rc.MaxMode)) { $r.Why = 'mode'; $r.Extra = @{ mode = $mode }; return $r }
    $reqs = @(Get-ChatqAskRequests)
    $open = @($reqs | Where-Object { [string]$_.state -eq 'open' -and (ConvertTo-ChatqDate $_.until) -gt $Now -and (Test-ChatqAskHookAlive $_) }).Count
    $hour = @($reqs | Where-Object { (ConvertTo-ChatqDate $_.at) -gt $Now.AddHours(-1) }).Count
    if ($open -ge $ac.MaxOpen -or $hour -ge 30) { $r.Why = 'busy'; return $r }
    $r.Ok = $true
    return $r
}

function Start-ChatqAskHook {
    <#
    The PermissionRequest hook, matcher AskUserQuestion (src/ask-hook.ps1
    starts it): one question, held for the phone beside the dialog. Reads
    its stdin, checks the gates (Test-ChatqAskGates), finds its own call in
    the chat's transcript, writes <rid>.req.json and waits, a step a second,
    for the phone's answer; or for the question gone - answered at the PC,
    Esc, a prompt after it - claude gone, its deadline, or answers from the
    phone switched off. A verified answer is the one line it prints. Never
    throws; returns what became of the question, for the log.
    Tests: $env:CHATQ_ASK_WAIT_SECONDS for the deadline, $env:CHATQ_ASK_STEP_MS
    for the step.
    #>
    $end = 'none'
    try {
        $text = Read-ChatqAskStdin
        $in = try { ConvertFrom-ChatqAskJson $text } catch { $null }
        $qRaw = if ($in) { Get-ChatqJsonRaw $text 'tool_input.questions' } else { $null }
        # the write time before the read: a pairing or a switch changed while
        # this starts up is seen at the first look
        $cfgStamp = try { [System.IO.File]::GetLastWriteTimeUtc($script:ChatqConfigPath).Ticks } catch { 0 }
        $cfg = Get-ChatqConfig
        $cHome = Get-ChatqAskClaudeHome
        $now = Get-Date
        $rid = New-ChatqRandomName 10
        if (-not $in) { Write-ChatqAskLog "hook: stdin did not read"; return 'unread' }
        $sid = [string]$in.session_id
        $gate = Test-ChatqAskGates $in $qRaw $cfg $cHome $now
        if ($gate.Silent) { Write-ChatqAskLog "hook $sid - $($gate.Why): the dialog alone"; return $gate.Why }
        $questions = @(Get-ChatqAskQuestionsOf $qRaw)
        $ac = Get-ChatqAskConfig $cfg
        $waitSec = ($env:CHATQ_ASK_WAIT_SECONDS -as [int])
        $until = if ($waitSec -gt 0) { $now.AddSeconds($waitSec) } else { $now.AddMinutes($ac.WaitMinutes) }
        $digest = Get-ChatqAskDigest $rid $sid $qRaw
        $entry = $gate.Entry
        New-ChatqDir $script:ChatqAskDir
        $path = Join-Path $script:ChatqAskDir "$rid.req.json"
        $req = [ordered]@{
            v = 1; rid = $rid; state = 'open'; why = $null; session = $sid; cwd = [string]$entry.Cwd; mode = [string]$in.permission_mode
            questionsRaw = $qRaw; toolUseId = $null; qh = $digest; at = $now.ToUniversalTime().ToString('o'); until = $until.ToUniversalTime().ToString('o')
            hookPid = $PID; cliPid = [int]$entry.Pid; cliStart = $entry.ProcStart; changedAt = (Get-ChatqStamp)
        }
        if (-not $gate.Ok) {
            $req.state = 'declined'
            $req.why = $gate.Why
            if ($gate.Extra) { foreach ($k in $gate.Extra.Keys) { $req[$k] = $gate.Extra[$k] } }
            Save-ChatqJson $path $req
            Write-ChatqAskLog "hook $rid $sid - declined: $($gate.Why)"
            return "declined $($gate.Why)"
        }
        # the chat's own transcript, from its id - the one stdin names only
        # when they agree
        $tp = Get-ChatqAskTranscript $sid ([string]$entry.Cwd) $cHome
        $given = [string]$in.transcript_path
        if ($given -and $tp -and -not [string]::Equals([System.IO.Path]::GetFullPath($given), [System.IO.Path]::GetFullPath($tp), [StringComparison]::OrdinalIgnoreCase)) {
            Write-ChatqAskLog "hook $rid - stdin names $given, the chat's own is ${tp} - that one is read"
        }
        if (-not $tp) { $tp = $given }
        $mine = @{ Rid = $rid; Digest = $digest; Questions = $questions; At = $now; Until = $until; Session = $sid; Raw = $qRaw }
        $step = ($env:CHATQ_ASK_STEP_MS -as [int]); if (-not $step -or $step -lt 20) { $step = 1000 }
        # its own call in the transcript: it may land just after the hook starts
        $toolUseId = $null
        $findUntil = (Get-Date).AddSeconds(10)
        while ($true) {
            $script:ChatqAskCache = @{}
            $p = Get-ChatqPendingAsk $tp
            if ($p -and (Test-ChatqAskSame $p.Questions $questions)) { $toolUseId = [string]$p.ToolUseId; break }
            if ((Get-Date) -ge $findUntil) { break }
            Start-Sleep -Milliseconds ([Math]::Min($step, 500))
        }
        $req.toolUseId = $toolUseId
        Save-ChatqJson $path $req
        Write-ChatqAskLog "hook $rid $sid - holding $(@($questions).Count) question(s)$(if ($toolUseId) { " ($toolUseId)" } else { ', its call not found in the transcript' }) until $($until.ToString('HH:mm'))"
        $state = @{ Nonces = @{} }
        $ansPath = Join-Path $script:ChatqAskDir "$rid.ans.json"
        $key = (Get-ChatqReplyConfig $cfg).Master
        $lastLook = Get-Date
        $lastCfg = [datetime]::MinValue
        $badSeen = @{}
        while ($true) {
            Start-Sleep -Milliseconds $step
            $t = Get-Date
            if (Test-Path -LiteralPath $ansPath) {
                $ans = Read-ChatqJson $ansPath
                $sig = if ($ans) { [string]$ans.raw } else { '' }
                if ($ans -and -not $badSeen.ContainsKey($sig)) {
                    $chk = Test-ChatqAskAnswer $mine $ans $key $state
                    if ($chk.Ok) {
                        # the mode is the one stdin gave as the question came:
                        # nothing written while it waits says the mode (the
                        # transcript has it on typed prompts only), so a change
                        # at the PC meanwhile is not seen (FUTURE_WORK)
                        Write-ChatqAskStdout (New-ChatqAskDecision $qRaw $chk.Answers)
                        Set-ChatqAskState $req 'answered' @{ answeredAt = (Get-ChatqStamp) }
                        Write-ChatqAskLog "hook $rid - answered from the phone"
                        return 'answered'
                    }
                    $badSeen[$sig] = $true
                    Set-ChatqAskState $req 'open' @{ badAnswer = $chk.Why }
                    Write-ChatqAskLog "hook $rid - an answer not taken: $($chk.Why)"
                }
            }
            if ($t -ge $until) { Set-ChatqAskState $req 'timeout'; Write-ChatqAskLog "hook $rid - the phone's time is up; the dialog stays"; return 'timeout' }
            if (($t - $lastLook).TotalSeconds -ge 5) {
                $lastLook = $t
                $alive = Get-Process -Id ([int]$entry.Pid) -EA SilentlyContinue
                if (-not $alive -or -not (Test-ChatqClaudeProcess $alive $entry.ProcStart)) { Set-ChatqAskState $req 'gone'; Write-ChatqAskLog "hook $rid - claude is gone"; return 'gone' }
                $script:ChatqAskCache = @{}
                $p = Get-ChatqPendingAsk $tp
                $still = if ($toolUseId) { [bool]($p -and [string]$p.ToolUseId -eq $toolUseId) } else { [bool]($p -and (Test-ChatqAskSame $p.Questions $questions)) }
                if (-not $still) { Set-ChatqAskState $req 'pc'; Write-ChatqAskLog "hook $rid - answered at the PC"; return 'pc' }
            }
            if (($t - $lastCfg).TotalSeconds -ge 10) {
                $lastCfg = $t
                $stamp = try { [System.IO.File]::GetLastWriteTimeUtc($script:ChatqConfigPath).Ticks } catch { 0 }
                if ($stamp -ne $cfgStamp) {
                    $cfgStamp = $stamp
                    $c2 = Get-ChatqConfig
                    $rc2 = Get-ChatqReplyConfig $c2
                    if (-not (Get-ChatqAskConfig $c2).On -or -not $rc2.Links -or -not (Test-ChatqSameBytes $rc2.Master $key)) {
                        Set-ChatqAskState $req 'off'
                        Write-ChatqAskLog "hook $rid - answers from the phone switched off, or the phone paired again"
                        return 'off'
                    }
                }
            }
        }
    }
    catch { Write-ChatqAskLog "hook failed: $($_.Exception.Message)"; $end = 'failed' }
    return $end
}

#endregion

#region the watcher's side: the phone's answer, whether it landed, tidying

function Invoke-ChatqAskReply {
    <#
    The phone's answer to a question, from an alert's page or the board,
    after the watcher opened and checked the message: dropped beside its
    request as posted (<rid>.ans.json) for the hook, which opens it again.
    Nothing is taken from the request without checking it against the chat
    itself: the transcript is -Transcript, the chat's own, found from its id;
    its pending call must be the request's; the request's digest is made
    again; its hook must be alive. @{ Ok; Say }.
    #>
    param($Payload, [string]$SessionId, [string]$Transcript, [string]$Raw, [string]$Via, $Rc, [string]$Title)
    $no = { param($s) [pscustomobject]@{ Ok = $false; Say = $s } }
    if (-not $Rc) { $Rc = Get-ChatqReplyConfig }
    $cfg = Get-ChatqConfig
    if (-not (Get-ChatqAskConfig $cfg).On) { return (& $no 'nothing answered - the PC takes no answers from the phone (chatnotify -Ask on)') }
    $rid = [string]$Payload.rid
    $held = 'that question is no longer held - answer it at the PC'
    $path = Join-Path $script:ChatqAskDir "$rid.req.json"
    if ($rid -cnotmatch '^[a-z2-7]{10}$' -or -not (Test-Path -LiteralPath $path)) { return (& $no $held) }
    $req = Read-ChatqJson $path
    if (-not $req) { return (& $no $held) }
    Add-Member -InputObject $req -NotePropertyName 'Path' -NotePropertyValue $path -Force
    if ([string]$req.session -ne $SessionId) { Write-ChatqReplyLog "ask $rid - an answer for another chat's question"; return (& $no $held) }
    $until = ConvertTo-ChatqDate $req.until
    $late = "too late - the phone could answer until $(if ($until) { $until.ToString('HH:mm') } else { '?' }); answer it at the PC"
    switch ([string]$req.state) {
        'pc' { return (& $no 'already answered at the PC') }
        'answered' { $a = ConvertTo-ChatqDate $req.answeredAt; return (& $no "already answered - from the phone at $(if ($a) { $a.ToString('HH:mm') } else { '?' })") }
        'declined' { return (& $no "not answered - $([string]$req.why) (see the page)") }
        'open' {}
        default { return (& $no $late) }
    }
    if (-not $until -or $until -le (Get-Date)) { return (& $no $late) }
    if (-not (Test-ChatqAskHookAlive $req)) { Set-ChatqAskState $req 'gone' -From 'open'; return (& $no $late) }
    if ([string]$Payload.qh -cne (Get-ChatqAskDigest $rid ([string]$req.session) ([string]$req.questionsRaw))) {
        Write-ChatqReplyLog "ask $rid - the digest does not match"
        return (& $no 'that question changed after it was shown - nothing sent')
    }
    $script:ChatqAskCache = @{}
    $pending = Get-ChatqPendingAsk $Transcript
    $qs = @(Get-ChatqAskQuestionsOf ([string]$req.questionsRaw))
    if (-not $pending -or -not (Test-ChatqAskSame $pending.Questions $qs) -or ($req.toolUseId -and [string]$req.toolUseId -ne [string]$pending.ToolUseId)) {
        return (& $no 'that chat is not waiting on that question any more')
    }
    $c = ConvertTo-ChatqAskAnswers $qs $Payload.a $Payload.o
    if (-not $c.Ok) { return (& $no "answer every question - nothing sent ($($c.Why))") }
    Save-ChatqJson (Join-Path $script:ChatqAskDir "$rid.ans.json") ([ordered]@{ v = 1; rid = $rid; via = $Via; raw = $Raw; at = (Get-ChatqStamp) })
    $script:ChatqAskSent[$rid] = @{ Rid = $rid; At = (Get-Date); ToolUseId = [string]$pending.ToolUseId; Answers = $c.Answers; Transcript = $Transcript; SessionId = $SessionId; Title = $Title }
    Write-ChatqReplyLog "ask $rid - answer sent to the hook ($Via)"
    return [pscustomobject]@{ Ok = $true; Say = "sent your answer to $(if ($Title) { $Title } else { 'the chat' }) - it goes on, unless it was answered at the PC first" }
}

function Get-ChatqAskResult {
    # the tool_result a transcript holds for one call: @{ Found; Answers }
    # - Answers its toolUseResult's, $null when it has none
    param([string]$Path, [string]$ToolUseId)
    $r = [pscustomobject]@{ Found = $false; Answers = $null }
    if (-not $Path -or -not $ToolUseId) { return $r }
    $t = Read-ChatqTail $Path 4MB
    if (-not $t) { return $r }
    foreach ($l in ($t -split "`n")) {
        if ($l.IndexOf('"tool_result"', [StringComparison]::Ordinal) -lt 0 -or $l.IndexOf("`"$ToolUseId`"", [StringComparison]::Ordinal) -lt 0) { continue }
        $o = try { ConvertFrom-ChatqAskJson $l } catch { $null }
        if (-not $o -or [string]$o.type -ne 'user') { continue }
        $r.Found = $true
        $tr = Get-ChatField $o 'toolUseResult'
        $a = if ($tr) { Get-ChatField $tr 'answers' } else { $null }
        if ($a) {
            $m = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
            foreach ($p in $a.PSObject.Properties) { $m[$p.Name] = [string]$p.Value }
            $r.Answers = $m
        }
    }
    return $r
}

function Test-ChatqAskLanded {
    <#
    Did each answer the phone sent land: 20 s on, the transcript's
    tool_result for that call. None yet - the chat did not take it; its
    answers the phone's - landed; other answers - the PC's won; none at all -
    the chat went on without it. The first and the last are pushed: the
    undocumented part of this (spec S46) fails loudly, never quietly. Each
    looked at once, or dropped after 10 minutes. -Now is for the tests.
    Returns what it found, rid -> outcome.
    #>
    param([datetime]$Now = (Get-Date), [switch]$Quick)
    $out = @{}
    foreach ($rid in @($script:ChatqAskSent.Keys)) {
        $e = $script:ChatqAskSent[$rid]
        $age = ($Now - $e.At).TotalSeconds
        if ($age -lt 20) { continue }
        $script:ChatqAskSent.Remove($rid)
        $res = Get-ChatqAskResult $e.Transcript $e.ToolUseId
        $name = if ($e.Title) { [string]$e.Title } else { 'the chat' }
        $say = $null
        if (-not $res.Found) {
            # the hook's own word first: one that held the answer back is not
            # the CLI failing, and is said as what it is
            $q = Read-ChatqJson (Join-Path $script:ChatqAskDir "$rid.req.json")
            $st = if ($q) { [string]$q.state } else { '' }
            $bad = if ($q) { [string](Get-ChatField $q 'badAnswer') } else { '' }
            if ($st -in 'declined', 'timeout', 'gone', 'off') { $out[$rid] = "held back ($st)"; $say = "$name was not answered from the phone ($st) - answer it at the PC" }
            elseif ($st -eq 'open' -and $bad) { $out[$rid] = 'refused by the hook'; $say = "$name did not take the answer from the phone ($bad) - answer it at the PC" }
            else { $out[$rid] = 'not taken'; $say = "$name did not take the answer from the phone - answer it at the PC" }
        }
        else {
            # an answer for every question, as the phone sent it - landed; one
            # for every question, not the phone's - the PC's; a question with
            # no answer at all - the chat went on without one (2.1.283 does
            # that for answers keyed to no question: S46 item 7)
            $all = $true
            $same = $true
            foreach ($k in $e.Answers.Keys) {
                if (-not $res.Answers -or -not $res.Answers.Contains($k)) { $all = $false }
                elseif ([string]$res.Answers[$k] -cne [string]$e.Answers[$k]) { $same = $false }
            }
            if (-not $all) { $out[$rid] = 'dropped'; $say = "$name went on without your answer - check it at the PC" }
            else { $out[$rid] = if ($same) { 'landed' } else { 'pc first' } }
        }
        Write-ChatqReplyLog "ask $rid $name`: $($out[$rid])"
        if ($say) {
            $job = ConvertTo-ChatqLiveJob @{ sessionId = $e.SessionId; title = $e.Title; path = $e.Transcript }
            [void](Send-ChatqAlert 'reply' $say 1 -Loud -Job $job -Quick:$Quick)
            # the CLI's part failing, for chatnotify's status line, which runs
            # in another process
            if ($out[$rid] -in 'not taken', 'dropped') {
                try { New-ChatqDir $script:ChatqAskDir; Save-ChatqJson (Join-Path $script:ChatqAskDir 'missed.json') ([ordered]@{ at = (Get-ChatqStamp); rid = $rid; what = $out[$rid] }) } catch {}
            }
        }
    }
    return $out
}

#endregion

#region install: the hook as a Claude Code plugin of chatq's own

function Get-ChatqAskPluginDir { Join-Path $script:ChatqData 'claude-plugin' }

function Get-ChatqAskHookCommand {
    # the command the plugin runs: Windows PowerShell and the launcher,
    # absolute, forward slashes, double quotes
    $ps = Join-Path $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $script:ChatqIsWindows) { $ps = (Get-Process -Id $PID).Path }
    $launcher = Join-Path (Join-Path $script:ChatRoot 'src') 'ask-hook.ps1'
    return ('"' + $ps.Replace('\', '/') + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $launcher.Replace('\', '/') + '"')
}

function Get-ChatqAskHooksBlock {
    # the hooks block, as the plugin's hooks.json and as -Manual prints it: a
    # PermissionRequest hook for AskUserQuestion, its timeout the longest wait
    # plus a minute - the hook's own deadline always comes first
    $h = [ordered]@{ type = 'command'; command = (Get-ChatqAskHookCommand); timeout = 720 * 60 + 60; statusMessage = 'chatq: your phone can answer this too' }
    return [ordered]@{ PermissionRequest = @([ordered]@{ matcher = 'AskUserQuestion'; hooks = @($h) }) }
}

function Get-ChatqAskPluginVersion {
    # chatq's version and a hash of the command: a chatq moved to another
    # folder is a new version, so an update always takes it
    $u = New-Object System.Text.UTF8Encoding $false
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($u.GetBytes((Get-ChatqAskHookCommand))) } finally { $sha.Dispose() }
    return "$($script:ChatVersion)-$((-join ($h[0..3] | ForEach-Object { $_.ToString('x2') })))"
}

function Write-ChatqAskPlugin {
    # the local marketplace and its one plugin, in data/claude-plugin/
    $root = Get-ChatqAskPluginDir
    $plug = Join-Path $root 'chatq-ask'
    New-ChatqDir (Join-Path $root '.claude-plugin')
    New-ChatqDir (Join-Path $plug '.claude-plugin')
    New-ChatqDir (Join-Path $plug 'hooks')
    $desc = "chatq: answer Claude's questions from your phone"
    Save-ChatqJson (Join-Path (Join-Path $root '.claude-plugin') 'marketplace.json') ([ordered]@{
            name = $script:ChatqAskMarketName; owner = [ordered]@{ name = 'chatq' }
            plugins = @([ordered]@{ name = $script:ChatqAskPluginName; source = './chatq-ask'; description = $desc })
        })
    Save-ChatqJson (Join-Path (Join-Path $plug '.claude-plugin') 'plugin.json') ([ordered]@{ name = $script:ChatqAskPluginName; version = (Get-ChatqAskPluginVersion); description = $desc })
    Save-ChatqJson (Join-Path (Join-Path $plug 'hooks') 'hooks.json') ([ordered]@{ hooks = (Get-ChatqAskHooksBlock) })
    return $root
}

function Invoke-ChatqAskCli {
    <#
    One claude plugin command: @{ Code; Out } - the exit code and what it
    printed. With the config dir of the chats chatq watches, set only when
    it is not the default one: CLAUDE_CONFIG_DIR at ~/.claude would move
    ~/.claude.json. $script:ChatqAskCliSeam for the tests.
    #>
    param([string[]]$ArgList)
    if ($script:ChatqAskCliSeam) { return (& $script:ChatqAskCliSeam $ArgList) }
    $exe = Find-ChatqExe 'claude'
    if (-not $exe) { return [pscustomobject]@{ Code = -1; Out = 'claude is not on PATH' } }
    $buf = [System.Collections.Generic.List[string]]::new()
    $env2 = @{}
    $default = Join-Path $HOME '.claude'
    if ($script:ChatClaudeHome -and -not [string]::Equals(([string]$script:ChatClaudeHome).TrimEnd('\', '/'), $default, [StringComparison]::OrdinalIgnoreCase)) { $env2['CLAUDE_CONFIG_DIR'] = [string]$script:ChatClaudeHome }
    try {
        $r = Invoke-ChatqProcess -Exe $exe -ArgList $ArgList -StdIn '' -TimeoutSec 120 -SetEnv $env2 -OnLine { param($l) $buf.Add($l) }
        return [pscustomobject]@{ Code = [int]$r.ExitCode; Out = ((@($buf) + @($r.StdErr)) -join "`n").Trim() }
    }
    catch { return [pscustomobject]@{ Code = -1; Out = $_.Exception.Message } }
}

function Get-ChatqAskHookState {
    <#
    Where the hook stands: @{ Installed; Stale; Manual; Blocked; Why }.
    Installed: the plugin chatq-ask@chatq-local is listed by claude plugin
    list (or, -Manual, a PermissionRequest hook naming ask-hook.ps1 is in the
    user's settings, read and never written). Stale: its version is not this
    chatq's, from this folder. Blocked: a policy allows managed hooks only.
    #>
    param([switch]$Manual)
    $r = [pscustomobject]@{ Installed = $false; Stale = $false; Manual = [bool]$Manual; Blocked = $false; Why = $null }
    $sf = Join-Path $script:ChatClaudeHome 'settings.json'
    $st = try { if (Test-Path -LiteralPath $sf) { [System.IO.File]::ReadAllText($sf) } else { '' } } catch { '' }
    if ($st -match '"allowManagedHooksOnly"\s*:\s*true') { $r.Blocked = $true }
    if ($Manual) {
        $r.Installed = [bool]($st -match 'ask-hook\.ps1' -and $st -match '"PermissionRequest"')
        return $r
    }
    $l = Invoke-ChatqAskCli @('plugin', 'list', '--json')
    if ($l.Code -ne 0) { $r.Why = $l.Out; return $r }
    $list = try { $l.Out | ConvertFrom-Json } catch { $null }
    $id = "$($script:ChatqAskPluginName)@$($script:ChatqAskMarketName)"
    foreach ($p in @($list)) {
        if (-not $p) { continue }
        $name = [string](Get-ChatField $p 'id'); if (-not $name) { $name = [string](Get-ChatField $p 'name') }
        if ($name -ne $id -and $name -ne $script:ChatqAskPluginName) { continue }
        $r.Installed = $true
        $ver = [string](Get-ChatField $p 'version')
        if ($ver -and $ver -ne (Get-ChatqAskPluginVersion)) { $r.Stale = $true }
    }
    return $r
}

function Install-ChatqAskHook {
    <#
    The hook put in place, by Claude Code's own CLI - chatq never writes the
    user's Claude settings: the plugin written into data/claude-plugin/, the
    marketplace added (removed first when one of that name points elsewhere),
    the plugin installed, and updated when it was there at another version.
    -Manual: nothing run - the hooks block is returned for the user to paste
    into their settings. @{ Ok; Say; Block }.
    #>
    param([switch]$Manual)
    $root = Write-ChatqAskPlugin
    if ($Manual) {
        $block = [ordered]@{ hooks = (Get-ChatqAskHooksBlock) } | ConvertTo-Json -Depth 8
        return [pscustomobject]@{ Ok = $true; Say = 'add this to your Claude settings (~/.claude/settings.json), merged into any hooks already there:'; Block = $block }
    }
    $state = Get-ChatqAskHookState
    if ($state.Blocked) { return [pscustomobject]@{ Ok = $false; Say = 'your Claude Code policy allows only managed hooks - the phone can show questions, not answer them'; Block = $null } }
    $fail = { param($what, $r) [pscustomobject]@{ Ok = $false; Say = "$what failed: $(if ($r.Out) { ($r.Out -split "`n")[0] } else { "exit $($r.Code)" })"; Block = $null } }
    $ml = Invoke-ChatqAskCli @('plugin', 'marketplace', 'list', '--json')
    $markets = if ($ml.Code -eq 0) { $mlp = try { $ml.Out | ConvertFrom-Json } catch { $null }; @($mlp) } else { @() }
    $mine = @($markets | Where-Object { $_ -and [string](Get-ChatField $_ 'name') -eq $script:ChatqAskMarketName })[0]
    $here = ([System.IO.Path]::GetFullPath($root)).TrimEnd('\').ToLowerInvariant()
    if ($mine -and (($mine | ConvertTo-Json -Depth 6 -Compress).Replace('\\', '\').ToLowerInvariant().IndexOf($here) -lt 0)) {
        $rm = Invoke-ChatqAskCli @('plugin', 'marketplace', 'remove', $script:ChatqAskMarketName)
        if ($rm.Code -ne 0) { return (& $fail 'claude plugin marketplace remove' $rm) }
        $mine = $null
    }
    if (-not $mine) {
        $add = Invoke-ChatqAskCli @('plugin', 'marketplace', 'add', $root, '--scope', 'user')
        if ($add.Code -ne 0) { return (& $fail 'claude plugin marketplace add' $add) }
    }
    $id = "$($script:ChatqAskPluginName)@$($script:ChatqAskMarketName)"
    if ($state.Installed) {
        $up = Invoke-ChatqAskCli @('plugin', 'marketplace', 'update', $script:ChatqAskMarketName)
        if ($up.Code -ne 0) { return (& $fail 'claude plugin marketplace update' $up) }
        $pu = Invoke-ChatqAskCli @('plugin', 'update', $id)
        if ($pu.Code -ne 0) { return (& $fail 'claude plugin update' $pu) }
    }
    else {
        $in = Invoke-ChatqAskCli @('plugin', 'install', $id, '--scope', 'user')
        if ($in.Code -ne 0) { return (& $fail 'claude plugin install' $in) }
    }
    return [pscustomobject]@{ Ok = $true; Say = 'the question hook is installed as the Claude Code plugin chatq-ask - new chats can be answered from the phone; reload a VS Code window for the chats open in it'; Block = $null }
}

function Uninstall-ChatqAskHook {
    # the plugin and its marketplace removed by Claude Code's CLI; the files
    # in data/claude-plugin/ go with them. @{ Ok; Say }
    $id = "$($script:ChatqAskPluginName)@$($script:ChatqAskMarketName)"
    $un = Invoke-ChatqAskCli @('plugin', 'uninstall', $id)
    if ($un.Code -ne 0 -and $un.Out -notmatch 'not (installed|found)') { return [pscustomobject]@{ Ok = $false; Say = "claude plugin uninstall failed: $(($un.Out -split "`n")[0])" } }
    $rm = Invoke-ChatqAskCli @('plugin', 'marketplace', 'remove', $script:ChatqAskMarketName)
    if ($rm.Code -ne 0 -and $rm.Out -notmatch 'not (found|configured)') { return [pscustomobject]@{ Ok = $false; Say = "claude plugin marketplace remove failed: $(($rm.Out -split "`n")[0])" } }
    Remove-Item -LiteralPath (Get-ChatqAskPluginDir) -Recurse -Force -EA SilentlyContinue
    return [pscustomobject]@{ Ok = $true; Say = 'the question hook is removed' }
}

function Read-ChatqAskChanges {
    <#
    Set-ChatqNotifyConfig's keys for answering questions, checked before
    anything is saved: Ask (on/off or a bool), AskWait (5 to 720 minutes),
    AskManual (a bool: print the hook for the settings, run nothing).
    @{ Error; Any; On; Wait; Manual }
    #>
    param([hashtable]$Ch)
    $r = [pscustomobject]@{ Error = $null; Any = $false; On = $null; Wait = $null; Manual = $false }
    if ($Ch.ContainsKey('Ask') -and $null -ne $Ch['Ask'] -and '' -ne $Ch['Ask']) {
        $v = $Ch['Ask']
        $r.On = ConvertFrom-ChatqOnOff $v
        if ($null -eq $r.On) { $r.Error = "-Ask takes on or off, not '$v'"; return $r }
        $r.Any = $true
    }
    if ($Ch.ContainsKey('AskWait') -and $null -ne $Ch['AskWait'] -and '' -ne $Ch['AskWait']) {
        $w = $Ch['AskWait'] -as [int]
        if ($null -eq $w -or $w -lt 5 -or $w -gt 720) { $r.Error = '-AskWait takes 5 to 720 minutes'; return $r }
        $r.Wait = $w
        $r.Any = $true
    }
    $r.Manual = [bool]($Ch.ContainsKey('AskManual') -and $Ch['AskManual'])
    return $r
}

function Set-ChatqAskChanges {
    <#
    Read-ChatqAskChanges' keys applied, after every other key is saved: the
    wait written; on - the hook installed (Install-ChatqAskHook) and ask.on
    set only once it is; off - ask.on cleared first, so a hook that stays
    for any reason stands aside, then the plugin removed. Returns @{ Text;
    Color } lines.
    #>
    param($Changes)
    $msgs = [System.Collections.Generic.List[object]]::new()
    # each key read, set and saved under config.json's lock (Lock-ChatqConfig)
    $put = {
        param($k, $v)
        Lock-ChatqConfig
        try {
            $c = Get-ChatqConfig
            if (-not ($c.PSObject.Properties['ask'] -and $c.ask)) { Set-ChatqProp $c 'ask' ([pscustomobject]@{}) }
            Set-ChatqProp $c.ask $k $v
            Save-ChatqConfig $c
        }
        finally { Unlock-ChatqConfig }
    }
    if ($null -ne $Changes.Wait) {
        & $put 'waitMinutes' $Changes.Wait
        $msgs.Add([pscustomobject]@{ Text = "a question is held for the phone $($Changes.Wait) min - the dialog stays open either way"; Color = 'Green' })
    }
    if ($Changes.On -eq $true) {
        $ins = Install-ChatqAskHook -Manual:$Changes.Manual
        if (-not $ins.Ok) { $msgs.Add([pscustomobject]@{ Text = "questions from the phone stay off - $($ins.Say)"; Color = 'Yellow' }); return $msgs.ToArray() }
        & $put 'on' $true
        & $put 'manual' ([bool]$Changes.Manual)
        $msgs.Add([pscustomobject]@{ Text = "questions from the phone on - a chat you run yourself that asks a question can be answered from the board or its alert; the PC's dialog stays open too"; Color = 'Green' })
        $msgs.Add([pscustomobject]@{ Text = $ins.Say; Color = 'DarkGray' })
        if ($ins.Block) { $msgs.Add([pscustomobject]@{ Text = $ins.Block; Color = 'Cyan' }) }
        if (-not (Get-ChatqReplyConfig).Links) { $msgs.Add([pscustomobject]@{ Text = 'no phone is paired - the questions only show at the PC (chatnotify -Pair)'; Color = 'Yellow' }) }
    }
    elseif ($Changes.On -eq $false) {
        $was = Get-ChatqAskConfig
        & $put 'on' $false
        if ($was.Manual) { $msgs.Add([pscustomobject]@{ Text = 'questions from the phone off - take the PermissionRequest hook naming ask-hook.ps1 out of your Claude settings'; Color = 'DarkGray' }) }
        else {
            $un = Uninstall-ChatqAskHook
            if ($un.Ok) { $msgs.Add([pscustomobject]@{ Text = "questions from the phone off - $($un.Say)"; Color = 'DarkGray' }) }
            # off all the same - an installed hook with ask.on off says nothing -
            # but the plugin stays until an -Ask off gets through, and
            # chatuninstall -All will not delete the folder under it
            else { $msgs.Add([pscustomobject]@{ Text = "questions from the phone off, but the plugin is still installed - $($un.Say); chatnotify -Ask off again"; Color = 'Yellow' }) }
        }
    }
    return $msgs.ToArray()
}

function Get-ChatqAskStatusText {
    # one line for chatnotify and the setup window. -NoCli: the plugin not
    # looked up (a claude start costs a second or two)
    param($Cfg, [switch]$NoCli)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $ac = Get-ChatqAskConfig $Cfg
    if (-not $ac.On) {
        # an -Ask off whose uninstall failed: the hook stays silent, but it is there
        if (-not $ac.Manual -and (Test-Path -LiteralPath (Get-ChatqAskPluginDir))) { return 'off, but the plugin chatq-ask may still be installed - chatnotify -Ask off again' }
        return 'off - the phone shows them, you answer at the PC'
    }
    if (-not (Get-ChatqReplyConfig $Cfg).Links) { return 'on, but no phone is paired - you answer at the PC' }
    $s = "on - the phone can answer them for $($ac.WaitMinutes) min"
    if (-not $NoCli) {
        $h = Get-ChatqAskHookState -Manual:$ac.Manual
        if ($h.Blocked) { return 'on, but your Claude Code policy allows only managed hooks - you answer at the PC' }
        if (-not $h.Installed) { return "on, but the hook is not installed - chatnotify -Ask on$(if ($ac.Manual) { ' -Manual' })" }
        if ($h.Stale) { return 'on, but the hook points at an old copy - chatnotify -Ask on' }
        $s += $(if ($ac.Manual) { ' (a hook you added)' } else { " (plugin chatq-ask, $($script:ChatClaudeHome))" })
    }
    $m = Get-ChatqAskMissed
    if ($m) { $s += " - the last answer from the phone did not land ($($m.At.ToString('HH:mm'))), see data/logs/replies.log" }
    return $s
}

function Get-ChatqAskMissed {
    # the last answer from the phone that did not land, in the last day:
    # @{ At; Rid; What } or $null
    $o = Read-ChatqJson (Join-Path $script:ChatqAskDir 'missed.json')
    $at = if ($o) { ConvertTo-ChatqDate $o.at } else { $null }
    if (-not $at -or $at -lt (Get-Date).AddDays(-1)) { return $null }
    return [pscustomobject]@{ At = $at; Rid = [string]$o.rid; What = [string]$o.what }
}

function Remove-ChatqAskLeftovers {
    <#
    data/ask/ kept tidy. An open request whose hook is gone becomes gone,
    one past its deadline timeout - rewritten, not deleted, so the page and
    a late answer can still be told what became of it. A request and its
    answer go only once they are not open and an hour past both their
    deadline and their last change.
    #>
    param([datetime]$Now = (Get-Date))
    foreach ($q in @(Get-ChatqAskRequests)) {
        try {
            $until = ConvertTo-ChatqDate $q.until
            if ([string]$q.state -eq 'open') {
                if ($until -and $until -le $Now) { Set-ChatqAskState $q 'timeout' -From 'open' }
                elseif (-not (Test-ChatqAskHookAlive $q)) { Set-ChatqAskState $q 'gone' -From 'open' }
                continue
            }
            $changed = ConvertTo-ChatqDate (Get-ChatField $q 'changedAt')
            $last = @($until, $changed, (ConvertTo-ChatqDate $q.at)) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            if (-not $last -or $last.AddHours(1) -lt $Now) {
                Remove-Item -LiteralPath $q.Path -Force -EA SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir "$($q.rid).ans.json") -Force -EA SilentlyContinue
            }
        }
        catch {}
    }
}

#endregion
