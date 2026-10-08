# Charlie-and-the-chat-factory, src/queue.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region queue: configuration --------------------------------------------

$script:ChatqIsWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

# Every runtime file lives in data/ beside the script, never in AppData or
# TEMP - the folder is the whole installation, and deleting it is the uninstall.
$script:ChatqData = Join-Path $script:ChatRoot 'data'
$script:ChatqQueueDir = Join-Path $script:ChatqData 'queue'
$script:ChatqLogDir = Join-Path $script:ChatqData 'logs'
$script:ChatqConfigPath = Join-Path $script:ChatqData 'config.json'
# held around every read-change-save of config.json (Lock-ChatqConfig)
$script:ChatqConfigLockPath = Join-Path $script:ChatqData 'config.lock'
$script:ChatqStatePath = Join-Path $script:ChatqData 'state.json'
$script:ChatqLockPath = Join-Path $script:ChatqData 'watcher.lock'
$script:ChatqPidPath = Join-Path $script:ChatqData 'watcher.pid'
$script:ChatqWakePath = Join-Path $script:ChatqData 'wake'
$script:ChatqStopPath = Join-Path $script:ChatqData 'stop'
$script:ChatqBoardPath = Join-Path $script:ChatqData 'queue.md'
# held while a new job takes its number and id (New-ChatqJobSlot): a
# shell, the overlay and the watcher all make jobs
$script:ChatqSeqLockPath = Join-Path $script:ChatqData 'job-numbers.lock'
# one file per cut-off the reset ask answered or announced (Get-ChatqResetAsk)
$script:ChatqAutoDir = Join-Path $script:ChatqData 'auto'
# written by chatinstall: a running watcher hands over to the new code
$script:ChatqRestartPath = Join-Path $script:ChatqData 'restart'
# a queued run's own --settings, <jobId>.json, while it runs: Ultracode as
# its chat had it (Invoke-ChatqRun)
$script:ChatqRunSettingsDir = Join-Path $script:ChatqData 'run-settings'
# the console's own state, its folders among it - which the phone's board
# offers too, in a process that never loads the console's part
$script:ChatConsoleStatePath = Join-Path $script:ChatqData 'console-state.json'
# tests only: a scriptblock that stands in for launching a real watcher
$script:ChatqSpawn = $null
$script:ChatqScriptPath = $script:ChatScriptPath

# This file stays pure ASCII. Windows PowerShell 5.1 reads a .ps1 without a BOM
# in the ANSI code page - 949 on a Korean machine - so a literal middle dot or
# Hangul in a string here is mangled before a line of it runs. Non-ASCII text
# is built from code points instead; everything read from disk says UTF-8.
$script:ChatqDot = [string][char]0x00B7
$script:ChatqEllipsis = [string][char]0x2026

# What Claude Code itself sends when it resumes a turn the limit cut off - an
# isMeta user message with exactly this text. -Continue sends the same words.
$script:ChatqContinueText = 'Continue from where you left off.'

# Claude's public status page. The "Claude Code" component is what a run
# stopped by "API Error: 529 Overloaded" waits on before it is tried again.
$script:ChatqStatusUrl = 'https://status.claude.com/api/v2/components.json'
$script:ChatqStatusComponent = 'Claude Code'

# Caches and flags, set here so a caller's Set-StrictMode -Version Latest -
# which this dot-sourced file inherits - never meets one unset.
$script:ChatqCliVersions = @{}
# Where the VS Code extensions are looked for in place of $HOME, which a
# test cannot move: the copy a PATH one is compared with (Get-ChatqCliReport)
$script:ChatqExtHomeSeam = $null
$script:ChatqAwake = $false
$script:ChatqAwakeProc = $null
$script:ChatqLastAlertError = $null
$script:ChatqForeground = $false
$script:ChatqAlertReport = $null   # what each channel did with the last alert
$script:ChatqAlertJob = $null      # "#n" of the job an alert is about, for the hook
# seams the tests set: no real toast, no real network, no real idle clock
$script:ChatqToastSeam = $null
$script:ChatqNtfySeam = $null
# Join's push ($url -> $null or the error), the reply topic's poll ($url ->
# the NDJSON text) and Join's device list ($url -> the JSON text)
$script:ChatqJoinSeam = $null
$script:ChatqReplyPollSeam = $null
$script:ChatqJoinDevicesSeam = $null
# the down topic's POST or PUT ($method, $url, $headers, $body -> $null or
# the error): src/phone-down.ps1, Invoke-ChatqDownRequest
$script:ChatqDownSeam = $null
# a live chat's alert (Send-ChatqLiveAlert), handed here instead of to the
# hidden process that sends it
$script:ChatqLiveSendSeam = $null
$script:ChatqIdleSeam = $null
$script:ChatqHookTimeoutSec = $null
$script:ChatqClipboardSeam = $null
$script:ChatqAliveSeam = $null
# and for showing a chat fresh: a chat process's parent, ending one, the code
# CLI and the Code.exe it is found beside, the window titles (and the
# windows with their handles) and profile names, the overlay's child - none
# of them real in a test
$script:ChatParentSeam = $null
$script:ChatStopSeam = $null
$script:ChatCodeSeam = $null
$script:ChatCodeExesSeam = $null
$script:ChatWindowTitlesSeam = $null
$script:ChatCodeWindowListSeam = $null
$script:ChatCodeProfilesSeam = $null
$script:ChatShowSpawnSeam = $null

#endregion

#region queue: readers only the queue needs ----------------------------

function Read-ChatqTail {
    # The last $Size bytes as text. Cutting mid-character only garbles the first
    # few bytes, which a caller looking for whole JSON lines skips anyway.
    param([string]$Path, [int64]$Size)
    try { $fs = Open-ChatRead $Path } catch { return $null }
    try {
        $n = [int][Math]::Min($Size, $fs.Length)
        if ($n -le 0) { return '' }
        return (Read-ChatTextAt $fs (-$n) $n End)
    }
    finally { $fs.Dispose() }
}

function Find-ChatqTailString {
    # The last value of a JSON string key, looking back from the end in growing
    # windows. The permission mode is written on user records only, and in a
    # 7 MB chat the last one sat 240 KB from the end - past any fixed chunk.
    param([string]$Path, [string]$Key)
    $len = try { ([System.IO.FileInfo]::new($Path)).Length } catch { 0 }
    foreach ($size in 65536, 1048576, 8388608, 67108864) {
        $t = Read-ChatqTail $Path $size
        $v = Get-ChatJsonString $t $Key
        if ($v) { return $v }
        if ($size -ge $len) { break }
    }
    return $null
}

function Read-ChatqJsonObjectAt {
    # The {...} that starts at $Start, by brace matching - strings honoured - so
    # one object can be lifted out of a file and parsed without parsing the rest
    param([string]$Text, [int]$Start)
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true }
        elseif ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start + 1) }
        }
    }
    return $null
}

function ConvertTo-ChatqDate {
    # Untyped on purpose. pwsh 7's ConvertFrom-Json hands ISO timestamps back
    # as [datetime] already (5.1 keeps them strings); a [string] parameter would
    # flatten that to local wall-clock time with no zone, and ToLocalTime would
    # then shift it a second time by the UTC offset.
    param($Text)
    if (-not $Text) { return $null }
    if ($Text -is [datetime]) {
        if ($Text.Kind -eq [System.DateTimeKind]::Utc) { return $Text.ToLocalTime() }
        return $Text
    }
    try {
        return [datetime]::Parse([string]$Text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    }
    catch { return $null }
}

function ConvertTo-ChatqResetDate {
    # A resets_at off Claude's usage endpoint, to the nearest minute. The
    # endpoint jitters it around the reset - 12:59:59.855 on one fetch,
    # 13:00:00 on the next - and HH:mm cuts the first down, so one reset read
    # 21:59 and 22:00 by turns. Rounded in UTC: local ticks rebuilt as a new
    # local time lose which pass of a DST fall-back hour they were, an hour
    # off for one of the two.
    param($Text)
    $d = ConvertTo-ChatqDate $Text
    if (-not $d) { return $null }
    $m = [TimeSpan]::TicksPerMinute
    $t = $d.ToUniversalTime().Ticks + [int64]($m / 2)
    return [datetime]::new($t - ($t % $m), [System.DateTimeKind]::Utc).ToLocalTime()
}

#endregion

#region resolver --------------------------------------------------------------
# Runs when you queue, not when the limit resets: you are at the keyboard now
# and gone then, so the pick is printed while a wrong one can still be undone.

$script:ChatqWindowHours = 5    # one usage-limit window

function ConvertTo-ChatqNorm {
    # NFC, because macOS types Hangul decomposed (NFD) and the transcript holds
    # it composed - the same title would otherwise never compare equal
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.Normalize([System.Text.NormalizationForm]::FormC)
    return ($t -replace '\s+', ' ').Trim()
}

function Get-ChatqBigrams {
    # Character pairs of each word, padded so a word's first and last letters
    # count too. Pairs, not words: Korean glues particles onto nouns (card +
    # object marker is one word), so whole-word matching misses what two-letter
    # overlap catches.
    # Hangul syllables are letters to IsLetterOrDigit, so no language switch.
    param([string]$Text)
    $d = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    if (-not $Text) { return , $d }
    $t = $Text.Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
    $sb = [System.Text.StringBuilder]::new($t.Length + 2)
    foreach ($ch in $t.ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch)) { [void]$sb.Append($ch) } else { [void]$sb.Append(' ') }
    }
    foreach ($tok in $sb.ToString().Split([char[]]@(' '), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $p = " $tok "
        for ($i = 0; $i -lt $p.Length - 1; $i++) {
            $k = $p.Substring($i, 2)
            $v = 0
            if ($d.TryGetValue($k, [ref]$v)) { $d[$k] = $v + 1 } else { $d[$k] = 1 }
        }
    }
    return , $d
}

function Get-ChatqCosine {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B -or $A.Count -eq 0 -or $B.Count -eq 0) { return 0.0 }
    $dot = 0.0
    foreach ($k in $A.Keys) {
        $v = 0
        if ($B.TryGetValue($k, [ref]$v)) { $dot += $A[$k] * $v }
    }
    if ($dot -eq 0) { return 0.0 }
    $na = 0.0; foreach ($v in $A.Values) { $na += $v * $v }
    $nb = 0.0; foreach ($v in $B.Values) { $nb += $v * $v }
    return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}

function Get-ChatqRelevance {
    # 0.6 on the title: what was typed was meant as a title. 0.4 on the chat's
    # own opening and latest prompts against what was typed plus the prompt -
    # that is what separates two chats whose titles look alike.
    param($Row, [string]$Typed, [string]$Prompt)
    $title = Get-ChatqCosine (Get-ChatqBigrams $Typed) (Get-ChatqBigrams $Row.Title)
    $q = $Typed
    if ($Prompt) { $q += ' ' + $Prompt.Substring(0, [Math]::Min(2000, $Prompt.Length)) }
    $body = (@($Row.First) + @($Row.Last)) -join ' '
    $content = Get-ChatqCosine (Get-ChatqBigrams $q) (Get-ChatqBigrams $body)
    return [Math]::Round(0.6 * $title + 0.4 * $content, 3)
}

function Test-ChatqTitleEquals {
    # The index clips titles at 60 characters with '...', so a long title typed
    # in full never equals the stored one - its clipped stem has to count
    param([string]$Title, [string]$Typed)
    $t = ConvertTo-ChatqNorm $Title
    if ($t.Equals($Typed, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($t.EndsWith('...') -and $t.Length -gt 10) {
        return $Typed.StartsWith($t.Substring(0, $t.Length - 3), [StringComparison]::OrdinalIgnoreCase)
    }
    return $false
}

function Resolve-ChatqTarget {
    <#
    Which chat a typed target means. The rules are the user's:
      - an id is that chat
      - otherwise exact title, then contains, then every word - this project
        first, every project only when this one has no match at all
      - nothing matched anywhere: every chat in this project is a candidate
      - of several candidates the newest wins, unless others were active
        within 5 h of it - one limit window, so recency cannot tell them
        apart - and then the most relevant one does
    Never guesses across projects on a miss: a prompt landing in the wrong
    repo's chat would act on the wrong repo.
    #>
    param([string]$Target, [string]$Prompt, [string[]]$Provider, [switch]$AllProjects)
    $typed = ConvertTo-ChatqNorm ($Target.Trim().Trim("'", '"'))
    if (-not $typed) { return [pscustomobject]@{ Error = 'no target given' } }
    $all = @(Sync-ChatIndex -Provider $Provider | Where-Object { -not $_.Hidden -and $_.Title -ne '(empty)' })
    if (-not $all) { return [pscustomobject]@{ Error = 'no chats found on this machine' } }
    $when = @{}
    foreach ($r in $all) { $when[$r.Path] = ConvertTo-ChatqDate $r.When }

    $make = {
        param($Row, $Rule, $Tier, $Score, $Runner, $RunnerScore, $Cluster, $Count, $Wide, $NoProject)
        # Copilot chats are searched so that naming one says why it cannot be
        # queued, rather than quietly resolving to some other chat instead
        if ($Row.Provider -eq 'copilot') {
            return [pscustomobject]@{ Error = "'$($Row.Title)' is a Copilot chat - Copilot has no CLI that can resume a chat, so nothing can deliver a prompt to it. Type more of the title to pick a Claude or Codex chat." }
        }
        [pscustomobject]@{
            Error = $null; Row = $Row; When = $when[$Row.Path]; Rule = $Rule; Tier = $Tier
            Score = $Score; RunnerUp = $Runner; RunnerUpScore = $RunnerScore
            RunnerUpWhen = if ($Runner) { $when[$Runner.Path] } else { $null }
            Cluster = $Cluster; Candidates = $Count; Wide = $Wide; NoProject = $NoProject; Typed = $typed
        }
    }

    # an id is exact by definition, and never scoped to a project
    if ($typed -match '^[0-9a-fA-F]{6,}(-[0-9a-fA-F-]*)?$') {
        $hit = @($all | Where-Object { $_.Id -like "$typed*" })
        if ($hit.Count -eq 1) { return & $make $hit[0] 'id' 'id' $null $null $null 1 1 $false $false }
        if ($hit.Count -gt 1) {
            return [pscustomobject]@{ Error = "'$typed' starts $($hit.Count) chat ids - type more of it" }
        }
        # no id starts with it: 'facade' is a fine title and valid hex
    }

    $scope = Get-ChatProjectScope
    $mine = if ($AllProjects) { $all } else { @($all | Where-Object { Test-ChatInProject $_ $scope }) }
    $noProject = -not $mine
    if ($noProject) { $mine = $all }
    $pools = @(@{ Rows = $mine; Wide = $false })
    if (-not $AllProjects -and -not $noProject) { $pools += @{ Rows = $all; Wide = $true } }

    $words = @($typed -split ' ' | Where-Object { $_ })
    $cands = @(); $tier = $null; $wide = $false
    foreach ($pool in $pools) {
        foreach ($t in 'exact', 'contains', 'words') {
            $m = @(switch ($t) {
                    'exact' { $pool.Rows | Where-Object { Test-ChatqTitleEquals $_.Title $typed } }
                    'contains' {
                        $pool.Rows | Where-Object { (ConvertTo-ChatqNorm $_.Title).IndexOf($typed, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
                    }
                    'words' {
                        if ($words.Count -gt 1) {
                            $pool.Rows | Where-Object {
                                $ti = ConvertTo-ChatqNorm $_.Title
                                -not @($words | Where-Object { $ti.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 })
                            }
                        }
                    }
                })
            if ($m.Count) { $cands = $m; $tier = $t; $wide = $pool.Wide; break }
        }
        if ($cands.Count) { break }
    }
    if (-not $cands.Count) {
        # A guess is only fair inside one project. Standing somewhere that is
        # no project at all, "the newest chat" would be any repo's on the
        # machine - refuse, unless -AllProjects asked for exactly that.
        if ($noProject -and -not $AllProjects) {
            return [pscustomobject]@{ Error = "no chat title matches '$typed', and this folder is not a project - cd into the project, type more of the title, or add -AllProjects to guess across all of them" }
        }
        # a guess is never a Copilot chat - it could only end in a refusal
        $cands = @($mine | Where-Object { $_.Provider -ne 'copilot' }); $tier = 'nomatch'
        if (-not $cands.Count) { return [pscustomobject]@{ Error = "no chat title matches '$typed', and this project has no Claude or Codex chat to guess from" } }
    }

    $sorted = @($cands | Sort-Object { $when[$_.Path] } -Descending)
    $newest = $sorted[0]
    $cluster = @($sorted | Where-Object { ($when[$newest.Path] - $when[$_.Path]).TotalHours -le $script:ChatqWindowHours })
    if ($cluster.Count -eq 1) {
        $rule = if ($sorted.Count -gt 1) { "$tier/newest" } else { $tier }
        $runner = if ($sorted.Count -gt 1) { $sorted[1] } else { $null }
        return & $make $newest $rule $tier $null $runner $null 1 $sorted.Count $wide $noProject
    }
    $scored = @($cluster | ForEach-Object {
            [pscustomobject]@{ Row = $_; Score = (Get-ChatqRelevance $_ $typed $Prompt); When = $when[$_.Path] }
        } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'When'; Descending = $true })
    return & $make $scored[0].Row "$tier/relevance" $tier $scored[0].Score $scored[1].Row $scored[1].Score `
        $cluster.Count $sorted.Count $wide $noProject
}

function Write-ChatqPick {
    # one line for the pick, then only what explains it
    param($Res, [string]$Lead = '  ->')
    $r = $Res.Row
    $age = if ($Res.When) { " ($(Get-ChatAge $Res.When))" } else { '' }
    $why = switch -Wildcard ($Res.Rule) {
        'id' { 'id' }
        'exact' { 'exact title' }
        'contains' { 'title contains it' }
        'words' { 'title has every word' }
        '*/newest' { "$($Res.Tier) - newest of $($Res.Candidates)" }
        '*/relevance' { "$($Res.Tier) - relevance $($Res.Score), $($Res.Cluster) active within $($script:ChatqWindowHours)h" }
        default { $Res.Rule }
    }
    Write-Host "$Lead " -NoNewline
    Write-Host "'$($r.Title)'" -NoNewline -ForegroundColor Cyan
    Write-Host "$age  $($r.Provider) $script:ChatqDot $why" -ForegroundColor DarkGray
    if ($Res.Tier -eq 'nomatch') {
        $from = if ($Res.NoProject) { 'recent chats in every project' } else { 'this project''s recent chats' }
        Write-Host "     no title matched - this is a guess from $from" -ForegroundColor Yellow
    }
    if ($Res.RunnerUp) {
        $ra = if ($Res.RunnerUpWhen) { " ($(Get-ChatAge $Res.RunnerUpWhen))" } else { '' }
        $rs = if ($null -ne $Res.RunnerUpScore) { " $($Res.RunnerUpScore)" } else { '' }
        Write-Host "     runner-up '$($Res.RunnerUp.Title)'$ra$rs" -ForegroundColor DarkGray
    }
    # a Codex chat's whole folder when the index has it: in D:\b\app, "not in
    # this project: app" for a chat of D:\a\app reads as a contradiction
    $where = Get-ChatField $r 'Cwd'
    if (-not $where) { $where = $r.Group }
    if ($Res.Wide) { Write-Host "     not in this project: $where" -ForegroundColor DarkGray }
    elseif ($Res.NoProject) { Write-Host "     project: $where" -ForegroundColor DarkGray }
}

function Write-ChatqPromptHint {
    # Everything after the command is the title, so a prompt typed bare joins
    # it, and the words meant for the chat go looking for one instead. What
    # that looks like is exactly this: a sentence that matched no title, and
    # the pick a guess. Said only then - a real title never prints it.
    param([string]$Typed, $Res, [switch]$HasPrompt, [switch]$Continue)
    if ($HasPrompt -or $Continue -or -not $Res -or $Res.Tier -ne 'nomatch') { return }
    $words = @($Typed -split '\s+' | Where-Object { $_ }).Count
    # a path or a URL in there is a prompt however short it is
    if ($words -lt 6 -and $Typed -notmatch '[\\/]|https?:') { return }
    Write-Host '     every word of that is the title - a prompt is never read from it' -ForegroundColor Yellow
    Write-Host "     did you mean:  chatq '<title>' -Prompt '<the rest>'" -ForegroundColor DarkGray
}

#endregion

#region session metadata ------------------------------------------------------

function Find-ChatqTailMatch {
    # the last match of $Pattern's first group, looking back in growing windows
    param([string]$Path, [string]$Pattern)
    $len = try { ([System.IO.FileInfo]::new($Path)).Length } catch { 0 }
    foreach ($size in 262144, 4194304, 67108864) {
        $t = Read-ChatqTail $Path $size
        if ($t) {
            $m = [regex]::Matches($t, $Pattern)
            if ($m.Count) { return $m[$m.Count - 1].Groups[1].Value }
        }
        if ($size -ge $len) { break }
    }
    return $null
}

function Get-ChatqLastTurn {
    # The last record that carries a message, walking back past the state lines
    # (ai-title, last-prompt, queue-operation) that trail every turn. Tells a
    # chat the limit cut off - its last message is Claude's own synthetic
    # "You've hit your session limit" - from one that finished or moved on.
    # The cut-off scan runs this on every transcript of the last week as the
    # overlay starts: 64 KB read first, where the message nearly always is
    # (65 of 69 in a trial), and the lines found back from the end one at a
    # time, never the window split whole - 69 transcripts in 49 ms, not 219.
    param([string]$Path)
    $len = try { ([System.IO.FileInfo]::new($Path)).Length } catch { return $null }
    foreach ($size in 65536, 262144, 4194304) {
        $t = Read-ChatqTail $Path $size
        if (-not $t) { return $null }
        $cut = $size -lt $len   # the window's first line is cut mid-line
        $end = $t.Length
        while ($end -ge 0) {
            $nl = if ($end -gt 0) { $t.LastIndexOf([char]10, $end - 1) } else { -1 }
            if ($nl -lt 0 -and $cut) { break }
            $s = $nl + 1
            $e = $end
            $end = $nl
            if ($t.IndexOf('"message":', $s, $e - $s, [StringComparison]::Ordinal) -lt 0) { continue }
            $line = $t.Substring($s, $e - $s).TrimStart([char]0xFEFF).Trim()
            $o = try { $line | ConvertFrom-Json } catch { $null }
            if (-not $o -or -not $o.message -or $o.isSidechain) { continue }
            $text = ''
            $c = $o.message.content
            if ($c -is [string]) { $text = $c }
            elseif ($c) { $text = (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
            $limit = ($o.error -eq 'rate_limit') -or
            ($o.isApiErrorMessage -and $text -match '(?i)hit your .*limit|usage limit')
            # the 529 turn: same synthetic shape, error server_error, apiErrorStatus 529
            $over = (-not $limit) -and $o.isApiErrorMessage -and
            (($o.apiErrorStatus -and [int]$o.apiErrorStatus -ge 500) -or $text -match $script:ChatqOverloadRx)
            $resets = $null
            if ($o.quotaLimits -and $o.quotaLimits.resetsAt) {
                $resets = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$o.quotaLimits.resetsAt).LocalDateTime
            }
            # where it ran: this record's own, else the last one the tail names -
            # looked for as far back as 256 KB, the first read's size once
            $cwd = if ($o.PSObject.Properties['cwd'] -and $o.cwd) { [string]$o.cwd }
            else {
                $cm = [regex]::Matches($t, '"cwd":"((?:[^"\\]|\\.)*)"')
                if (-not $cm.Count -and $cut -and $size -lt 262144) { $cm = [regex]::Matches([string](Read-ChatqTail $Path 262144), '"cwd":"((?:[^"\\]|\\.)*)"') }
                if ($cm.Count) { Convert-ChatJsonEscaped $cm[$cm.Count - 1].Groups[1].Value } else { $null }
            }
            return [pscustomobject]@{
                Uuid = $o.uuid; Type = $o.type; Limit = [bool]$limit; Overloaded = [bool]$over; ResetsAt = $resets
                At = ConvertTo-ChatqDate $o.timestamp; Text = $text; StopReason = $o.message.stop_reason; Cwd = $cwd
            }
        }
        if ($size -ge $len) { break }
    }
    return $null
}

function Get-ChatqClaudeMeta {
    param([string]$Path, [string]$Group)
    $meta = [pscustomobject]@{ Exists = $false; Cwd = $null; Mode = $null; Model = $null; LastTurn = $null }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $meta }
    $meta.Exists = $true
    $chunk = Read-ChatChunk $Path 262144
    if ($chunk) {
        # Both d:\ and D:\ turn up for the same folder. The one whose slug is
        # this project's folder name is the one Claude filed the chat under.
        $seen = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($chunk.Head + "`n" + $chunk.Tail, '"cwd":"((?:[^"\\]|\\.)*)"')) {
            $v = Convert-ChatJsonEscaped $m.Groups[1].Value
            if ($v -and -not $seen.Contains($v)) { $seen.Add($v) }
        }
        $meta.Cwd = @($seen | Where-Object { (Get-ChatSlug $_) -eq $Group -and (Test-Path -LiteralPath $_) }) |
            Select-Object -First 1
        if (-not $meta.Cwd) { $meta.Cwd = @($seen | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1 }
    }
    $meta.Mode = Find-ChatqTailString $Path 'permissionMode'
    # the real model sits first in a real assistant message; Claude's own error
    # turns carry <synthetic> and tool inputs carry aliases, neither of which
    # starts '"message":{"model":"claude-'
    $meta.Model = Find-ChatqTailMatch $Path '"message":\{"model":"(claude-[^"]+)"'
    $meta.LastTurn = Get-ChatqLastTurn $Path
    return $meta
}

# The only words codex's sandbox_mode takes (the app-server's SandboxMode
# enum too): a run given any other fails as its config loads, before a turn
# - "unknown variant `managed`" - so nothing else ever reaches -c sandbox_mode=
$script:ChatqCodexSandboxes = @('read-only', 'workspace-write', 'danger-full-access')

function ConvertTo-ChatqCodexSandbox {
    <#
    A sandbox word as codex's sandbox_mode takes it, from whatever a rollout
    or a job holds: the three kebab words as they are, the app-server's
    camelCase (readOnly, workspaceWrite, dangerFullAccess) turned into them.
    Anything else - 'managed', the permission profile newer threads keep in
    Codex's own DB, or 'externalSandbox', which sandbox_mode refuses too -
    runs workspace-write, and Unknown keeps the word so the caller can say
    so. None at all is workspace-write too, as it always was, and no
    Unknown. Returns @{ Sandbox; Unknown }. Pure.
    #>
    param([string]$Value)
    $v = ([string]$Value).Trim()
    if (-not $v) { return [pscustomobject]@{ Sandbox = 'workspace-write'; Unknown = $null } }
    # the camelCase app-server words, the kebab ones whatever their case
    $k = ($v -creplace '([a-z])([A-Z])', '$1-$2').ToLowerInvariant()
    if ($k -cin $script:ChatqCodexSandboxes) { return [pscustomobject]@{ Sandbox = $k; Unknown = $null } }
    return [pscustomobject]@{ Sandbox = 'workspace-write'; Unknown = $v }
}

function Get-ChatqCodexRunSandbox {
    <#
    The sandbox a Codex job runs in: its own pick in mode (-Sandbox, the
    console's chips, the phone's cap), else the chat's, as the job read it
    when queued. A mode that is no sandbox word - a Claude mode an older
    chatq stored when -Mode was given for a Codex chat - is no pick. The
    chat's own goes through ConvertTo-ChatqCodexSandbox, so a job saved
    with 'managed' runs. Unknown: that word, from sandbox on an older job,
    else from sandboxUnknown, where New-ChatqJobRecord keeps it now that
    sandbox holds the workspace-write. Returns @{ Sandbox; Picked; Unknown }.
    Pure.
    #>
    param($Job)
    $m = [string](Get-ChatField $Job 'mode')
    if ($m -cin $script:ChatqCodexSandboxes) { return [pscustomobject]@{ Sandbox = $m; Picked = $true; Unknown = $null } }
    $c = ConvertTo-ChatqCodexSandbox ([string](Get-ChatField $Job 'sandbox'))
    $u = if ($c.Unknown) { $c.Unknown } else { [string](Get-ChatField $Job 'sandboxUnknown') }
    return [pscustomobject]@{ Sandbox = $c.Sandbox; Picked = $false; Unknown = $(if ($u) { $u } else { $null }) }
}

function Get-ChatqCodexSandboxRank {
    # how wide a sandbox word is: read-only 0, workspace-write 1,
    # danger-full-access 2; anything else -1. Pure.
    param([string]$Sandbox)
    return [array]::IndexOf([string[]]$script:ChatqCodexSandboxes, [string]$Sandbox)
}

function Get-ChatqCodexMeta {
    # The chat as its rollout's last turn_context has it. Sandbox is the
    # word as written - Get-ChatqJobInfo makes it one codex takes. Effort:
    # the turn's own level, else the one its collaboration mode names; shown
    # beside the model, never sent - whether exec resume keeps it is
    # FUTURE_WORK's "Carry a Codex chat's effort into its run".
    param([string]$Path)
    $meta = [pscustomobject]@{ Exists = $false; Cwd = $null; Sandbox = $null; Network = $false; Approval = $null; Model = $null; Effort = $null }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $meta }
    $meta.Exists = $true
    $chunk = Read-ChatChunk $Path 262144
    if ($chunk -and $chunk.Head -match '"cwd":\s*"((?:[^"\\]|\\.)*)"') { $meta.Cwd = Convert-ChatJsonEscaped $Matches[1] }
    $text = if ($chunk.Split) { $chunk.Tail } else { $chunk.Head }
    $lines = Get-ChatJsonLines $text @('"type":"turn_context"', '"type": "turn_context"') 1 -FromEnd -Skip @()
    if ($lines.Count) {
        $o = try { $lines[0] | ConvertFrom-Json } catch { $null }
        if ($o.payload) {
            $meta.Sandbox = $o.payload.sandbox_policy.type
            $meta.Network = [bool]$o.payload.sandbox_policy.network_access
            $meta.Approval = $o.payload.approval_policy
            $meta.Model = $o.payload.model
            $meta.Effort = if ($o.payload.effort) { [string]$o.payload.effort }
            elseif ($o.payload.collaboration_mode.settings.reasoning_effort) { [string]$o.payload.collaboration_mode.settings.reasoning_effort }
            else { $null }
            if ($o.payload.cwd) { $meta.Cwd = $o.payload.cwd }
        }
    }
    return $meta
}

# tests: how many transcripts the cut-off scan has read
$script:ChatqCutOffReads = 0

function Get-ChatqCutOffChats {
    # Chats the limit - or a 529 Overloaded - stopped mid-task that nothing is
    # queued for: the ones you would otherwise walk round typing "continue"
    # into, one at a time. Only transcripts touched in the last $Hours count.
    # -Cache: the overlay asks every minute, so a transcript is read again
    # only once its length or time moved; the hashtable keeps what it said.
    # -Skip: session ids working right now - they are not cut off, and a
    # working chat's transcript moves all the time, so reading it would miss
    # the cache every minute.
    param([object[]]$Jobs, [int]$Hours = 12, [hashtable]$Cache, [string[]]$Skip)
    $root = Join-Path $script:ChatClaudeHome 'projects'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $since = (Get-Date).AddHours(-$Hours).ToUniversalTime()
    $busy = @{}
    # a job with no session - none should have one, but $null is no key
    foreach ($j in $Jobs) { if ($j.state -in 'queued', 'running' -and $j.sessionId) { $busy[[string]$j.sessionId] = $true } }
    foreach ($s in @($Skip)) { if ($s) { $busy[$s] = $true } }
    $rows = $null
    $seen = @{}
    $dirs = try { @([System.IO.DirectoryInfo]::new($root).EnumerateDirectories()) } catch { @() }
    $out = foreach ($d in $dirs) {
        # a folder gone since the list was taken, or a broken junction, is
        # one folder less - not the whole scan
        $files = try { @($d.EnumerateFiles('*.jsonl')) } catch { @() }
        foreach ($f in $files) {
            if ($f.LastWriteTimeUtc -le $since -or $f.Name.Length -ne 42 -or $f.BaseName -notmatch '^[0-9a-fA-F-]{36}$') { continue }
            if ($busy[$f.BaseName]) { continue }
            $sig = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
            $seen[$f.FullName] = $true
            if ($Cache -and $Cache.ContainsKey($f.FullName) -and $Cache[$f.FullName].Sig -eq $sig) {
                if ($Cache[$f.FullName].Row) { $Cache[$f.FullName].Row }
                continue
            }
            $script:ChatqCutOffReads++
            $last = Get-ChatqLastTurn $f.FullName
            $row = $null
            if ($last -and ($last.Limit -or $last.Overloaded)) {
                # The index is only as fresh as the last search, and a chat the
                # limit has just cut off is exactly the one that may be missing
                # from it. Read the title where it lives rather than printing a
                # uuid, which is not what the -Continue line below asks for.
                if ($null -eq $rows) { $rows = @{}; foreach ($r in @(Get-ChatIndex)) { $rows[$r.Path] = $r } }
                $title = if ($rows[$f.FullName]) { $rows[$f.FullName].Title }
                else {
                    $rec = try { & $script:ChatProviders['claude'].Describe $f } catch { $null }
                    if ($rec -and $rec.Title -and $rec.Title -ne '(empty)') { $rec.Title } else { $f.BaseName }
                }
                # LimitUuid: the limit record's own uuid, which names this one
                # cut-off for good (Get-ChatqCutKey); old records have none
                $row = [pscustomobject]@{
                    Id = $f.BaseName; Title = $title; Group = $d.Name; At = $last.At; ResetsAt = $last.ResetsAt
                    Why = if ($last.Limit) { 'limit' } else { 'overloaded' }; Path = $f.FullName; Cwd = $last.Cwd
                    LimitUuid = $last.Uuid
                }
            }
            if ($Cache) { $Cache[$f.FullName] = @{ Sig = $sig; Row = $row } }
            if ($row) { $row }
        }
    }
    # what fell out of the window, or went, is forgotten
    if ($Cache) { foreach ($k in @($Cache.Keys)) { if (-not $seen[$k]) { $Cache.Remove($k) } } }
    return @($out | Sort-Object At -Descending)
}

#endregion

#region queue: the reset ask ------------------------------------------------------
# config autoContinue. ask, the default: once the limit is over, the overlay
# says how many chats it cut off and continues them if you say so. off: they
# are only marked orange. on, chosen: each is continued by itself, a minute
# after the reset (src/auto-continue.ps1).
# Each cut-off is asked about once: an answer leaves a marker in data/auto,
# which the automatic mode reads too, so a cut-off answered here is never
# queued there - and one it queued is never asked about.

# The wait after a reset before the ask: a chat open in a VS Code panel may
# be continued by Claude Code itself meanwhile, one wait for all keeps it to
# one prompt, and a fresh usage figure is in by then.
$script:ChatqAskAfterMinutes = 5

function Get-ChatqAutoContinue {
    # 'on', 'ask' or 'off'. Only the word "on" is on: true, as the spec
    # once wrote the switch, reads as ask with anything else - missing or
    # unknown - so nothing written before the automatic mode existed turns
    # it on. $false and "false" are off. -Cfg: config.json already read.
    param($Cfg)
    if ($null -eq $Cfg) { $Cfg = Get-ChatqConfig }
    $v = Get-ChatField $Cfg 'autoContinue'
    if ($v -is [bool]) { if ($v) { return 'ask' } else { return 'off' } }
    $w = ([string]$v).Trim().ToLowerInvariant()
    if ($w -in 'off', 'false') { return 'off' }
    if ($w -eq 'on') { return 'on' }
    return 'ask'
}

function Set-ChatqAutoContinue {
    # config.json's top-level autoContinue, not overlay's: the watcher reads
    # it too. The one writer every surface goes through. Prints nothing;
    # returns the value - what to say about it is the caller's
    # (Get-ChatqAutoSwitchSay).
    param([Parameter(Mandatory)][ValidateSet('on', 'ask', 'off')][string]$Value)
    Lock-ChatqConfig
    try {
        $cfg = Get-ChatqConfig
        # turned on now: only cut-offs from here on are continued (since)
        if ($Value -eq 'on' -and (Get-ChatqAutoContinue $cfg) -ne 'on') { Reset-ChatqAutoSince }
        Set-ChatqProp $cfg 'autoContinue' $Value
        Save-ChatqConfig $cfg
    }
    finally { Unlock-ChatqConfig }
    return $Value
}

function Get-ChatqCutKey {
    # The name of one cut-off: the chat and the limit record that stopped it,
    # so the same chat cut off again later is a new one. Old records have no
    # uuid; the time stands in. $null when it would not make a file name.
    param($Row)
    $id = [string](Get-ChatField $Row 'Id')
    if (-not $id) { return $null }
    $u = [string](Get-ChatField $Row 'LimitUuid')
    if ($u) { $k = "${id}_$u" }
    else {
        $at = Get-ChatField $Row 'At'
        if ($at -isnot [datetime]) { $at = ConvertTo-ChatqDate $at }
        if (-not $at) { return $null }
        $k = "${id}_$($at.ToUniversalTime().Ticks)"
    }
    if ($k -cnotmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { return $null }
    return $k
}

function Save-ChatqAskAnswer {
    <#
    What you said about cut-offs, one data/auto/<key>.json each: when, the
    answer (continue or leave), where it was given and the jobs it made.
    CreateNew: one already there was answered first and is left as it is.
    Returns the keys written or found answered. Never throws - the caller
    logs what did not go. -Extra: more fields by key - the chat's session
    id and its reset, which the automatic mode reads to hold a later
    cut-off of that chat with the same reset (Get-ChatqAutoState).
    #>
    param([string[]]$Keys, [ValidateSet('continue', 'leave')][string]$Answer, [string]$Source, [hashtable]$Seqs, [hashtable]$Extra)
    $out = [System.Collections.Generic.List[string]]::new()
    try { New-ChatqDir $script:ChatqAutoDir } catch { return @() }
    $enc = New-Object System.Text.UTF8Encoding $false
    foreach ($k in @($Keys)) {
        if (-not $k -or $k -cnotmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { continue }
        $p = Join-Path $script:ChatqAutoDir "$k.json"
        $seq = @()
        if ($Seqs -and $Seqs.ContainsKey($k)) { $seq = @(@($Seqs[$k]) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) }
        $o = [ordered]@{ at = (Get-ChatqStamp); answer = $Answer; source = $Source; seq = $seq }
        if ($Extra -and $Extra[$k]) { foreach ($n in @($Extra[$k].Keys)) { if (-not $o.Contains([string]$n)) { $o[[string]$n] = $Extra[$k][$n] } } }
        try {
            $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $b = $enc.GetBytes(($o | ConvertTo-Json -Depth 3)); $fs.Write($b, 0, $b.Length) }
            finally { $fs.Dispose() }
            $out.Add($k)
        }
        catch { if (Test-Path -LiteralPath $p) { $out.Add($k) } }
    }
    return $out.ToArray()
}

function Read-ChatqAskMarks {
    # key -> $true for every data/auto/<key><Ext>; markers over 8 days old -
    # long past any cut-off still asked about - are deleted on the way
    param([string]$Ext)
    $out = @{}
    try {
        if (-not (Test-Path -LiteralPath $script:ChatqAutoDir)) { return $out }
        $old = (Get-Date).ToUniversalTime().AddDays(-8)
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ChatqAutoDir -File -EA SilentlyContinue)) {
            if ($f.Extension -notin '.json', '.shown') { continue }
            if ($f.LastWriteTimeUtc -lt $old) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue; continue }
            if ($f.Extension -eq $Ext -and $f.BaseName -cmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { $out[$f.BaseName] = $true }
        }
    }
    catch {}
    return $out
}

function Read-ChatqAskState {
    # the cut-offs answered already: key -> $true. Never throws.
    return (Read-ChatqAskMarks '.json')
}

function Read-ChatqAskShown {
    # the cut-offs whose prompt was announced already - toast, notification,
    # phone - so an overlay restarted does not announce them again
    return (Read-ChatqAskMarks '.shown')
}

function Add-ChatqAskShown {
    # an empty data/auto/<key>.shown each; never throws
    param([string[]]$Keys)
    try { New-ChatqDir $script:ChatqAutoDir } catch { return }
    foreach ($k in @($Keys)) {
        if (-not $k -or $k -cnotmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { continue }
        try { ([System.IO.File]::Open((Join-Path $script:ChatqAutoDir "$k.shown"), [System.IO.FileMode]::CreateNew)).Dispose() } catch {}
    }
}

function Get-ChatqResetAsk {
    <#
    Which chats the limit cut off can be offered a continue now - one prompt
    for all of them - or $null. Pure. A row is in when it was the usage limit
    (a 529 has no reset to wait for), that reset is at least
    $script:ChatqAskAfterMinutes behind -Now and under 12 hours behind, no
    job is queued or running for it, and it was not answered (-Asked, by
    Get-ChatqCutKey). -Held: session ids open where their own claude will
    continue them - a terminal - which go to Left instead, to be named.
    -Limited: a 5h or week window is at its limit with its reset ahead; the
    chats could not go yet, so nothing is asked until then.
    A chat a window's restart cut off (Get-ChatRestartCutOffs, Why
    restart) is in the same ask, with no reset to wait for: while its
    cut-off is under 12 hours old, and not while at the limit - it could
    not go either. -RestartOnly: those alone, for the automatic mode, which
    queues the limit's by itself but never a restart's. Restart counts
    them; ResetsAt is the latest reset, $null when only restarts are in.
    #>
    param([object[]]$CutOff, [hashtable]$Held, [hashtable]$Asked, [object[]]$Jobs, [bool]$Limited, [datetime]$Now = (Get-Date), [switch]$RestartOnly)
    if ($Limited) { return $null }
    $busy = @{}
    foreach ($j in @($Jobs)) { if ($j -and $j.state -in 'queued', 'running' -and $j.sessionId) { $busy[[string]$j.sessionId] = $true } }
    $in = [System.Collections.Generic.List[object]]::new()
    $left = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($CutOff)) {
        if (-not $r) { continue }
        $why = [string](Get-ChatField $r 'Why')
        $reset = $null
        if ($why -eq 'restart') {
            $at = Get-ChatField $r 'At'
            if ($at -isnot [datetime]) { $at = ConvertTo-ChatqDate $at }
            if (-not $at -or $at -le $Now.AddHours(-12)) { continue }
        }
        elseif ($why -ne 'limit' -or $RestartOnly) { continue }
        else {
            # old records carry no reset: never asked about, their orange row stays
            $reset = Get-ChatField $r 'ResetsAt'
            if ($reset -isnot [datetime]) { $reset = ConvertTo-ChatqDate $reset }
            if (-not $reset) { continue }
            if ($reset.AddMinutes($script:ChatqAskAfterMinutes) -gt $Now -or $reset -le $Now.AddHours(-12)) { continue }
        }
        $id = [string](Get-ChatField $r 'Id')
        if ($busy[$id]) { continue }
        $key = Get-ChatqCutKey $r
        if (-not $key -or ($Asked -and $Asked[$key])) { continue }
        if ($Held -and $Held[$id]) { $left.Add([pscustomobject]@{ Title = [string](Get-ChatField $r 'Title'); Why = 'terminal' }); continue }
        $in.Add([pscustomobject]@{ Row = $r; Key = $key; Reset = $reset })
    }
    if (-not $in.Count) { return $null }
    $zero = [datetime]::MinValue
    $sorted = @($in | Sort-Object @{ Expression = { $a = Get-ChatField $_.Row 'At'; if ($a -isnot [datetime]) { $a = ConvertTo-ChatqDate $a }; if ($a) { $a } else { $zero } }; Descending = $true })
    $latest = $null
    foreach ($x in $sorted) { if ($x.Reset -and (-not $latest -or $x.Reset -gt $latest)) { $latest = $x.Reset } }
    return [pscustomobject]@{
        ResetsAt = $latest
        Items = @($sorted | ForEach-Object { $_.Row })
        Keys = @($sorted | ForEach-Object { $_.Key })
        Count = $sorted.Count
        Restart = @($sorted | Where-Object { [string](Get-ChatField $_.Row 'Why') -eq 'restart' }).Count
        Left = $left.ToArray()
    }
}

function Format-ChatqAskHead {
    <#
    What the reset ask is about, first in its every wording - the banner,
    the tray's balloon, the Mac's notice, the phone, the console: "limit
    over at 13:00" for chats the limit cut off, "VS Code restarted" for
    those a window's restart did, both joined when it is both. -Ask:
    Get-ChatqResetAsk's answer or the snapshot's header.ask (count,
    restart, resetsAt in ms). Pure.
    #>
    param($Ask, [datetime]$Now = (Get-Date))
    $n = [int](Get-ChatField $Ask 'Count')
    $r = [int](Get-ChatField $Ask 'Restart')
    $at = Format-ChatOverlayAskAt (Get-ChatField $Ask 'ResetsAt') $Now
    $limit = "limit over$(if ($at) { " at $at" })"
    if ($r -le 0) { return $limit }
    if ($r -ge $n) { return 'VS Code restarted' }
    return "$limit, and VS Code restarted"
}

function Format-ChatqAskCount {
    # "1 chat it cut off" / "3 chats they cut off" - the limit, the restart,
    # or the two of them - for the ask's words after its head. Pure.
    param($Ask)
    $n = [int](Get-ChatField $Ask 'Count')
    $r = [int](Get-ChatField $Ask 'Restart')
    $who = if ($r -gt 0 -and $r -lt $n) { 'they' } else { 'it' }
    return "$n chat$(if ($n -ne 1) { 's' }) $who cut off"
}

function Format-ChatqAskLeaveTip {
    # What leaving them does, for the ask's Leave tooltip - the chip, the
    # tray, the console. A chat the limit cut off keeps its orange row,
    # which Continue all still reaches; one a VS Code restart cut off is
    # not offered again and its row goes, since its note forgets it once
    # answered (Get-ChatRestartCutOffs). -Ask: as Format-ChatqAskCount's.
    # Pure.
    param($Ask)
    $n = [int](Get-ChatField $Ask 'Count')
    $r = [int](Get-ChatField $Ask 'Restart')
    if ($r -le 0) { return 'Leave them as they are - their rows stay orange; Continue all in the console still continues them' }
    if ($r -ge $n) { return 'Leave them as they are - a chat a VS Code restart cut off is not offered again, and its row goes' }
    return 'Leave them as they are - the limit''s keep their orange rows, which Continue all in the console still continues; those a VS Code restart cut off are not offered again, and their rows go'
}

function Format-ChatqContinueTip {
    # What Continue queues, for the console's Continue and Continue all
    # tooltips: Claude Code's own "Continue from where you left off." for a
    # chat the limit or a 529 cut off, and for one a VS Code restart did, a
    # prompt that first says what the restart ended (Get-ChatqRestartPrompt).
    # -Count: the chats, -Restart: how many of them a restart cut off. Pure.
    param([int]$Count, [int]$Restart)
    if ($Restart -le 0) { return "Queue ""$($script:ChatqContinueText)"" for $(if ($Count -eq 1) { 'this chat' } else { 'each of them' })" }
    $say = 'a prompt that says what the VS Code restart ended, then "' + $script:ChatqContinueText + '"'
    if ($Count -eq 1) { return "Queue $say, for this chat" }
    if ($Restart -ge $Count) { return "Queue, for each of them, $say" }
    return "Queue ""$($script:ChatqContinueText)"" for each of them - for those a VS Code restart cut off, $say"
}

function Get-ChatqRestartPrompt {
    <#
    The prompt that continues a chat a window's restart cut off
    (Get-ChatRestartCutOffs' row): what happened, what was lost, and the
    words Claude Code's own continue uses. A background workflow or agent
    is named - claude --resume brings the chat back, not the work it had
    out, so Claude has to be told to start again what is still wanted.
    Pure.
    #>
    param($Row)
    $mid = [bool](Get-ChatField $Row 'Mid')
    $say = "The VS Code window this chat ran in restarted while it worked, which ended its process$(if ($mid) { ' mid-turn' })."
    $names = @(@(Get-ChatField $Row 'Tasks') | Where-Object { $_ } | ForEach-Object {
            $k = [string](Get-ChatField $_ 'Kind')
            if ($k -notin 'workflow', 'agent') { $k = 'task' }
            $note = [string](Get-ChatField $_ 'Note')
            if (-not $note) { $note = [string](Get-ChatField $_ 'Id') }
            $note = ($note -replace '\s+', ' ').Trim()
            if ($note.Length -gt 80) { $note = $note.Substring(0, 79).TrimEnd() + '...' }
            "$k `"$note`""
        })
    if ($names.Count) {
        $list = if ($names.Count -eq 1) { $names[0] } else { (($names[0..($names.Count - 2)]) -join ', ') + ' and ' + $names[-1] }
        $say += " Your background $list did not finish: resuming the chat does not bring background work back, so start again whatever of it is still needed."
    }
    return "$say $($script:ChatqContinueText)"
}

#endregion

#region job store -------------------------------------------------------------
# One JSON file per job plus the prompt as its own .md, so the prompt can be
# opened and edited in place - it is read again at send time.
# Ownership, so nothing needs a lock: the shell creates jobs, deletes ones not
# running, and flips failed/needs-input back to queued; every move out of
# queued is the watcher's. Cancelling a running job goes through a flag file.
# The one overlap: the watcher holds a queued job for seconds of checks, and
# the shell, the console or the phone may delete it meanwhile - so what the
# watcher writes after them goes -Existing, and a deleted job stays deleted.

function New-ChatqDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Open-ChatqLock {
    # A lock file opened with no sharing, or $null when it cannot be had in
    # 3 s of tries; each caller throws its own words for that. A wait of its
    # own length each time: two writers retrying in step would otherwise let
    # one of them take it every time.
    param([string]$Path)
    New-ChatqDir $script:ChatqData
    $h = $null
    $until = (Get-Date).AddSeconds(3)
    while (-not $h) {
        try { $h = [System.IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ((Get-Date) -gt $until) { break }
            Start-Sleep -Milliseconds (Get-Random -Minimum 15 -Maximum 60)
        }
    }
    return $h
}

function Invoke-ChatCompile {
    <#
    A C# compile - Add-Type given a type's source - with its working files in
    data/tmp: csc writes them under TEMP as it runs, and nothing of this
    tool goes there. Each compile has a folder of its own there, taken away
    after it: the compiler leaves a folder in TEMP until the process exits,
    and a process killed never takes it away. One killed mid-compile
    leaves its folder in data/tmp, so a compile takes away any there a day
    old - none is in use that long, a compile taking a second. TEMP is put
    back after, as WPF and every process started later take theirs from
    this one. csc cannot work in a TEMP over 210 characters - it fails, and
    past 260 hangs - nor in one with a character this PC's code page
    lacks. A compile's folder past 200 characters or with such a
    character, or one that cannot be made, leaves the compile where it
    always was.
    #>
    param([scriptblock]$Compile)
    $was = $env:TMP, $env:TEMP
    $own = $null
    try {
        $name = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName())
        $dir = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $script:ChatqData 'tmp') $name))
        $ansi = [System.Text.Encoding]::Default
        if ($dir.Length -le 200 -and $ansi.GetString($ansi.GetBytes($dir)) -ceq $dir) {
            foreach ($old in @(try { [System.IO.Directory]::GetDirectories([System.IO.Path]::GetDirectoryName($dir)) } catch {})) {
                try { if ([System.IO.Directory]::GetCreationTimeUtc($old) -lt [datetime]::UtcNow.AddDays(-1)) { [System.IO.Directory]::Delete($old, $true) } } catch {}
            }
            $null = [System.IO.Directory]::CreateDirectory($dir)
            $own = $dir
            $env:TMP = $own
            $env:TEMP = $own
        }
    }
    catch {}
    try { & $Compile }
    finally {
        if ($own) {
            $env:TMP = $was[0]
            $env:TEMP = $was[1]
            try { [System.IO.Directory]::Delete($own, $true) } catch {}
        }
    }
}

function Save-ChatqText {
    # UTF-8 without a BOM, written aside and swapped in, so a reader - the
    # watcher, the board preview - never sees half a file
    param([string]$Path, [string]$Text)
    New-ChatqDir (Split-Path $Path -Parent)
    $tmp = "$Path.tmp"
    $enc = New-Object System.Text.UTF8Encoding $false
    for ($try = 1; $try -le 5; $try++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $Text, $enc)
            # [NullString]::Value, not $null: PowerShell hands $null to a .NET
            # string parameter as "", and "" is not a legal backup path
            if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        }
        catch {
            if ($try -eq 5) { throw }
            Start-Sleep -Milliseconds (100 * $try)
        }
    }
}

function Update-ChatqText {
    # Save-ChatqText over a file that must still be there: File.Replace
    # alone, never the Move, so a file deleted meanwhile stays deleted -
    # $false then, and the copy aside dropped. A reader holding it open is
    # waited out, as there.
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    $enc = New-Object System.Text.UTF8Encoding $false
    for ($try = 1; $try -le 5; $try++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $Text, $enc)
            [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
            return $true
        }
        catch {
            if (-not (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; return $false }
            if ($try -eq 5) { throw }
            Start-Sleep -Milliseconds (100 * $try)
        }
    }
}

function Read-ChatqJson {
    param([string]$Path)
    for ($try = 1; $try -le 3; $try++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
    return $null
}

function Get-ChatqStamp {
    # UTC round-trip, so the strings sort in time order as they are
    (Get-Date).ToUniversalTime().ToString('o')
}

function Get-ChatqJobs {
    # Every file read and parsed each call, each job a new object: of some
    # 40 callers many change what they get, so a cache of parsed jobs would
    # have to hand out copies, and a copy costs what the parse does. 1.2 ms
    # a file in a trial - 24 ms at 20 jobs, 114 at 100 - and the overlay
    # reads it only as a job file changes.
    if (-not (Test-Path -LiteralPath $script:ChatqQueueDir)) { return @() }
    $jobs = foreach ($f in @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Filter *.json -File -EA SilentlyContinue)) {
        $j = Read-ChatqJson $f.FullName
        if ($j -and $j.id) { $j }
    }
    # The one queue order, which the watcher, the "sends" column, the list and
    # the board all walk: jobs put first (the latest -First ahead), then the
    # continues, then the rest - each oldest first, and by number where two
    # were made within the clock's tick. A continue picks up work the limit
    # cut off, so it never waits behind prompts queued for other chats; the
    # chats Continue all names keep the order it named them in. The continue
    # of a chat a window's restart cut off (rule restart) is a prompt - it
    # says what the restart took (Get-ChatqRestartPrompt) - and goes with
    # the continues all the same. A lane that is waiting is skipped as a
    # whole, so "first" means the front of its own lane.
    # Dates, not strings: pwsh 7 reads the stamps back as [datetime], whose
    # string form does not sort in time order.
    $zero = [datetime]::MinValue
    return @($jobs | Sort-Object @{ Expression = { if ($_.PSObject.Properties['first'] -and $_.first) { 0 } elseif ($_.kind -eq 'continue' -or [string](Get-ChatField $_ 'rule') -eq 'restart') { 1 } else { 2 } } },
        @{ Expression = { $d = if ($_.PSObject.Properties['first']) { ConvertTo-ChatqDate $_.first } else { $null }; if ($d) { $d } else { $zero } }; Descending = $true },
        @{ Expression = { $d = ConvertTo-ChatqDate $_.createdAt; if ($d) { $d } else { $zero } } },
        @{ Expression = { [int]$_.seq } })
}

function Save-ChatqJob {
    # -Existing: only over its file, never making it again - for a copy
    # read before seconds of checks, whose job may have been removed
    # meanwhile. Returns whether it saved, then only.
    param($Job, [switch]$Existing)
    $path = Join-Path $script:ChatqQueueDir "$($Job.id).json"
    if ($Existing) { return (Update-ChatqText $path ($Job | ConvertTo-Json -Depth 8)) }
    Save-ChatqJson $path $Job
}

function Save-ChatqJson {
    param([string]$Path, $Object)
    Save-ChatqText $Path ($Object | ConvertTo-Json -Depth 8)
}

function Add-ChatqLogLine {
    # One stamped line onto data/logs/<Name>, the file rolled to <Name>.1
    # past 1 MB; UTF-8 without a BOM. No try of its own: each log's writer
    # keeps its catch, and whatever it does after the write.
    param([string]$Name, [string]$Line)
    New-ChatqDir $script:ChatqLogDir
    $p = Join-Path $script:ChatqLogDir $Name
    if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 1MB) { Move-Item -LiteralPath $p -Destination "$p.1" -Force }
    [System.IO.File]::AppendAllText($p, "$((Get-Date).ToString('o'))  $Line`n", (New-Object System.Text.UTF8Encoding $false))
}

function Write-ChatqJobLog {
    # Every move a job makes, in one file that outlives it. A job's own history
    # goes with its file, so a chatqrm used to leave no trace at all - where a
    # job went could only be guessed from the watcher logging an empty queue.
    # Best effort: the watcher and a shell both append, and a line lost to a
    # collision is better than either of them stopping over a diary.
    param([string]$Text)
    try {
        Add-ChatqLogLine 'jobs.log' $Text
    }
    catch {}
}

function Set-ChatqJobState {
    # -Existing: as Save-ChatqJob's - a job removed meanwhile is left gone,
    # and the diary says nothing of it; returns whether it moved, then only
    param($Job, [string]$State, [string]$Why, [switch]$Existing)
    $Job.state = $State
    $Job.history = @(@($Job.history) + [pscustomobject]@{ at = (Get-ChatqStamp); state = $State; why = $Why })
    if ($Existing) { if (-not (Save-ChatqJob $Job -Existing)) { return $false } }
    else { Save-ChatqJob $Job }
    Write-ChatqJobLog "#$($Job.seq) $State$(if ($Why) { " - $Why" }) $($script:ChatqDot) $($Job.title)"
    if ($Existing) { return $true }
}

function Find-ChatqJob {
    # by the #n shown in lists, or by (a prefix of) the id. A job queued for
    # the same chat in the same second is that id with -2 after it, so a
    # whole id is only ever that job: once it is gone, a prefix match would
    # hand back its sibling, and a skip or a recheck would act on the wrong
    # job. -Exact is for callers that hold a stored id; a ref shaped like a
    # whole id (20260927-101500-ab12, -2 after it or not) is taken exactly
    # too. Prefixes are for what a user types.
    param([string]$Ref, [object[]]$Jobs, [switch]$Exact)
    if (-not $Jobs) { $Jobs = @(Get-ChatqJobs) }
    $r = $Ref.Trim().TrimStart('#')
    if (-not $r) { return $null }
    if (-not $Exact -and $r -match '^\d+$') { return @($Jobs | Where-Object { [int]$_.seq -eq [int]$r }) | Select-Object -First 1 }
    # not $exact: names ignore case, and -Exact is a switch
    $whole = @($Jobs | Where-Object { [string]$_.id -eq $r })
    if ($whole.Count -eq 1) { return $whole[0] }
    if ($Exact -or $r -match '^\d{8}-\d{6}-[0-9A-Za-z]{4}(-\d+)?$') { return $null }
    $hit = @($Jobs | Where-Object { $_.id -like "$r*" })
    if ($hit.Count -eq 1) { return $hit[0] }
    return $null
}

function Get-ChatqPromptPath {
    param($Job)
    Join-Path $script:ChatqQueueDir $Job.promptFile
}

function Read-ChatqPrompt {
    # the file as it is now - edits made after queueing count
    param($Job)
    $p = Get-ChatqPromptPath $Job
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    return (Remove-ChatqPromptHeader $t)
}

function Remove-ChatqPromptHeader {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.TrimStart([char]0xFEFF)
    $t = [regex]::Replace($t, '^\s*<!--\s*chatq:.*?-->', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    return $t.Trim()
}

function Get-ChatqSafeName {
    # the prompt file is named after the chat, so the editor tab says which chat
    # it is for. % ^ & ! are legal in a filename but code.cmd hands the path
    # through cmd.exe, which would expand or eat them.
    param([string]$Text)
    $t = ($Text -replace '[\\/:*?"<>|%^&!\x00-\x1f]', '_' -replace '\s+', ' ').Trim()
    if ($t.Length -gt 50) { $t = $t.Substring(0, 50) }
    return $t.TrimEnd('.', ' ')
}

#endregion

#region attachments -----------------------------------------------------------
# A job's files live in data/queue/<job id>/, copied there when it is queued:
# the original may move or change in the hours before the job sends, and by
# then the clipboard holds whatever was copied last. What is in that folder
# when the job sends is what goes - delete a file there to drop it.
# A link in the prompt is an attachment only when it points into data/queue/,
# where VS Code saves an image pasted into the prompt tab. A link to any other
# file names that file where it is, for the chat to open or change there.
# Neither CLI needs more than a path for most of it. Claude Code opens an
# image with its own Read tool and sees the picture, and reads text and PDF the
# same way - named in the prompt, from outside the project, in the strictest
# unattended mode (spike S18). Codex also takes images properly, with -i.

$script:ChatqImageExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp')
$script:ChatqAttachWarnCount = 10
$script:ChatqAttachWarnBytes = 20MB

function Get-ChatqAttachDir {
    param($Job)
    Join-Path $script:ChatqQueueDir $Job.id
}

function Get-ChatqAttachments {
    # in the order they were added: a copy is created when it is made, whatever
    # time its original says
    param($Job)
    $d = Get-ChatqAttachDir $Job
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -File -EA SilentlyContinue | Sort-Object CreationTimeUtc, Name)
}

function Add-ChatqAttachment {
    # One file in, under a name nothing else in the folder has, with no space
    # in it: a markdown link breaks on one. Moved rather than copied when asked
    # - a file VS Code saved beside the prompt belongs to nobody else.
    param([string]$Dir, [string]$Source, [switch]$Move)
    New-ChatqDir $Dir
    $name = ([System.IO.Path]::GetFileName($Source)) -replace '[^\w.\-]+', '-'
    if (-not $name.Trim('.', '-')) { $name = 'file' }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $ext = [System.IO.Path]::GetExtension($name)
    $dest = Join-Path $Dir $name
    for ($n = 2; Test-Path -LiteralPath $dest; $n++) { $dest = Join-Path $Dir "$base-$n$ext" }
    # Stop, so a file gone or locked since it was checked throws: both cmdlets
    # otherwise only print their error, and the job would go without the file
    if ($Move) { Move-Item -LiteralPath $Source -Destination $dest -ErrorAction Stop }
    else { Copy-Item -LiteralPath $Source -Destination $dest -ErrorAction Stop }
    # a copy keeps its original's times, and the order goes by when it came in
    $f = Get-Item -LiteralPath $dest -ErrorAction Stop
    try { $f.CreationTimeUtc = [datetime]::UtcNow } catch {}
    return $f
}

function Add-ChatqAttachmentBytes {
    param([string]$Dir, [string]$Name, [byte[]]$Bytes)
    New-ChatqDir $Dir
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [System.IO.Path]::GetExtension($Name)
    $dest = Join-Path $Dir $Name
    for ($n = 2; Test-Path -LiteralPath $dest; $n++) { $dest = Join-Path $Dir "$base-$n$ext" }
    [System.IO.File]::WriteAllBytes($dest, $Bytes)
    return (Get-Item -LiteralPath $dest)
}

function Get-ChatqPromptLinks {
    # The files a prompt links to inside data/queue/ - ![alt](path) or
    # [text](path), relative to the prompt file, which is what VS Code writes
    # when an image is pasted, or a media file dropped, into the prompt tab.
    # Nothing outside is even looked at. A link to a project file names it
    # where it is: copied, the chat would read and edit a snapshot instead.
    # ../config.json would reach chatq's own data, and testing a \\host path
    # opens an SMB connection to that host.
    # Every occurrence, with where its target sits in the text, so a rewrite
    # touches that link and no other - a plain replace of "(image.png" would
    # also rewrite "(image.png.bak)".
    param([string]$Text)
    if (-not $Text) { return @() }
    $queue = [System.IO.Path]::GetFullPath($script:ChatqQueueDir).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    # one level of parentheses inside a target: shot(1).png is a name
    $rx = '!?\[[^\]\r\n]*\]\(\s*(<[^>\r\n]+>|(?:[^()\s]|\([^()\s]*\))+)(?:\s+"[^"\r\n]*")?\s*\)'
    return @(foreach ($m in [regex]::Matches($Text, $rx)) {
            $g = $m.Groups[1]
            $p = $g.Value.Trim('<', '>').Trim()
            if ($p -match '^[a-zA-Z]:[\\/]') { $cand = $p }                             # a drive path
            elseif ($p -match '^[a-zA-Z][\w+.-]*:' -or $p -match '^[\\/]{2}') { continue }   # a URL, file: too, or a share
            else { $cand = Join-Path $script:ChatqQueueDir ([uri]::UnescapeDataString($p)) }
            # decided on the string alone, before anything touches a disk; an
            # anchor like #top simply names no file in there
            $full = try { [System.IO.Path]::GetFullPath($cand) } catch { continue }
            if (-not $full.StartsWith($queue, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            [pscustomobject]@{ Index = $g.Index; Length = $g.Length; Path = $full }
        })
}

function Sync-ChatqAttachments {
    # Bring the files the prompt links to in data/queue/ into the job's own
    # folder, and point each link there. A pasted image belongs to nobody, so
    # it moves - out of a folder VS Code made for it too, which then goes if
    # empty. One in another job's folder is that job's, and is copied. Run when
    # the job is queued and again just before it sends, so an image pasted into
    # a prompt reopened with chatq <n> counts. Returns the files it could not
    # bring in.
    param($Job)
    $pp = Get-ChatqPromptPath $Job
    if (-not (Test-Path -LiteralPath $pp)) { return @() }
    $text = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8)
    $dir = [System.IO.Path]::GetFullPath((Get-ChatqAttachDir $Job))
    $queue = [System.IO.Path]::GetFullPath($script:ChatqQueueDir).TrimEnd('\', '/')
    # read once, before anything moves - a moved file is no longer where its
    # link says, and would drop out of a second reading
    $links = @(Get-ChatqPromptLinks $text)
    $new = @{}
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $links) {
        # one copy per file, however many times the prompt links it
        $key = $l.Path.ToLowerInvariant()
        if ($new.ContainsKey($key)) { continue }
        # already the job's own
        if ($l.Path.StartsWith($dir + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rel = $l.Path.Substring($queue.Length + 1)
        $top = ($rel -split '[\\/]', 2)[0]
        $atRoot = $rel -notmatch '[\\/]'
        # never the queue's own files - a job, its prompt, a cancel
        if ($atRoot -and [System.IO.Path]::GetExtension($rel) -in '.md', '.json', '.cancel') { continue }
        $otherJob = -not $atRoot -and (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$top.json"))
        $f = try { Add-ChatqAttachment $dir $l.Path -Move:(-not $otherJob) } catch { $failed.Add($l.Path); $null }
        if (-not $f) { continue }
        $new[$key] = "$($Job.id)/$($f.Name)"
        if (-not $atRoot -and -not $otherJob) {
            $from = Split-Path -Parent $l.Path
            if (-not @(Get-ChildItem -LiteralPath $from -Force -EA SilentlyContinue).Count) { Remove-Item -LiteralPath $from -Force -EA SilentlyContinue }
        }
    }
    if ($new.Count) {
        # from the end backwards, so each rewrite leaves the earlier positions true
        $sb = [System.Text.StringBuilder]::new($text)
        foreach ($l in @($links | Sort-Object Index -Descending)) {
            $to = $new[$l.Path.ToLowerInvariant()]
            if ($to) { [void]$sb.Remove($l.Index, $l.Length).Insert($l.Index, $to) }
        }
        Save-ChatqText $pp $sb.ToString()
    }
    return @($failed)
}

# How old a file in data/queue/ that no prompt links to must be before the
# sweep takes it (Clear-ChatqStrayFiles)
$script:ChatqStrayHours = 24

function Clear-ChatqStrayFiles {
    <#
    Sweep the images VS Code saved into data/queue/ for a prompt tab that was
    then cancelled: nothing moves them into a job's folder, and nothing else
    ever would. Removing what appeared while that tab was open would also take
    an image pasted at that moment into another shell's open tab, so it goes
    by age instead: a file no prompt links to, a day old (-Hours) by the newer
    of its creation and write times. A tab open a day with the link still
    unsaved in it loses its image; a saved one keeps it.
    Only what VS Code can have put there: a file at the root that is none of
    the queue's own (a job, its prompt, a cancel, a write in flight), or one
    in a folder that is no job's - a folder named as a job id is its job's,
    whole, even before its .json is written (New-ChatqJobSlot makes it
    first). Such a folder goes once empty and as old. Any prompt that cannot
    be read stops the sweep: its links are unknown, and the file may be its.
    The watcher runs it at its start and every six hours. Returns the paths
    removed.
    #>
    param([double]$Hours = $script:ChatqStrayHours, $Now = $null)
    $queue = $script:ChatqQueueDir
    if (-not (Test-Path -LiteralPath $queue -PathType Container)) { return @() }
    $cut = $(if ($Now) { ([datetime]$Now).ToUniversalTime() } else { [datetime]::UtcNow }).AddHours(-$Hours)
    $old = { param($i) $t = $i.LastWriteTimeUtc; if ($i.CreationTimeUtc -gt $t) { $t = $i.CreationTimeUtc }; $t -lt $cut }
    $linked = @{}
    try {
        foreach ($p in @(Get-ChildItem -LiteralPath $queue -Filter *.md -File -EA Stop)) {
            $text = [System.IO.File]::ReadAllText($p.FullName, [System.Text.Encoding]::UTF8)
            foreach ($l in @(Get-ChatqPromptLinks $text)) { $linked[$l.Path.ToLowerInvariant()] = $true }
        }
    }
    catch { return @() }
    $gone = [System.Collections.Generic.List[string]]::new()
    $drop = {
        param($i)
        if ($linked[$i.FullName.ToLowerInvariant()] -or -not (& $old $i)) { return }
        try { Remove-Item -LiteralPath $i.FullName -Force -ErrorAction Stop; $gone.Add($i.FullName) } catch {}
    }
    foreach ($i in @(Get-ChildItem -LiteralPath $queue -Force -EA SilentlyContinue)) {
        if (-not $i.PSIsContainer) {
            if ($i.Extension -notin '.md', '.json', '.cancel', '.tmp') { & $drop $i }
            continue
        }
        if ($i.Name -match '^\d{8}-\d{6}-' -or (Test-Path -LiteralPath (Join-Path $queue "$($i.Name).json"))) { continue }
        # a folder's age as it was before the sweep - taking a file out of it
        # makes its write time now. Deepest first, so a folder emptied of
        # folders goes too.
        $dirs = @(@(Get-ChildItem -LiteralPath $i.FullName -Recurse -Directory -Force -EA SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending) + @($i) |
            Where-Object { & $old $_ })
        foreach ($f in @(Get-ChildItem -LiteralPath $i.FullName -Recurse -File -Force -EA SilentlyContinue)) { & $drop $f }
        foreach ($d in $dirs) {
            if (@(Get-ChildItem -LiteralPath $d.FullName -Force -EA SilentlyContinue).Count) { continue }
            try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop; $gone.Add($d.FullName) } catch {}
        }
    }
    return @($gone)
}

function Format-ChatqAttachFooter {
    # The wording both CLIs were seen to act on in spike S18: every file read,
    # the images looked at
    param([object[]]$Files)
    if (-not $Files) { return '' }
    return "`n`nAttached files - read each one:`n" + (($Files | ForEach-Object { "- $($_.FullName)" }) -join "`n")
}

function Format-ChatqAttachSummary {
    param([object[]]$Files)
    $n = @($Files).Count
    if (-not $n) { return '' }
    $bytes = ($Files | Measure-Object -Property Length -Sum).Sum
    $mb = if ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) } else { '{0:N0} KB' -f [Math]::Max(1, $bytes / 1KB) }
    $names = ($Files | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ', '
    if ($n -gt 4) { $names += ", +$($n - 4) more" }
    return "$n file$(if ($n -ne 1) { 's' }) ($mb): $names"
}

function Read-ChatqAttachSources {
    # -Attach and -Paste, resolved while you are here: the files checked now -
    # one found missing at 3 a.m. could only fail the job - and the clipboard
    # read now, since by then it holds whatever was copied last. Nothing is
    # copied yet. Error set means nothing should be queued. Skipped: folders
    # the clipboard held, for the caller to mention.
    param([string[]]$Attach, [switch]$Paste)
    $r = [pscustomobject]@{ Error = $null; Files = [System.Collections.Generic.List[string]]::new(); Image = $null; Text = $null; Skipped = [System.Collections.Generic.List[string]]::new() }
    $seen = @{}
    foreach ($a in @($Attach | Where-Object { $_ })) {
        $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($a)
        # a name with [ ] in it is a name first; only one that is not a file
        # is tried as a wildcard - -Attach .\shots\*.png
        $hits = if (Test-Path -LiteralPath $p -PathType Leaf) { @($p) }
        elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($a)) {
            @(Get-ChildItem -Path $a -File -EA SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
        }
        else { @() }
        if (-not $hits) { $r.Error = "no such file: $a"; return $r }
        foreach ($h in $hits) {
            # the same file twice is sent once
            if (-not $seen.ContainsKey($h.ToLowerInvariant())) { $seen[$h.ToLowerInvariant()] = $true; $r.Files.Add($h) }
        }
    }
    if ($Paste) {
        $clip = Get-ChatqClipboard
        if (-not $clip) { $r.Error = 'the clipboard cannot be read here - give the file with -Attach instead'; return $r }
        foreach ($f in @($clip.Files)) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $r.Skipped.Add($f); continue }
            if (-not $seen.ContainsKey($f.ToLowerInvariant())) { $seen[$f.ToLowerInvariant()] = $true; $r.Files.Add($f) }
        }
        $r.Image = $clip.Image
        # text only when nothing else came: a copied image often brings its
        # caption or HTML along, and that is not what was meant
        if (-not $r.Image -and -not @($clip.Files).Count -and $clip.Text -and $clip.Text.Trim()) { $r.Text = $clip.Text }
        if (-not $r.Image -and -not $r.Files.Count -and -not $r.Text) {
            $r.Error = 'nothing on the clipboard to paste - copy a screenshot, some files or text first'
        }
    }
    return $r
}

function Save-ChatqAttachSources {
    # Into the job's folder; throws when one cannot be copied, having taken
    # back what this call copied - and only that: adding to a queued job, the
    # folder already holds files of its own. -Move: the files are the
    # console's own staged copies, so they move in, and move back on a
    # failure. Images: more than one pasted image, as @{ Name; Bytes }.
    param([string]$Dir, $Got, [switch]$Move)
    $added = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($s in @($Got.Files)) { if ($s) { $added.Add(@{ To = (Add-ChatqAttachment $Dir $s -Move:$Move).FullName; From = $(if ($Move) { $s }) }) } }
        if ($Got.Image) { $added.Add(@{ To = (Add-ChatqAttachmentBytes $Dir 'clip.png' $Got.Image).FullName }) }
        $more = if ($Got -is [hashtable]) { $Got['Images'] } elseif ($Got.PSObject.Properties['Images']) { $Got.Images } else { $null }
        foreach ($im in @($more)) { if ($im) { $added.Add(@{ To = (Add-ChatqAttachmentBytes $Dir ([string]$im.Name) ([byte[]]$im.Bytes)).FullName }) } }
        return @($added | ForEach-Object { $_.To })
    }
    catch {
        foreach ($a in $added) {
            if ($a.From) { Move-Item -LiteralPath $a.To -Destination $a.From -Force -EA SilentlyContinue }
            else { Remove-Item -LiteralPath $a.To -Force -EA SilentlyContinue }
        }
        if (-not @(Get-ChildItem -LiteralPath $Dir -Force -EA SilentlyContinue).Count) { Remove-Item -LiteralPath $Dir -Force -EA SilentlyContinue }
        throw
    }
}

# What the clipboard holds, read where the clipboard can be read: an STA
# thread. Windows PowerShell's console is one; where this shell is not, a
# child Windows PowerShell reads it. Either way it lands as files in a folder
# of data/ - not JSON: a screenshot in base64 is past the 2 MB that 5.1's
# ConvertFrom-Json will take. A "PNG" entry first, which keeps transparency
# and the exact bytes, then the plain bitmap a screenshot puts there. Text is
# written only when there is nothing else, the one case it is used in. The
# folder comes in through the environment, never spliced into the code: a
# path is not code, whatever quotes it holds.
$script:ChatqClipCode = @'
$Out = $env:CHATQ_CLIP_OUT
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$cb = [System.Windows.Forms.Clipboard]
$u8 = New-Object System.Text.UTF8Encoding $false
$got = $false
if ($cb::ContainsFileDropList()) {
    [System.IO.File]::WriteAllLines((Join-Path $Out 'files.txt'), [string[]]@($cb::GetFileDropList()), $u8)
    $got = $true
}
else {
    $png = $cb::GetData('PNG')
    if ($png -is [System.IO.MemoryStream]) { [System.IO.File]::WriteAllBytes((Join-Path $Out 'clip.png'), $png.ToArray()); $got = $true }
    elseif ($cb::ContainsImage()) {
        $img = $cb::GetImage()
        $img.Save((Join-Path $Out 'clip.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $img.Dispose()
        $got = $true
    }
}
if (-not $got -and $cb::ContainsText()) { [System.IO.File]::WriteAllText((Join-Path $Out 'clip.txt'), $cb::GetText(), $u8) }
'@

function Get-ChatqClipboard {
    # @{ Image = [byte[]]; Files = [string[]]; Text = [string] }, or $null where
    # it cannot be read
    if ($script:ChatqClipboardSeam) { return & $script:ChatqClipboardSeam }
    if (-not $script:ChatqIsWindows) { return $null }
    # one a killed shell left behind is swept up by the next read
    Get-ChildItem -LiteralPath $script:ChatqData -Directory -Filter 'clip-*' -EA SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } | Remove-Item -Recurse -Force -EA SilentlyContinue
    $out = Join-Path $script:ChatqData ('clip-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-ChatqDir $out
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
            $was = $env:CHATQ_CLIP_OUT
            $env:CHATQ_CLIP_OUT = $out
            try { & ([scriptblock]::Create($script:ChatqClipCode)) } finally { $env:CHATQ_CLIP_OUT = $was }
        }
        else {
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:ChatqClipCode))
            $null = Invoke-ChatqProcess -Exe $ps -ArgList @('-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', $enc) -StdIn '' -TimeoutSec 30 `
                -SetEnv @{ CHATQ_CLIP_OUT = $out }
        }
        $img = Join-Path $out 'clip.png'
        $lst = Join-Path $out 'files.txt'
        $txt = Join-Path $out 'clip.txt'
        return [pscustomobject]@{
            Image = if (Test-Path -LiteralPath $img) { [System.IO.File]::ReadAllBytes($img) } else { $null }
            Files = if (Test-Path -LiteralPath $lst) { @([System.IO.File]::ReadAllLines($lst, [System.Text.Encoding]::UTF8) | Where-Object { $_ }) } else { @() }
            Text  = if (Test-Path -LiteralPath $txt) { [System.IO.File]::ReadAllText($txt, [System.Text.Encoding]::UTF8) } else { $null }
        }
    }
    catch { return $null }
    finally { Remove-Item -LiteralPath $out -Recurse -Force -EA SilentlyContinue }
}

#endregion

#region external CLIs ---------------------------------------------------------

# Set in every shell a live Claude chat spawns (its Bash tool, a VS Code
# terminal it opened), and so in a watcher one of those started. A child that
# inherits them believes it is part of that session - its messaging socket, its
# session id, its effort - so none of them survive into a run. Some are the
# VS Code extension's own settings for its chats: MCP_CONNECTION_NONBLOCKING
# and CLAUDE_CODE_ENABLE_TASKS, and from Claude Code 2.1.284 the SDK's
# CLAUDE_CODE_SDK_READS_SESSION_STATE (extra stream lines for an SDK host). The
# API keys go too: with one set, claude -p bills the API instead of the
# subscription whose reset this whole tool is waiting for.
$script:ChatqEnvDrop = @(
    'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'CLAUDE_AGENT_SDK_VERSION',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_CODE_SESSION_ID',
    'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SSE_PORT',
    'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING', 'CLAUDE_CODE_ENABLE_TASKS',
    'CLAUDE_CODE_SDK_READS_SESSION_STATE', 'MCP_CONNECTION_NONBLOCKING',
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_API_KEY', 'CODEX_API_KEY'
)
$script:ChatqClaudeMin = '2.1.259'   # --permission-prompts none
# The first codex-cli whose app-server is taken to answer what the later
# Codex work needs - thread/list, turn/start, account/rateLimits/read. Only
# 0.159.2's schema was read, so this floor is a guess a spike has to pin
# (FUTURE_WORK, "The Codex app-server floor is a guess"). Start-ChatqCodexRpc
# gates on it: an older codex is never started, so the limit check falls
# back to its codex exec turn and the overlay keeps the rollout's figure -
# raising it turns both off for whatever falls below.
$script:ChatqCodexAppServerMin = '0.159.0'

function Find-ChatqExe {
    # Not cached: VS Code deletes the old extension folder when it updates, so a
    # path found at queue time can be gone by the time the limit resets.
    param([string]$Provider)
    $pick = Get-ChatqExePick $Provider
    if ($pick) { return $pick.Path }
    return $null
}

function Get-ChatqExePick {
    <#
    The claude or codex chatq runs, and where it was found: {Path, From},
    From one of CHATQ_CLAUDE / CHATQ_CODEX (the override), 'PATH', 'local'
    (Claude Code's own installer) or 'bundled' (an editor extension's copy),
    tried in that order. $null when there is none. Find-ChatqExe is this,
    path only; the doctor lines (Get-ChatqCliReport) need to know which.
    #>
    param([string]$Provider)
    $name = if ($Provider -eq 'codex') { 'codex' } else { 'claude' }
    $envName = if ($name -eq 'codex') { 'CHATQ_CODEX' } else { 'CHATQ_CLAUDE' }
    $override = if ($name -eq 'codex') { $env:CHATQ_CODEX } else { $env:CHATQ_CLAUDE }
    if ($override) { return [pscustomobject]@{ Path = $override; From = $envName } }
    $exe = if ($script:ChatqIsWindows) { "$name.exe" } else { $name }
    $local = @((Join-Path (Join-Path (Join-Path $HOME '.local') 'bin') $exe),
        (Join-Path (Join-Path $script:ChatClaudeHome 'local') $exe))
    $cmd = Get-Command $name -CommandType Application -EA SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        # Claude Code's own installer puts its folder on PATH: that copy is
        # 'local' however it was found - off PATH, it would still be the one
        # picked, so there is no extension's copy to send anyone to
        $isLocal = $name -eq 'claude' -and @($local | Where-Object { [string]::Equals($_, $cmd.Source, [StringComparison]::OrdinalIgnoreCase) }).Count
        return [pscustomobject]@{ Path = $cmd.Source; From = $(if ($isLocal) { 'local' } else { 'PATH' }) }
    }
    foreach ($p in $local) {
        if ($name -eq 'claude' -and (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Path = $p; From = 'local' } }
    }
    $b = Find-ChatqBundledExe $name
    if ($b) { return [pscustomobject]@{ Path = $b; From = 'bundled' } }
    return $null
}

function Find-ChatqBundledExe {
    # Both VS Code extensions ship their own copy and put none on PATH - on a
    # machine that only ever used the panel this is the only one there is.
    # The newest extension folder's, across VS Code and its forks; $null if
    # there is none.
    param([string]$Provider)
    $name = if ($Provider -eq 'codex') { 'codex' } else { 'claude' }
    $exe = if ($script:ChatqIsWindows) { "$name.exe" } else { $name }
    $homeDir = if ($script:ChatqExtHomeSeam) { $script:ChatqExtHomeSeam } else { $HOME }
    $pattern = if ($name -eq 'claude') { 'anthropic.claude-code-*' } else { 'openai.chatgpt-*' }
    $best = $null; $bestVer = $null
    foreach ($root in '.vscode', '.vscode-insiders', '.cursor', '.windsurf') {
        $ext = Join-Path (Join-Path $homeDir $root) 'extensions'
        if (-not (Test-Path -LiteralPath $ext)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $ext -Directory -Filter $pattern -EA SilentlyContinue)) {
            if ($d.Name -notmatch '-(\d+(?:\.\d+){1,3})(?:-|$)') { continue }
            $ver = $null
            if (-not [version]::TryParse($Matches[1], [ref]$ver)) { continue }
            $bin = if ($name -eq 'claude') {
                Join-Path (Join-Path (Join-Path $d.FullName 'resources') 'native-binary') $exe
            }
            else {
                $b = Join-Path $d.FullName 'bin'
                if (Test-Path -LiteralPath $b) {
                    Get-ChildItem -LiteralPath $b -Recurse -Filter $exe -File -EA SilentlyContinue |
                        Select-Object -First 1 -ExpandProperty FullName
                }
            }
            if ($bin -and (Test-Path -LiteralPath $bin) -and (-not $bestVer -or $ver -gt $bestVer)) {
                $best = $bin; $bestVer = $ver
            }
        }
    }
    return $best
}

function Get-ChatqCliVersion {
    # Cached by path for the process's life. -Fresh asks again: an upgrade in
    # place - npm's, which keeps the path - is otherwise never seen.
    param([string]$Exe, [switch]$Fresh)
    if (-not $Exe) { return $null }
    if (-not $script:ChatqCliVersions) { $script:ChatqCliVersions = @{} }
    if (-not $Fresh -and $script:ChatqCliVersions.ContainsKey($Exe)) { return $script:ChatqCliVersions[$Exe] }
    $v = $null
    try {
        $out = (& $Exe --version 2>$null | Select-Object -First 1)
        if ("$out" -match '(\d+\.\d+\.\d+)') { $v = $Matches[1] }
    }
    catch {}
    $script:ChatqCliVersions[$Exe] = $v
    return $v
}

function Get-ChatqCliReport {
    <#
    The doctor's view of one CLI: which claude or codex chatq runs, its
    version, where it was found, and a warning when that is stale. A
    codex installed by npm and left on PATH wins over the one the VS Code
    extension keeps current, so every job would run on whatever the old
    one supports - with nothing to say so. Only a PATH pick is compared with
    the extension's copy: CHATQ_CODEX / CHATQ_CLAUDE is a choice made on
    purpose, and the extension's own needs no comparing. A version either
    side will not give is no warning.
    {Provider, Path, From, Where, Version, Bundled, BundledVersion, Older,
    Say, Warn} - Where is From in words, Say the one line chatinstall prints.
    Path $null when there is no CLI.
    #>
    param([string]$Provider)
    $name = if ($Provider -eq 'codex') { 'codex' } else { 'claude' }
    $r = [pscustomobject]@{ Provider = $name; Path = $null; From = $null; Where = $null; Version = $null
        Bundled = $null; BundledVersion = $null; Older = $false; Say = $null; Warn = $null
    }
    $pick = Get-ChatqExePick $name
    if (-not $pick) { return $r }
    $r.Path = $pick.Path
    $r.From = $pick.From
    $r.Version = Get-ChatqCliVersion $pick.Path
    $r.Where = switch ($pick.From) {
        'PATH' { 'on PATH' }
        'bundled' { "the VS Code extension's copy" }
        'local' { "Claude Code's own install" }
        default { "from $($pick.From)" }
    }
    $r.Say = "$name $(if ($r.Version) { $r.Version } else { '(version unknown)' }) - $($r.Where)"
    if ($pick.From -ne 'PATH') { return $r }
    $b = Find-ChatqBundledExe $name
    # PATH can lead into the extension's own folder: then it is the same one
    if (-not $b -or [string]::Equals($b, $pick.Path, [StringComparison]::OrdinalIgnoreCase)) { return $r }
    $r.Bundled = $b
    $r.BundledVersion = Get-ChatqCliVersion $b
    if ($r.Version -and $r.BundledVersion -and (Compare-ChatVersion $r.Version $r.BundledVersion) -eq -1) {
        $r.Older = $true
        $r.Warn = "the $name on PATH ($($r.Version)) is older than the VS Code extension's ($($r.BundledVersion)), and chatq runs the one on PATH - update it, or remove it to use the extension's"
    }
    return $r
}

function Test-ChatqCmdExe {
    # an executable Windows runs through cmd.exe: a .cmd or .bat - npm's
    # claude.cmd and codex.cmd among them. Pure.
    param([string]$Exe)
    return [bool]($Exe -match '\.(cmd|bat)$')
}

function Get-ChatqCmdArgRefusal {
    <#
    Why -ArgList cannot go to -Exe on a command line, or $null. Only a .cmd
    or .bat is refused anything: cmd.exe reads its line again, and a " or a
    %NAME% has no escape there at all - a quote ends the argument and hands
    what follows, an & and all, to cmd as a command of its own, and %NAME%
    is replaced by that variable, inside quotes too, whenever one of that
    name is set. A lone %, with no second one after it, is left as it is,
    so a folder named "100%" still goes. A line break ends the command.
    Everything else cmd would take as its own, & | < > ^ ( ), is quoted
    instead (ConvertTo-ChatqArgLine). Pure.
    #>
    param([string]$Exe, [string[]]$ArgList)
    if (-not (Test-ChatqCmdExe $Exe)) { return $null }
    foreach ($a in @($ArgList)) {
        $a = [string]$a
        if ($a -notmatch '["\r\n]|%[^%]+%') { continue }
        $what = if ($a -match '"') { 'a quote' } elseif ($a -match '%[^%]+%') { 'a %name%' } else { 'a line break' }
        $shown = if ($a.Length -gt 60) { $a.Substring(0, 60) + $script:ChatqEllipsis } else { $a }
        return "$(Split-Path $Exe -Leaf) runs through cmd.exe, which cannot be handed $what - not sent: $($shown -replace '[\r\n]+', ' ')"
    }
    return $null
}

function ConvertTo-ChatqArgLine {
    # The Windows command-line rules (backslashes only special before a quote),
    # which is also what .NET applies to Arguments on macOS and Linux - so one
    # string works everywhere, and PS 5.1 has no ArgumentList to fall back on.
    # -Exe a .cmd or .bat: cmd.exe reads the line first, so an argument
    # holding & | < > ^ ( ) is quoted too - inside quotes cmd takes them as
    # they are - and one it cannot carry at all throws
    # (Get-ChatqCmdArgRefusal).
    param([string[]]$ArgList, [string]$Exe)
    $no = Get-ChatqCmdArgRefusal $Exe $ArgList
    if ($no) { throw $no }
    $special = if (Test-ChatqCmdExe $Exe) { '[\s"&|<>^()]' } else { '[\s"]' }
    $parts = foreach ($a in $ArgList) {
        $a = [string]$a
        if ($a -eq '') { '""'; continue }
        if ($a -notmatch $special) { $a; continue }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $bs++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"') }
            else { if ($bs) { [void]$sb.Append('\' * $bs) }; [void]$sb.Append($ch) }
            $bs = 0
        }
        if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

function Stop-ChatqTree {
    # the CLI starts its own children (shells, MCP servers); take them all
    param($Process)
    try {
        if ($script:ChatqIsWindows) { & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null }
        else { try { $Process.Kill($true) } catch { $Process.Kill() } }
    }
    catch {}
}

function New-ChatqProcessStartInfo {
    <#
    How chatq starts every CLI: no window, all three pipes redirected, UTF-8
    out, the session's own variables dropped (ChatqEnvDrop) and -SetEnv laid
    over what is left. Invoke-ChatqProcess, which runs a CLI to the end, and
    Invoke-ChatqCodexRpc, which holds codex app-server open for a few
    requests, both start from this one, so a fix to either reaches both.
    Throws what ConvertTo-ChatqArgLine throws for an argument cmd.exe
    cannot carry.
    #>
    param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [hashtable]$SetEnv)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-ChatqArgLine $ArgList -Exe $Exe
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $hasInEnc = [bool]$psi.PSObject.Properties['StandardInputEncoding']
    if ($hasInEnc) { $psi.StandardInputEncoding = $utf8 }
    foreach ($k in $script:ChatqEnvDrop) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
    }
    # A $null value removes the variable rather than leaving what the watcher
    # inherited: a job queued with no CLAUDE_CONFIG_DIR means the default home,
    # not whichever one the shell that started the watcher had.
    if ($SetEnv) {
        foreach ($k in $SetEnv.Keys) {
            if ($SetEnv[$k]) { $psi.EnvironmentVariables[$k] = [string]$SetEnv[$k] }
            elseif ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
        }
    }
    return $psi
}

function Start-ChatqProcess {
    <#
    Process.Start for a New-ChatqProcessStartInfo, stdin left open: what is
    written to it goes as raw UTF-8 bytes onto StandardInput.BaseStream,
    never through its writer.

    stdin is where Korean went wrong on Windows PowerShell 5.1, three ways at
    once: the console code page here is 949, $OutputEncoding is us-ascii (so
    piping turns Hangul into ?), and 5.1's ProcessStartInfo has no
    StandardInputEncoding at all - Process.Start builds the stdin writer from
    Console.InputEncoding, and under chcp 65001 that writer puts a BOM on the
    pipe the moment it is created. So: the bytes go onto the base stream, and
    the console encoding is swapped to BOM-less UTF-8 for the instant Start
    takes and put back after.
    #>
    param($Psi)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $oldIn = $null
    if (-not $Psi.PSObject.Properties['StandardInputEncoding']) {
        try { $oldIn = [Console]::InputEncoding; [Console]::InputEncoding = $utf8 } catch { $oldIn = $null }
    }
    try { return [System.Diagnostics.Process]::Start($Psi) }
    finally { if ($oldIn) { try { [Console]::InputEncoding = $oldIn } catch {} } }
}

function Invoke-ChatqProcess {
    <#
    Run a CLI to the end, prompt on stdin, handing each stdout line to $OnLine.
    The prompt is written once and stdin closed after it (Start-ChatqProcess
    says why as bytes): a CLI that reads to the end of its input starts then.
    #>
    param(
        [string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$StdIn,
        [hashtable]$SetEnv, [string]$LogPath, [scriptblock]$OnLine, [scriptblock]$OnTick,
        [int]$TimeoutSec = 14400
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi = New-ChatqProcessStartInfo -Exe $Exe -ArgList $ArgList -WorkDir $WorkDir -SetEnv $SetEnv
    $p = Start-ChatqProcess $psi

    $bytes = $utf8.GetBytes([string]$StdIn)
    try {
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    catch {}
    try { $p.StandardInput.Close() } catch {}
    # a .NET task, not a PowerShell event: those need a runspace the watcher's
    # pipeline thread does not hand out, and a full stderr pipe would hang it
    $errTask = $p.StandardError.ReadToEndAsync()

    $log = $null
    if ($LogPath) {
        New-ChatqDir (Split-Path $LogPath -Parent)
        $log = New-Object System.IO.StreamWriter($LogPath, $true, $utf8)
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stopped = $null
    $lastTick = Get-Date
    # cancel, stop and the deadline are looked at every 5 s whether the run is
    # silent or chattering - a stream of quick tool calls must not hide them
    $check = {
        if ($OnTick -and (& $OnTick)) { return 'cancelled' }
        if ((Get-Date) -gt $deadline) { return 'timeout' }
        return $null
    }
    try {
        while ($true) {
            $task = $p.StandardOutput.ReadLineAsync()
            while (-not $task.Wait(5000)) {
                $lastTick = Get-Date
                $stopped = . $check
                if ($stopped) { break }
            }
            if ($stopped) { break }
            $line = $task.Result
            if ($null -eq $line) { break }
            if ($log) { $log.WriteLine($line); $log.Flush() }
            if ($OnLine) { & $OnLine $line }
            if (((Get-Date) - $lastTick).TotalSeconds -ge 5) {
                $lastTick = Get-Date
                $stopped = . $check
                if ($stopped) { break }
            }
        }
    }
    finally { if ($log) { $log.Dispose() } }
    if ($stopped) { Stop-ChatqTree $p }
    [void]$p.WaitForExit(15000)
    $err = ''
    try { if ($errTask.Wait(5000)) { $err = $errTask.Result } } catch {}
    $code = try { $p.ExitCode } catch { -1 }
    return [pscustomobject]@{ ExitCode = $code; StdErr = $err; Stopped = $stopped; Pid = $p.Id }
}

#endregion

#region reading a run --------------------------------------------------------
# What the stream-json lines of claude -p say, measured on 2.1.278:
#   system/init             session_id, model, permissionMode, claude_code_version
#   system/permission_denied  tool_name - a prompt nobody could answer
#   rate_limit_event        rate_limit_info {status allowed|allowed_warning|
#                           rejected, resetsAt (epoch s), rateLimitType}
#   assistant               message.content; model <synthetic> is Claude Code's
#                           own error turn, "You've hit your session limit ..."
#   result                  subtype, is_error, result, permission_denials[],
#                           num_turns, duration_ms, total_cost_usd - its "type"
#                           key comes last, so nothing may assume key order
# user lines carry tool results and run to megabytes; they are never parsed.

$script:ChatqLimitRx = '(?i)hit your (session |usage |weekly |opus |sonnet )?limit|usage limit reached|limit (will )?reset'
# "API Error: 529 Overloaded. This is a server-side issue, usually temporary -
# try again in a moment. If it persists, check https://status.claude.com." is
# the 529 as Claude Code prints it; the other 5xx it reports are the same kind
# of trouble - on Anthropic's side, and over when the status page says so.
$script:ChatqOverloadRx = '(?i)API Error:\s*5\d\d|\boverloaded(_error)?\b'
# Codex's own words for the same trouble, as codex-cli 0.159.2 has them:
# "Selected model is at capacity", "We're currently experiencing high
# demand", "Flex capacity unavailable", "exceeded retry limit, last status:
# 503" once its own retries ran out, "unexpected status 502 ...". A 429 is
# left out: Codex's usage limit says so in words of its own, and a throttle
# taken for an outage would loop. Not one of these was seen in a real run
# yet - a wording that misses still fails the job, as before.
$script:ChatqCodexOverloadRx = '(?i)at capacity|high demand|Flex capacity unavailable|(unexpected status|last status:?)\s*5\d\d|\boverloaded\b|server_error'
# A dropped connection is worth another try; a refused login is not - every
# retry would fail the same way until someone logs in again, or renews the
# subscription, which is refused with the same 401 or 403. Both are only
# ever matched against error text, never against a reply.
$script:ChatqNetworkRx = '(?i)ECONNRESET|ETIMEDOUT|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|socket hang up|Connection error|fetch failed|network error|stream disconnected|error sending request|Premature close|connection reset'
$script:ChatqAuthRx = '(?i)OAuth token (has )?expired|invalid (api key|x-api-key|bearer token)|authentication_error|not logged in|please (run )?/login|401 Unauthorized|403 Forbidden'

function New-ChatqRunState {
    @{
        Init = $false; Started = $false; Session = $null; Model = $null; Mode = $null; Version = $null
        Limit = $null; Rate = $null; SyntheticLimit = $null; Overloaded = $null; Retries = 0
        Assistant = 0; LastText = ''; Tools = [System.Collections.Generic.List[string]]::new()
        Denied = [System.Collections.Generic.List[string]]::new(); Result = $null
        # the phone's permission bridge (src/permit.ps1): every tool_use id the
        # stream showed with its tool's name, and how init found the bridge
        ToolIds = @{}; PermitServer = $null
        # codex
        Thread = $null; TurnStarted = $false; TurnDone = $false; TurnFailed = $null; Failed = $null
    }
}

function Update-ChatqClaudeState {
    param($St, [string]$Line)
    if ($Line.Length -gt 1048576) { return }
    $isAssistant = $Line.StartsWith('{"type":"assistant"')
    if (-not $isAssistant -and
        $Line.IndexOf('"type":"result"', [StringComparison]::Ordinal) -lt 0 -and
        $Line.IndexOf('"type":"rate_limit_event"', [StringComparison]::Ordinal) -lt 0 -and
        -not $Line.StartsWith('{"type":"system"')) { return }
    $o = try { $Line | ConvertFrom-Json } catch { return }
    switch ($o.type) {
        'system' {
            if ($o.subtype -eq 'init') {
                $St.Init = $true; $St.Session = $o.session_id; $St.Model = $o.model
                $St.Mode = $o.permissionMode; $St.Version = $o.claude_code_version
                # "connected", or "failed" when the bridge never came up (S35)
                $pb = @($o.mcp_servers | Where-Object { $_ -and $_.name -eq 'chatqpermit' })
                if ($pb.Count) { $St.PermitServer = [string]$pb[0].status }
            }
            elseif ($o.subtype -eq 'permission_denied' -and $o.tool_name) { $St.Denied.Add([string]$o.tool_name) }
            # Claude Code retries a 529 by itself several times before it gives up
            elseif ($o.subtype -eq 'api_retry') { $St.Retries++ }
        }
        'rate_limit_event' {
            $St.Rate = $o.rate_limit_info
            if ($o.rate_limit_info.status -eq 'rejected') { $St.Limit = $o.rate_limit_info }
        }
        'assistant' {
            $texts = @($o.message.content | Where-Object { $_.type -eq 'text' -and $_.text } | ForEach-Object { $_.text })
            if ($o.message.model -eq '<synthetic>') {
                $t = $texts -join ' '
                if ($t -match $script:ChatqLimitRx) { $St.SyntheticLimit = $t }
                elseif ($t -match $script:ChatqOverloadRx) { $St.Overloaded = $t }
                return
            }
            $St.Assistant++
            if ($texts) { $St.LastText = $texts[-1] }
            foreach ($u in @($o.message.content | Where-Object { $_.type -eq 'tool_use' })) { $St.Tools.Add([string]$u.name) }
            foreach ($u in @($o.message.content | Where-Object { $_.type -eq 'tool_use' -and $_.id })) { $St.ToolIds[[string]$u.id] = [string]$u.name }
        }
        'result' { $St.Result = $o }
    }
}

function Get-ChatqExcerpt {
    # the end of the reply, where the summary or the question is - up to $Max
    # characters, markdown fences and headers dropped, cut on a paragraph
    param([string]$Text, [int]$Max = 300)
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, '```[\s\S]*?```', ' ')
    $paras = @($t -split '\r?\n\s*\r?\n' | ForEach-Object { ($_ -replace '(?m)^\s*#+\s*', '' -replace '\s+', ' ').Trim() } | Where-Object { $_ })
    if (-not $paras) { return '' }
    $out = ''
    for ($i = $paras.Count - 1; $i -ge 0; $i--) {
        $next = if ($out) { $paras[$i] + ' / ' + $out } else { $paras[$i] }
        if ($next.Length -gt $Max) { break }
        $out = $next
    }
    if (-not $out) { $out = $paras[-1].Substring(0, [Math]::Min($Max - 1, $paras[-1].Length)) + $script:ChatqEllipsis }
    return $out
}

function Get-ChatqAuthWords {
    # What the CLI said when it turned the login down: the API's own message
    # when the error carries one, else the text itself, cut short. An expired
    # login and a subscription that ended are both refused with a 401 or 403,
    # and only these words tell which it was. Error text only - never a reply.
    param([string]$Text, $Status)
    $t = ($Text -replace '\s+', ' ').Trim()
    $msg = $null
    if ($t -match '"message"\s*:\s*("(?:[^"\\]|\\.)*")') {
        $msg = try { [string]($Matches[1] | ConvertFrom-Json) } catch { $null }
    }
    if ($msg) {
        # Claude prints "API Error: 401", Codex "unexpected status 401"
        $code = if ($Status) { [string]$Status } elseif ($t -match '(?i)(?:API Error|status):?\s*(\d{3})\b') { $Matches[1] } else { $null }
        if ($code) { $msg = "$msg ($code)" }
    }
    else {
        # log noise ahead of the refusal would crowd it out of the cut below
        $m = [regex]::Match($t, $script:ChatqAuthRx)
        $msg = if ($m.Success -and $m.Index + $m.Length -gt 159) { $script:ChatqEllipsis + $t.Substring($m.Index) } else { $t }
    }
    if (-not $msg) { $msg = if ($Status) { "API Error $Status" } else { 'no reason given' } }
    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 159) + $script:ChatqEllipsis }
    return $msg
}

function Get-ChatqAuthDetail {
    # the error text whole, on one line, for the watcher log: the message alone
    # drops the error's type, and a new way of being refused is read from this
    param([string]$Text)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt 1000) { $t = $t.Substring(0, 999) + $script:ChatqEllipsis }
    return $t
}

function Test-ChatqAsks {
    # a reply ending on a question - the alert says so, but it is not treated
    # as needs-input: most replies end on an offer ("want me to also ...?")
    param([string]$Text)
    if (-not $Text) { return $false }
    $last = @($Text -split '\r?\n' | Where-Object { $_.Trim() })[-1]
    return [bool]($last -and $last.TrimEnd().TrimEnd('*', '_', ')').EndsWith('?') -or
        ($last -and $last.TrimEnd().EndsWith([string][char]0xFF1F)))
}

function Get-ChatqClaudeOutcome {
    # limited and overloaded before failed, failed before needs-input: those two
    # are the outcomes that go back in the queue rather than get reported.
    # -Refused / -NoAnswer: the tool_use ids the phone denied, and the ones it
    # left unanswered (Close-ChatqPermitRun) - a run whose every denial was
    # the user's own Deny is done, not waiting on them.
    param($St, $Proc, [string]$Mode,
        [string[]]$Refused = @(), [string[]]$NoAnswer = @())
    $res = $St.Result
    $text = if ($res -and $res.result) { [string]$res.result } else { [string]$St.LastText }
    $o = [ordered]@{
        kind = $null; reason = $null; excerpt = (Get-ChatqExcerpt $text); asks = $false
        denied = @($St.Denied | Select-Object -Unique); turns = $res.num_turns; durationMs = $res.duration_ms
        costUsd = $res.total_cost_usd; model = $St.Model; resetsAt = $null; limitType = $null
        # replies before it broke: a run that got nowhere counts toward the cap
        assistant = $St.Assistant; detail = $null
    }
    # A turn that ended well is not limited, whatever was said on the way: a
    # 'rejected' rate_limit_event also goes out when extra usage carries the
    # request, and the run then completes normally.
    $broke = (-not $res) -or $res.is_error
    $legacy = if ("$text $($St.SyntheticLimit)" -match 'limit reached\|(\d{9,})') { $Matches[1] } else { $null }
    $limited = $broke -and ($St.Limit -or $St.SyntheticLimit -or $legacy -or
        ($res -and ("$text" -match $script:ChatqLimitRx)))
    $status = if ($res) { $res.api_error_status } else { $null }
    $overloaded = $broke -and -not $limited -and ($St.Overloaded -or ($status -and [int]$status -ge 500) -or
        ($res -and "$text" -match $script:ChatqOverloadRx) -or (-not $res -and "$($Proc.StdErr)" -match $script:ChatqOverloadRx))
    if ($overloaded -and -not $Proc.Stopped) {
        $o.kind = 'overloaded'
        $o.reason = if ($St.Overloaded) { $St.Overloaded } elseif ($status) { "API Error: $status" } else { 'API Error: overloaded' }
        return [pscustomobject]$o
    }
    if ($limited) {
        $o.kind = 'limited'
        $o.reason = if ($St.SyntheticLimit) { $St.SyntheticLimit } else { 'usage limit' }
        if ($St.Limit -and $St.Limit.resetsAt) {
            $o.resetsAt = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$St.Limit.resetsAt).UtcDateTime.ToString('o')
            $o.limitType = $St.Limit.rateLimitType
        }
        elseif ($legacy) { $o.resetsAt = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$legacy).UtcDateTime.ToString('o') }
        return [pscustomobject]$o
    }
    # Not chatq's own stop (the 4 h cap, a cancel): that is no network trouble,
    # and a job that ran four hours must not quietly run three times more.
    if ($broke -and -not $Proc.Stopped) {
        $err = "$text $($Proc.StdErr)"
        if (($status -and [int]$status -in 401, 403) -or $err -match $script:ChatqAuthRx) {
            # $text may be the last reply, which is no part of the refusal
            $said = "$(if ($res -and $res.is_error) { [string]$res.result }) $($Proc.StdErr)"
            $o.kind = 'auth'; $o.reason = "login refused: $(Get-ChatqAuthWords $said $status)"
            $o.detail = Get-ChatqAuthDetail $said
            return [pscustomobject]$o
        }
        if ($err -match $script:ChatqNetworkRx) {
            $o.kind = 'network'; $o.reason = "network: $($Matches[0])"
            return [pscustomobject]$o
        }
    }
    # The 4 h deadline after the turn itself had ended well: what print mode
    # was still waiting on - a workflow or an agent the run started - was cut
    # off, and the turn is done all the same.
    $cut = $Proc.Stopped -eq 'timeout' -and $res -and -not $res.is_error -and $res.subtype -eq 'success'
    if ($cut) { $o['note'] = 'background work it started was cut off at the 4 h deadline' }
    elseif ($Proc.Stopped) { $o.kind = 'failed'; $o.reason = $Proc.Stopped; return [pscustomobject]$o }
    if (-not $res) {
        $err = ("$($Proc.StdErr)" -replace '\s+', ' ').Trim()
        if ($err.Length -gt 200) { $err = $err.Substring($err.Length - 200) }
        $o.kind = 'failed'; $o.reason = "no result (exit $($Proc.ExitCode)) $err".Trim()
        return [pscustomobject]$o
    }
    if ($res.subtype -eq 'error_max_turns') { $o.kind = 'needs-input'; $o.reason = 'stopped at the turn limit'; return [pscustomobject]$o }
    if ($res.is_error -or $res.subtype -ne 'success') {
        $o.kind = 'failed'; $o.reason = "$($res.subtype): $(Get-ChatqExcerpt $text 160)"
        return [pscustomobject]$o
    }
    # a result with no permission_denials at all is none, not one $null
    $den = @($res.permission_denials | Where-Object { $null -ne $_ })
    if ($den.Count) {
        $names = @($den | ForEach-Object {
                $n = [string]$_.tool_name
                $arg = if ($_.tool_input.file_path) { Split-Path ([string]$_.tool_input.file_path) -Leaf }
                elseif ($_.tool_input.command) { ([string]$_.tool_input.command).Split("`n")[0] }
                else { $null }
                if ($arg) {
                    if ($arg.Length -gt 40) { $arg = $arg.Substring(0, 40) + $script:ChatqEllipsis }
                    "$n($arg)"
                }
                else { $n }
            } | Select-Object -Unique -First 3)
        # the phone said no to every one of them: that was the answer, the
        # run went on without them, and nothing waits on the user
        $ids = @($den | ForEach-Object { [string]$_.tool_use_id })
        if (@($Refused).Count -and -not @($ids | Where-Object { -not $_ -or $_ -notin @($Refused) }).Count) {
            $o.kind = 'done'; $o.asks = Test-ChatqAsks $text; $o.denied = $names; $o['youDenied'] = $names
            return [pscustomobject]$o
        }
        $o.kind = 'needs-input'; $o.reason = 'denied ' + ($names -join ', '); $o.denied = $names
        if (@($NoAnswer).Count -and @($ids | Where-Object { $_ -and $_ -in @($NoAnswer) }).Count) { $o.reason += ' - no answer from the phone' }
        return [pscustomobject]$o
    }
    if ($Mode -eq 'plan' -or $St.Mode -eq 'plan') {
        $o.kind = 'needs-input'; $o.reason = 'plan ready - approve it in VS Code'
        return [pscustomobject]$o
    }
    $o.kind = 'done'
    $o.asks = Test-ChatqAsks $text
    return [pscustomobject]$o
}

function Update-ChatqCodexState {
    param($St, [string]$Line)
    if ($Line.Length -gt 1048576) { return }
    $o = try { $Line | ConvertFrom-Json } catch { return }
    switch ($o.type) {
        'thread.started' { $St.Init = $true; $St.Thread = $o.thread_id }
        'turn.started' { $St.TurnStarted = $true }
        'turn.completed' { $St.TurnDone = $true }
        'turn.failed' { $St.TurnFailed = [string]$o.error.message; $St.Failed = $St.TurnFailed }
        # a bare 'error' can be a reconnect notice the turn recovers from
        'error' { if (-not $St.Failed) { $St.Failed = [string]$o.message } }
        'item.completed' {
            if ($o.item.type -eq 'agent_message' -and $o.item.text) { $St.Assistant++; $St.LastText = [string]$o.item.text }
            elseif ($o.item.type) { $St.Tools.Add([string]$o.item.type) }
        }
    }
}

function ConvertFrom-ChatqLimitText {
    # Codex puts its reset time in prose only - "try again at Sep 21st, 2026
    # 8:37 AM" - with no field for it, so the prose is all there is to parse
    param([string]$Text)
    if ($Text -notmatch '(?i)try again (?:at|in) ([^.\n]+)') { return $null }
    $s = ($Matches[1] -replace '(\d+)(st|nd|rd|th)', '$1').Trim()
    if ($s -match '^(\d+)\s*(minute|min|hour|hr|day)s?') {
        $n = [int]$Matches[1]
        switch -Wildcard ($Matches[2]) {
            'min*' { return (Get-Date).AddMinutes($n) }
            'h*' { return (Get-Date).AddHours($n) }
            'day' { return (Get-Date).AddDays($n) }
        }
    }
    $d = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
    return $null
}

function Get-ChatqCodexOutcome {
    param($St, $Proc)
    $o = [ordered]@{
        kind = $null; reason = $null; excerpt = (Get-ChatqExcerpt $St.LastText); asks = $false
        denied = @(); turns = $null; durationMs = $null; costUsd = $null; model = $null; resetsAt = $null; limitType = $null
        assistant = $St.Assistant; detail = $null
    }
    # a turn that completed is done, whatever retry notices came before it
    if ($St.TurnDone -and -not $St.TurnFailed -and -not $Proc.Stopped) {
        $o.kind = 'done'
        $o.asks = Test-ChatqAsks $St.LastText
        return [pscustomobject]$o
    }
    $fail = "$($St.Failed) $($Proc.StdErr)"
    if ($fail -match '(?i)usage limit|hit your .*limit') {
        $o.kind = 'limited'; $o.reason = ($St.Failed -replace '\s+', ' ').Trim()
        $at = ConvertFrom-ChatqLimitText $fail
        if ($at) { $o.resetsAt = $at.ToUniversalTime().ToString('o') }
        return [pscustomobject]$o
    }
    if (-not $Proc.Stopped) {
        if ($fail -match $script:ChatqAuthRx) {
            $o.kind = 'auth'; $o.reason = "login refused: $(Get-ChatqAuthWords $fail)"; $o.detail = Get-ChatqAuthDetail $fail
            return [pscustomobject]$o
        }
        # A 5xx or a model at capacity: the server's trouble, waited out as an
        # outage of the lane (Enter-ChatqOutage). Read from what the turn
        # failed with, and from stderr only when it said nothing - and then
        # only from the lines that are the run's own fatal error ("Error:
        # ...", as codex exec ends on one), the matched line the reason.
        # The rest of stderr is codex's own log noise - a models refresh
        # that got "unexpected status 503", an MCP probe that "returned
        # unexpected status: 500" - which must never turn a run that failed
        # for another reason, a resume of a rollout that is gone say, into
        # a retry and its lane into an outage.
        $said = if ($St.Failed) { [string]$St.Failed }
        else {
            $own = @(([string]$Proc.StdErr) -split '\r?\n' | Where-Object { $_ -match '^\s*(?:Error|ERROR):\s*\S' -and $_ -match $script:ChatqCodexOverloadRx })
            if ($own.Count) { $own[0] -replace '^\s*(?:Error|ERROR):\s*', '' } else { '' }
        }
        if ($said -and $said -match $script:ChatqCodexOverloadRx) {
            $why = ($said -replace '\s+', ' ').Trim()
            if ($why.Length -gt 200) { $why = $why.Substring(0, 199) + $script:ChatqEllipsis }
            $o.kind = 'overloaded'; $o.reason = $why
            return [pscustomobject]$o
        }
        if ($fail -match $script:ChatqNetworkRx) { $o.kind = 'network'; $o.reason = "network: $($Matches[0])"; return [pscustomobject]$o }
    }
    if ($Proc.Stopped) { $o.kind = 'failed'; $o.reason = $Proc.Stopped; return [pscustomobject]$o }
    if ($St.Failed -or -not $St.TurnDone) {
        $why = if ($St.Failed) { $St.Failed } else { "no turn.completed (exit $($Proc.ExitCode))" }
        $o.kind = 'failed'; $o.reason = ($why -replace '\s+', ' ').Trim()
        return [pscustomobject]$o
    }
    $o.kind = 'done'
    $o.asks = Test-ChatqAsks $St.LastText
    return [pscustomobject]$o
}

function Test-ChatqPromptLanded {
    # Did the prompt reach the chat before the limit stopped it? If it did,
    # sending it again would put it in the chat twice and redo half-done work,
    # so the retry is a "continue" instead. Codex records the user turn when the
    # turn starts, so a run cut off before any reply has still landed there.
    param([string]$Path, [string]$Prompt, $SinceUtc, [string]$Provider = 'claude')
    if (-not $Path -or -not (Test-Path -LiteralPath $Path) -or -not $Prompt) { return $false }
    $since = ConvertTo-ChatqDate $SinceUtc
    $want = ($Prompt -replace '\s+', ' ').Trim()
    $want = $want.Substring(0, [Math]::Min(60, $want.Length))
    $text = Read-ChatqTail $Path 4194304
    # assigned, never @()-wrapped: Get-ChatJsonLines returns its array behind a
    # comma, and @(...) around that makes an array holding one array
    $marker = if ($Provider -eq 'codex') { @('"role":"user"', '"role": "user"') } else { @('"type":"user"') }
    $lines = Get-ChatJsonLines $text $marker 40 -FromEnd -Skip @('"tool_result"')
    foreach ($line in $lines) {
        $o = try { $line | ConvertFrom-Json } catch { continue }
        if ($since -and (ConvertTo-ChatqDate $o.timestamp) -lt $since.AddSeconds(-5)) { continue }
        $t = if ($Provider -eq 'codex') {
            (@($o.payload.content) | Where-Object { $_.type -eq 'input_text' } | ForEach-Object { $_.text }) -join ' '
        }
        else {
            $c = $o.message.content
            if ($c -is [string]) { $c } else { (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
        }
        $t = (([string]$t) -replace '\s+', ' ').Trim()
        # contains, not starts-with: the IDE wraps a Codex prompt in context
        if ($t.StartsWith($want, [StringComparison]::Ordinal) -or ($Provider -eq 'codex' -and $t.Contains($want))) { return $true }
    }
    return $false
}

#endregion

#region when the limit resets -------------------------------------------------

function Get-ChatqHomeDir {
    # The config dir a job's chats live under: the one set when it was queued,
    # else the default. Never the watcher's own - that came from whichever shell
    # happened to start it, and may belong to another account.
    param([string]$Provider, [string]$Override)
    if ($Override) { return $Override }
    if ($Provider -eq 'codex') { return (Join-Path $HOME '.codex') }
    return (Join-Path $HOME '.claude')
}

# Limits that stop every chat. Others - seven_day_opus, a weekly_scoped model
# limit - stop one model only, and the probe (asked with the chat's own model)
# is what decides those.
$script:ChatqWideLimits = @('five_hour', 'seven_day', 'session', 'weekly_all', 'weekly')

function Get-ChatqRecordTime {
    # the "timestamp" of the JSONL record that holds position $At in $Text
    param([string]$Text, [int]$At)
    $s = $Text.LastIndexOf("`n", [Math]::Max(0, $At)) + 1
    $e = $Text.IndexOf("`n", $At)
    if ($e -lt 0) { $e = $Text.Length }
    if ($Text.Substring($s, $e - $s) -match '"timestamp":\s*"([^"]+)"') { return ConvertTo-ChatqDate $Matches[1] }
    return $null
}

function Get-ChatqClaudeBlock {
    <#
    The latest future reset among the "rejected" records Claude writes into a
    transcript when it stops one - read from the tails of the most recently
    touched chats, where that record always is. ~/.claude.json's usage cache is
    a hint on top: it is refreshed only when a window asks, and was 11 h stale
    on the machine this was written on. At is when the record was written, so a
    probe that said "allowed" after it wins.
    #>
    param([string]$ConfigDir)
    $now = Get-Date
    $best = $null
    $root = Join-Path (Get-ChatqHomeDir 'claude' $ConfigDir) 'projects'
    if (Test-Path -LiteralPath $root) {
        $since = $now.AddDays(-8)
        $files = @(Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File -EA SilentlyContinue
            } | Where-Object { $_.LastWriteTime -gt $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 30)
        $recent = $now.AddHours(-6)
        $extra = foreach ($f in $files) {
            $sub = Join-Path (Join-Path $f.DirectoryName $f.BaseName) 'subagents'
            if (Test-Path -LiteralPath $sub) {
                Get-ChildItem -LiteralPath $sub -Filter *.jsonl -File -Recurse -EA SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $recent }
            }
        }
        foreach ($f in @($files) + @($extra)) {
            $t = Read-ChatqTail $f.FullName 262144
            if (-not $t) { continue }
            $i = $t.LastIndexOf('"quotaLimits":{', [StringComparison]::Ordinal)
            while ($i -ge 0) {
                $obj = Read-ChatqJsonObjectAt $t ($i + 14)
                $q = if ($obj) { try { $obj | ConvertFrom-Json } catch { $null } } else { $null }
                if ($q -and $q.status -eq 'rejected' -and $q.resetsAt -and
                    (-not $q.rateLimitType -or $script:ChatqWideLimits -contains [string]$q.rateLimitType)) {
                    $until = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$q.resetsAt).LocalDateTime
                    if ($until -gt $now -and (-not $best -or $until -gt $best.Until)) {
                        $best = [pscustomobject]@{ Until = $until; Type = $q.rateLimitType; Source = 'transcript'; At = (Get-ChatqRecordTime $t $i) }
                    }
                }
                $i = if ($i -gt 0) { $t.LastIndexOf('"quotaLimits":{', $i - 1, [StringComparison]::Ordinal) } else { -1 }
            }
        }
    }
    $hint = Read-ChatqUsageCache $ConfigDir
    if ($hint -and (-not $best -or $hint.Until -gt $best.Until)) { $best = $hint }
    return $best
}

function Read-ChatqCachedUtilization {
    # The cachedUsageUtilization block of the .claude.json at -Path, parsed,
    # or $null - for one with no fetchedAtMs too. Only that block is lifted
    # out and parsed - the rest of the file holds the account and is none of
    # this tool's business. Read by Read-ChatqUsageCache,
    # Read-ChatqClaudeUsageCache and Get-ChatqUsage.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $t = try { Read-ChatAllText $Path } catch { return $null }
    $i = $t.IndexOf('"cachedUsageUtilization"', [StringComparison]::Ordinal)
    $j = if ($i -ge 0) { $t.IndexOf('{', $i) } else { -1 }
    $obj = if ($j -ge 0) { Read-ChatqJsonObjectAt $t $j } else { $null }
    $u = if ($obj) { try { $obj | ConvertFrom-Json } catch { $null } } else { $null }
    if (-not $u -or -not $u.fetchedAtMs) { return $null }
    return $u
}

function Read-ChatqUsageCache {
    # a wide limit Claude Code's usage cache (Read-ChatqCachedUtilization)
    # saw full, with its reset still ahead
    param([string]$ConfigDir)
    $path = if ($ConfigDir) { Join-Path $ConfigDir '.claude.json' } else { Join-Path $HOME '.claude.json' }
    $u = Read-ChatqCachedUtilization $path
    if (-not $u) { return $null }
    $fetched = [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$u.fetchedAtMs).LocalDateTime
    $now = Get-Date
    $best = $null
    foreach ($l in @($u.utilization.limits)) {
        if (-not $l -or [double]$l.percent -lt 100 -or -not $l.resets_at) { continue }
        # one model's weekly limit ('weekly_scoped', with a scope) is not a wall
        if ($l.PSObject.Properties['scope'] -and $l.scope) { continue }
        if ($l.kind -and $script:ChatqWideLimits -notcontains [string]$l.kind) { continue }
        $until = ConvertTo-ChatqResetDate $l.resets_at
        # full at the time it was fetched, and that fetch was inside the window
        if ($until -and $until -gt $now -and $fetched -gt $until.AddDays(-7)) {
            if (-not $best -or $until -gt $best.Until) {
                $best = [pscustomobject]@{ Until = $until; Type = $l.kind; Source = 'usage cache'; At = $fetched }
            }
        }
    }
    return $best
}

# The key, with whatever spacing the writer used: Codex writes compact JSON
# today, but a key matched as the literal '"rate_limits":{' at a fixed +14
# offset - as three readers once did - finds nothing in '"rate_limits": {'.
# An escaped mention inside a string ('\"rate_limits\"') never matches.
$script:ChatqCodexLimitRx = [regex]'"rate_limits"\s*:\s*\{'

function ConvertFrom-ChatqCodexLimits {
    # Codex's rate_limits: used_percent, window_minutes and resets_at (epoch s)
    # per window - or, as codex app-server's account/rateLimits/read answers
    # (ConvertFrom-ChatqCodexRateLimitsReply), the same in camelCase:
    # usedPercent, windowDurationMins, resetsAt. Which window is primary
    # varies by plan - a free plan's is 43200 minutes, 30 days - so its
    # length is what names it: Label for what is shown, Type for a block. One
    # that gives no length is named by its place, as the windows were before
    # plans differed: primary 5h, secondary week. A window with no used
    # percent is left out.
    param($R)
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not $R) { return $out.ToArray() }
    $field = { param($o, [string[]]$names) foreach ($n in $names) { $pp = $o.PSObject.Properties[$n]; if ($pp -and $null -ne $pp.Value) { return $pp.Value } }; $null }
    foreach ($k in 'primary', 'secondary') {
        $p = $R.PSObject.Properties[$k]
        $w = if ($p) { $p.Value } else { $null }
        if (-not $w) { continue }
        $used = & $field $w 'used_percent', 'usedPercent'
        if ($null -eq $used) { continue }
        $mv = & $field $w 'window_minutes', 'windowDurationMins'
        $m = if ($null -ne $mv) { [int]$mv } else { 0 }
        $short = if ($m) { $m -le 300 } else { $k -eq 'primary' }
        $mid = if ($m) { $m -le 10080 } else { $true }
        $label = if ($short) { '5h' } elseif ($mid) { 'week' } else { 'month' }
        $type = if ($short) { 'five_hour' } elseif ($mid) { 'weekly' } else { 'monthly' }
        $rs = & $field $w 'resets_at', 'resetsAt'
        $at = if ($rs) { try { [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$rs).LocalDateTime } catch { $null } } else { $null }
        $out.Add([pscustomobject]@{ Label = $label; Type = $type; Minutes = $m; Percent = [double]$used; ResetsAt = $at; Severity = '' })
    }
    return $out.ToArray()
}

function ConvertFrom-ChatqCodexRateLimitsReply {
    <#
    What codex app-server's account/rateLimits/read answered, read as a
    rollout's snapshot is (Read-ChatqCodexLimitSnapshot): Limits, PlanType,
    Reached (rateLimitReachedType) - and two things only the answer has:
    Allowed, ordinaryUsageAllowed (the server's own yes or no on the
    plan's included use; $null when it does not say), and Credits, whether
    credits could carry a turn past a full window. $null when the answer
    has no window. rateLimits is the single-bucket view the rollouts
    carry; the per-limit view's 'codex' bucket stands in for it if empty.
    #>
    param($Result)
    if (-not $Result) { return $null }
    $snap = Get-ChatField $Result 'rateLimits'
    $w = @(ConvertFrom-ChatqCodexLimits $snap)
    if (-not $w.Count) {
        $by = Get-ChatField $Result 'rateLimitsByLimitId'
        $snap = if ($by) { Get-ChatField $by 'codex' } else { $null }
        $w = @(ConvertFrom-ChatqCodexLimits $snap)
    }
    if (-not $w.Count) { return $null }
    $plan = Get-ChatField $snap 'planType'
    $hit = Get-ChatField $snap 'rateLimitReachedType'
    $ok = Get-ChatField $Result 'ordinaryUsageAllowed'
    $cr = Get-ChatField $snap 'credits'
    $credits = [bool]($cr -and ((Get-ChatField $cr 'hasCredits') -eq $true -or (Get-ChatField $cr 'unlimited') -eq $true))
    return [pscustomobject]@{
        Limits = $w
        PlanType = $(if ($plan) { [string]$plan } else { $null })
        Reached = $(if ($hit) { [string]$hit } else { $null })
        Allowed = $(if ($ok -is [bool]) { $ok } else { $null })
        Credits = $credits
    }
}

function Read-ChatqCodexLimitSnapshot {
    <#
    The newest rate_limits snapshot in $Text - a rollout's tail - that has a
    window in it: Limits (ConvertFrom-ChatqCodexLimits), At (the record's own
    timestamp, $null when it has none), PlanType and Reached (Codex's
    rate_limit_reached_type, $null while nothing is reached). $null when
    there is none. Codex logs one in every token_count event.
    Newest first, and on past one that cannot be read: the last line of a
    rollout Codex is still writing can be half there, and a snapshot one
    line up is still this thread's. One with no window at all - nothing a
    caller could show or wait on - is passed over the same way, but for
    -Newest: then it is the answer, Limits empty. A figure to show may be
    an older one, with its age beside it; a lane blocked on one would wait
    out a reset the account has since moved past (Get-ChatqCodexBlock).
    #>
    param([string]$Text, [switch]$Newest)
    if (-not $Text) { return $null }
    $ms = $script:ChatqCodexLimitRx.Matches($Text)
    for ($k = $ms.Count - 1; $k -ge 0; $k--) {
        $m = $ms[$k]
        $obj = Read-ChatqJsonObjectAt $Text ($m.Index + $m.Length - 1)
        $r = if ($obj) { try { $obj | ConvertFrom-Json } catch { $null } } else { $null }
        if (-not $r) { continue }
        $w = @(ConvertFrom-ChatqCodexLimits $r)
        if (-not $w.Count -and -not $Newest) { continue }
        $plan = $r.PSObject.Properties['plan_type']
        $hit = $r.PSObject.Properties['rate_limit_reached_type']
        return [pscustomobject]@{
            Limits = $w; At = (Get-ChatqRecordTime $Text $m.Index)
            PlanType = $(if ($plan -and $plan.Value) { [string]$plan.Value } else { $null })
            Reached = $(if ($hit -and $hit.Value) { [string]$hit.Value } else { $null })
        }
    }
    return $null
}

function Find-ChatqCodexLimitSnapshot {
    <#
    Read-ChatqCodexLimitSnapshot over rollouts, newest first; the first that
    has one wins, with File the rollout it came from. That need not be the
    newest rollout: a thread cut off before its first reply has none. With
    -HomeDir, the ten rollouts Codex wrote to last under that home - the
    usage line and the limit check both list them so; the overlay hands its
    own list in, kept between passes. -Newest goes to
    Read-ChatqCodexLimitSnapshot: a rollout whose newest snapshot has no
    window stops the walk there too.
    #>
    param([object[]]$Files, [string]$HomeDir, [switch]$Newest)
    if ($PSBoundParameters.ContainsKey('HomeDir')) {
        $root = Join-Path $HomeDir 'sessions'
        if (-not (Test-Path -LiteralPath $root)) { return $null }
        $Files = @(Get-ChildItem -LiteralPath $root -Filter *.jsonl -File -Recurse -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    }
    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        $s = Read-ChatqCodexLimitSnapshot (Read-ChatqTail $f.FullName 262144) -Newest:$Newest
        if ($s) { return ($s | Add-Member -NotePropertyName File -NotePropertyValue $f -PassThru) }
    }
    return $null
}

function Get-ChatqCodexBlock {
    # A window of the newest rate_limits snapshot that is full and resets
    # later than now. Each window is judged by its own used_percent. The
    # newest one even with no window (-Newest): a turn under another login
    # or plan logs none, and a full window from before it is no longer the
    # account's word - waiting it out held the lane with no probe to clear it.
    param([string]$ConfigDir)
    $s = Find-ChatqCodexLimitSnapshot -HomeDir (Get-ChatqHomeDir 'codex' $ConfigDir) -Newest
    if (-not $s) { return $null }
    $now = Get-Date
    $best = $null
    foreach ($w in @($s.Limits)) {
        if (-not $w.ResetsAt -or $w.Percent -lt 100) { continue }
        if ($w.ResetsAt -gt $now -and (-not $best -or $w.ResetsAt -gt $best.Until)) {
            $best = [pscustomobject]@{ Until = $w.ResetsAt; Type = $w.Type; Source = 'rollout'; At = $s.At }
        }
    }
    return $best
}

function Get-ChatqClaudeStatus {
    # "Claude Code" on status.claude.com: operational, degraded_performance,
    # partial_outage, major_outage or under_maintenance. $null when the page
    # cannot be read - a laptop just woken has no network yet.
    try {
        $j = if ($script:ChatqStatusUrl -notmatch '^https?://' -and (Test-Path -LiteralPath $script:ChatqStatusUrl)) {
            Get-Content -LiteralPath $script:ChatqStatusUrl -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        else {
            Enable-ChatqTls12
            Invoke-RestMethod -Uri $script:ChatqStatusUrl -Method Get -TimeoutSec 15 -UseBasicParsing
        }
        $c = @($j.components | Where-Object { $_.name -eq $script:ChatqStatusComponent }) | Select-Object -First 1
        if (-not $c) { $c = @($j.components | Where-Object { $_.name -like 'Claude API*' }) | Select-Object -First 1 }
        if ($c) { return [string]$c.status }
    }
    catch {}
    return $null
}

function Invoke-ChatqProbe {
    <#
    Is the limit really over, or the overload? A throwaway "ok" that saves no
    session - 3 s and half a cent on haiku, measured - asked before any real
    chat is touched; Codex's is asked at low effort, and only once the
    account's own figures, asked with no turn, leave it unclear
    (Get-ChatqCodexLiveLimit). Sending the real prompt
    while still limited would plant it, and an error after it, in that chat.
    Asked with the chat's own model: a weekly limit can be one model's alone,
    and haiku would sail through it.
    #>
    param([string]$Provider, $Job, [switch]$NoModel)
    $exe = Find-ChatqExe $Provider
    if (-not $exe) { return [pscustomobject]@{ Allowed = $false; Limited = $false; Overloaded = $false; Auth = $false; Error = "no $Provider CLI found"; Until = $null; Type = $null; Detail = $null } }
    $dir = if ($Job.cwd -and (Test-Path -LiteralPath $Job.cwd)) { $Job.cwd } else { $script:ChatqData }
    $st = New-ChatqRunState
    # the model the run will use: one given with -Model, else the chat's own
    $model = Get-ChatqRunModel $Job
    if ($Provider -eq 'codex') {
        # First the turn-free answer (Get-ChatqCodexLiveLimit): still limited
        # by the account's own figures spends nothing. Asked once - not again
        # on the -NoModel ask below, which only drops the model.
        if (-not $NoModel) {
            $live = Get-ChatqCodexLiveLimit (Get-ChatqHomeDir 'codex' ([string](Get-ChatField $Job 'home')))
            if ($live) { return $live }
        }
        # Low effort and the chat's model: with none named, codex takes both
        # from config.toml - xhigh on whatever model is set there - so each
        # lane check was a full-price turn asked of the wrong model.
        $args2 = @('exec', '--ephemeral', '--skip-git-repo-check', '--json', '-s', 'read-only', '-c', 'model_reasoning_effort=low')
        if ($model -and -not $NoModel) { $args2 += @('-m', $model) }
        $args2 += '-'
    }
    else {
        # default mode: the probe asks nothing, and a settings defaultMode of
        # plan must not read as "needs input" here
        $args2 = @('-p', '--no-session-persistence', '--safe-mode', '--tools', '', '--permission-mode', 'default',
            '--output-format', 'stream-json', '--verbose')
        if ($model -and -not $NoModel) { $args2 += @('--model', $model) }
    }
    # a model cmd.exe cannot carry: never thrown into the watcher. The
    # chat's own is only ever named to the probe, so it is asked without
    # one; a -Model the run would use is this job's own failure, not its
    # lane's - Refused, which Confirm-ChatqAllowed fails the job on.
    # New-ChatqJob and Set-ChatqJobRunAs refuse one as it is given, so
    # only a job queued before them, or edited by hand, gets here.
    $no = Get-ChatqCmdArgRefusal $exe $args2
    if ($no -and $model -and -not $Job.runModel -and -not $NoModel) { return (Invoke-ChatqProbe $Provider $Job -NoModel) }
    if ($no) { return [pscustomobject]@{ Allowed = $false; Limited = $false; Overloaded = $false; Auth = $false; Refused = $true; Error = $no; Until = $null; Type = $null; Detail = $null } }
    if ($Provider -eq 'codex') {
        $proc = Invoke-ChatqProcess -Exe $exe -ArgList $args2 -WorkDir $dir -StdIn 'Reply with one word: ok' `
            -SetEnv @{ CODEX_HOME = $Job.home } -TimeoutSec 180 -OnLine { param($l) Update-ChatqCodexState $st $l }
        $out = Get-ChatqCodexOutcome $st $proc
        $ok = $out.kind -eq 'done'
    }
    else {
        $proc = Invoke-ChatqProcess -Exe $exe -ArgList $args2 -WorkDir $dir -StdIn 'Reply with one word: ok' `
            -SetEnv @{ CLAUDE_CONFIG_DIR = $Job.home } -TimeoutSec 180 -OnLine { param($l) Update-ChatqClaudeState $st $l }
        $out = Get-ChatqClaudeOutcome $st $proc 'default'
        $ok = $out.kind -notin 'limited', 'overloaded' -and $st.Result -and -not $st.Result.is_error
    }
    # The chat's model as it last named it may be one the account has since
    # lost (Codex's rollout), or an id from months ago since retired
    # (Claude); the run itself never names one - a resume keeps the chat's
    # model - so ask again without it. Not for a -Model: the run will use
    # exactly that, so the probe must.
    if (-not $ok -and $out.kind -eq 'failed' -and $model -and -not $Job.runModel -and -not $NoModel) {
        return (Invoke-ChatqProbe $Provider $Job -NoModel)
    }
    $until = if ($out.resetsAt) { ConvertTo-ChatqDate $out.resetsAt } else { $null }
    return [pscustomobject]@{
        Allowed    = [bool]$ok
        Limited    = $out.kind -eq 'limited'
        Overloaded = $out.kind -eq 'overloaded'
        Auth       = $out.kind -eq 'auth'
        Until      = $until
        Type       = $out.limitType
        Error      = if (-not $ok -and $out.kind -notin 'limited', 'overloaded') { $(if ($out.reason) { $out.reason } else { $out.kind }) } else { $null }
        Detail     = $out.detail
    }
}

function Get-ChatqCodexLiveLimit {
    <#
    Whether a Codex account is still limited, asked of codex app-server
    (account/rateLimits/read) with no model turn: a probe-shaped answer
    (Invoke-ChatqProbe) when it clearly is, else $null and the exec probe
    asks. Clearly is a window at 100% whose reset is ahead, a limit the
    server says is reached (rateLimitReachedType), or included use it
    says is not allowed (ordinaryUsageAllowed false) - each on the whole
    account, so whatever the chat's model. Never when credits could carry
    a turn past them, and never "allowed": a window under 100% says
    nothing of an overload, the login, or a limit that is one model's
    alone, which only a turn finds. No answer - no CLI, an older codex,
    a timeout, an error - is $null too.
    Until is the latest full window's reset; with none, $null, and
    Confirm-ChatqAllowed falls back to the rollout's (Get-ChatqCodexBlock).
    #>
    param([string]$CodexHome)
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $CodexHome -TimeoutSec 10
    $a = if ($r.Ok) { ConvertFrom-ChatqCodexRateLimitsReply $r.Results[0] } else { $null }
    if (-not $a -or $a.Credits) { return $null }
    $now = Get-Date
    $full = @($a.Limits | Where-Object { $_.Percent -ge 100 -and $_.ResetsAt -and $_.ResetsAt -gt $now } | Sort-Object ResetsAt)
    if (-not $full.Count -and -not $a.Reached -and $a.Allowed -ne $false) { return $null }
    $last = if ($full.Count) { $full[-1] } else { $null }
    $why = if ($full.Count) { "$($last.Label) window at 100%" } elseif ($a.Reached) { $a.Reached } else { 'included use not allowed' }
    return [pscustomobject]@{
        Allowed = $false; Limited = $true; Overloaded = $false; Auth = $false; Refused = $false
        Until = $(if ($last) { $last.ResetsAt } else { $null })
        Type = $(if ($last) { $last.Type } elseif ($a.Reached) { $a.Reached } else { $null })
        Error = $null
        # said where the watcher logs the probe: no turn was spent on it
        Detail = "account/rateLimits/read: $why"
        NoTurn = $true
    }
}

function Get-ChatqRunModel {
    # -Model for this job if given, else the chat's own - which a resume keeps
    # by itself, so it is only ever named to the probe
    param($Job)
    if ($Job.PSObject.Properties['runModel'] -and $Job.runModel) { return [string]$Job.runModel }
    return [string]$Job.model
}

function Get-ChatqRunRules {
    <#
    What the settings a queued Claude run loads say beyond the flags chatq
    gives it: the user's (settings.json in the job's config dir, the
    CLAUDE_CONFIG_DIR the run is given - ~/.claude when the job names none),
    the project's (.claude/settings.json in the job's folder) and the local
    one (.claude/settings.local.json there). @{ Workflow = 'deny' | 'ask' |
    'allow' | $null - the strongest rule any of them has for Workflow, as
    Claude Code weighs them: a deny over an ask over an allow; WorkflowIn =
    'user' | 'project' | 'local', the first file that has it; EffortEnv =
    the first that sets CLAUDE_CODE_EFFORT_LEVEL in its env, or $null }.
    An allow counts only for the whole tool (Workflow, Workflow(*)): one
    for a named workflow leaves the rest asking. A deny or an ask counts
    whatever it names - some workflow would be refused, and the model picks
    which. A file missing or spoilt says nothing. The managed settings an
    organisation deploys are not read.
    #>
    param($Job)
    $r = [pscustomobject]@{ Workflow = $null; WorkflowIn = $null; EffortEnv = $null }
    # the run's own: a job with no home runs with CLAUDE_CONFIG_DIR taken
    # away (Invoke-ChatqRun), so ~/.claude, never the watcher's
    $home0 = Get-ChatqHomeDir 'claude' ([string](Get-ChatField $Job 'home'))
    $files = [ordered]@{ user = (Join-Path $home0 'settings.json') }
    if ($Job.cwd) {
        $files['project'] = Join-Path (Join-Path $Job.cwd '.claude') 'settings.json'
        $files['local'] = Join-Path (Join-Path $Job.cwd '.claude') 'settings.local.json'
    }
    $rank = @{ allow = 1; ask = 2; deny = 3 }
    foreach ($scope in $files.Keys) {
        $s = $null
        try { if (Test-Path -LiteralPath $files[$scope] -PathType Leaf) { $s = [System.IO.File]::ReadAllText($files[$scope], [System.Text.Encoding]::UTF8) | ConvertFrom-Json } }
        catch { $s = $null }
        if ($s -isnot [pscustomobject]) { continue }
        $env0 = Get-ChatField $s 'env'
        if (-not $r.EffortEnv -and $env0 -is [pscustomobject] -and [string](Get-ChatField $env0 'CLAUDE_CODE_EFFORT_LEVEL')) { $r.EffortEnv = $scope }
        $perm = Get-ChatField $s 'permissions'
        if ($perm -isnot [pscustomobject]) { continue }
        foreach ($kind in 'deny', 'ask', 'allow') {
            foreach ($rule in @(Get-ChatField $perm $kind)) {
                if ($rule -isnot [string]) { continue }
                $t = $rule.Trim()
                $hit = if ($kind -eq 'allow') { $t -ceq 'Workflow' -or $t -ceq 'Workflow(*)' } else { $t -ceq 'Workflow' -or $t -clike 'Workflow(*)' }
                if ($hit -and (-not $r.Workflow -or $rank[$kind] -gt $rank[$r.Workflow])) { $r.Workflow = $kind; $r.WorkflowIn = $scope }
            }
        }
    }
    return $r
}

function Get-ChatqRunCarry {
    <#
    What a queued Claude run carries of the chat's session-only settings
    (Get-ChatSessionSettings), which a new process for the chat - a run is
    one - would start without: @{ Ultracode = [bool]; Effort = a level
    --effort takes, or $null; UltracodeHeld = the run's mode when the chat
    had Ultracode and the run goes without it, else $null; HeldBy = 'mode',
    or 'deny' / 'ask' for a settings rule on Workflow, and RuleIn the file
    with the rule (Get-ChatqRunRules) - the one that held Ultracode back,
    or the allow it was carried by in a mode that would ask }. Only into
    the chat as it is, on its own model - never a new chat's first run,
    and never on a -Model of the job's, which may not take them (Ultracode
    needs a model that can do xhigh). Codex has neither. A level only where
    nothing sets one already: CLAUDE_CODE_EFFORT_LEVEL - in the watcher's
    environment, or in a settings file's env, which the run loads -
    overrides --effort, and is the user's own, left as it is.
    Ultracode where nothing asks before a Workflow. Its standing
    instruction has the model run a workflow for every real task - likely
    the first - and Claude Code asks before each Workflow unless a rule
    allows it: auto mode's classifier lets one through, bypassPermissions
    asks nothing, and a Workflow allow rule in the settings lets it through
    in any mode; but otherwise nobody can answer a run (with
    --permission-prompts none the ask is a denial, and the phone's bridge
    never approves a Workflow), so each call is denied and the job ends
    needs input, 'denied Workflow', where it would have run without. A
    deny or an ask rule for Workflow holds it back in every mode, and plan
    mode holds it back whatever allows it: a plan run is to change nothing,
    and a workflow's agents would.
    #>
    param($Job)
    $none = [pscustomobject]@{ Ultracode = $false; Effort = $null; UltracodeHeld = $null; HeldBy = $null; RuleIn = $null }
    if ($Job.provider -ne 'claude' -or (Get-ChatField $Job 'runModel') -or (Test-ChatqFreshChat $Job) -or -not $Job.path) { return $none }
    $s = Get-ChatSessionSettings ([string]$Job.path)
    $uc = $s.Ultracode -eq $true
    $lvl = $null
    if ($s.Effort -in $script:ChatEffortLevels -and -not [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL')) { $lvl = [string]$s.Effort }
    # the settings only for something to carry: most runs carry nothing
    $rules = if ($uc -or $lvl) { Get-ChatqRunRules $Job } else { $null }
    if ($lvl -and $rules.EffortEnv) { $lvl = $null }
    $held = $null; $by = $null; $in = $null
    if ($uc) {
        $mode = Get-ChatqPermitMode $Job
        if ($rules.Workflow -in 'deny', 'ask') { $uc = $false; $held = $mode; $by = $rules.Workflow; $in = $rules.WorkflowIn }
        elseif ($mode -eq 'plan') { $uc = $false; $held = $mode; $by = 'mode' }
        elseif ($mode -notin 'auto', 'bypassPermissions') {
            if ($rules.Workflow -eq 'allow') { $by = 'allow'; $in = $rules.WorkflowIn }
            else { $uc = $false; $held = $mode; $by = 'mode' }
        }
    }
    return [pscustomobject]@{ Ultracode = $uc; Effort = $lvl; UltracodeHeld = $held; HeldBy = $by; RuleIn = $in }
}

function Format-ChatqUltracodeHeld {
    # Why a run goes without the Ultracode its chat had, in words for its
    # history (Get-ChatqRunCarry): '' when it did not. Plan mode's own: a
    # Workflow allow rule may mean it asks nothing, but a plan run is to
    # change nothing, and a workflow's agents would.
    param($Carry)
    $held = [string](Get-ChatField $Carry 'UltracodeHeld')
    if (-not $held) { return '' }
    $in = [string](Get-ChatField $Carry 'RuleIn')
    switch ([string](Get-ChatField $Carry 'HeldBy')) {
        'deny' { return "the $in settings deny Workflow" }
        'ask' { return "the $in settings ask before a Workflow" }
        default {
            if ($held -eq 'plan') { return "plan mode changes nothing, and a workflow's agents would" }
            return "$held mode asks before each Workflow"
        }
    }
}

function Test-ChatqRunUltracode {
    # Whether a queued Claude run starts with Ultracode, as the chat last had
    # it (Get-ChatqRunCarry)
    param($Job)
    return [bool](Get-ChatqRunCarry $Job).Ultracode
}

function Format-ChatqRunCarry {
    # What a run carries of the chat's session, in words, from the job's own
    # fields the watcher set at its start (Get-ChatqRunCarry): 'with
    # Ultracode', 'at effort max', both, or ''. A Codex run carries none of
    # it: its words are the model and effort its chat last ran on, as read
    # when it was queued (effortAtQueue) - 'gpt-5.6 at effort medium' - and
    # '' on a -Model of the job's, which the chat's level may not fit. Pure.
    param($Job)
    if ([string](Get-ChatField $Job 'provider') -eq 'codex') {
        if (Get-ChatField $Job 'runModel') { return '' }
        $md = [string](Get-ChatField $Job 'model')
        $ef = [string](Get-ChatField $Job 'effortAtQueue')
        return ((@($md, $(if ($ef) { "at effort $ef" })) | Where-Object { $_ }) -join ' ')
    }
    $w = @()
    if (Get-ChatField $Job 'ultracode') { $w += 'with Ultracode' }
    $e = [string](Get-ChatField $Job 'effort')
    if ($e) { $w += "at effort $e" }
    return ($w -join ', ')
}

function Get-ChatqRunTook {
    <#
    What a queued run into a Claude chat took, from its own records - the
    ones after -From, the transcript's length as it began: @{ Ultracode =
    $true|$false|$null; Effort = a level|$null }, $null where they do not
    say. Effort: the level on the run's first turn, an assistant record of
    a print-mode entrypoint's (sdk-cli, as claude -p writes) with an effort
    - one Claude Code made up itself, an error's, has none. Ultracode: a
    notice of the run's before that turn (ultra_effort_enter or _exit)
    says it. With none the run saw no change: Claude Code writes one with
    a prompt only when the state differs from the last notice it can see
    (Get-ChatSessionSettings), so the run had what that one says - a
    compact_boundary after it, or no notice at all, is off. Both only once
    the turn is there: a run cut off before its first turn says nothing.
    The records as Get-ChatSessionRecord reads them - a subagent's are not
    the run's; at most -Budget bytes read each way. Never throws. Not
    known: whether Ultracode on but idle - workflows turned off, a model
    below xhigh - still writes the enter; such a run reads as taken.
    #>
    param([string]$Path, [int64]$From, [int64]$Budget = $script:ChatSessionScanBudget)
    $none = @{ Ultracode = $null; Effort = $null }
    if (-not $Path -or $From -lt 0 -or $Budget -le 0) { return $none }
    $x = Get-ChatSessionRx
    $sdk = $script:ChatSdkEntrypoints
    $ord = [StringComparison]::Ordinal
    $latin = [System.Text.Encoding]::GetEncoding(28591)
    # a stretch of the file as Latin-1 text, one char a byte
    $readAt = {
        param([int64]$At, [int]$N)
        $b = [byte[]]::new($N)
        [void]$fs.Seek($At, [System.IO.SeekOrigin]::Begin)
        $got = 0
        while ($got -lt $N) { $r = $fs.Read($b, $got, $N - $got); if ($r -le 0) { break }; $got += $r }
        $latin.GetString($b, 0, $got)
    }
    try { $fs = Open-ChatRead $Path } catch { return $none }
    try {
        $size = $fs.Length
        if ($size -le $From) { return $none }
        # the run's records, from its start to its first turn: whole lines,
        # in stretches that double from 1 MB - the turn is near the start
        $uc = $null; $ef = $null
        $pos = $From
        $end = [Math]::Min($size, $From + $Budget)
        $win = [int64]1048576
        while ($pos -lt $end -and -not $ef) {
            $n = [int][Math]::Min($win, $end - $pos)
            $T = & $readAt $pos $n
            $win *= 2
            $last = if ($pos + $n -ge $end) { $T.Length } else { $T.LastIndexOf([char]10) + 1 }
            # one record longer than the stretch: read a longer one
            if ($last -le 0) { continue }
            $at = 0
            while ($at -lt $last) {
                $nl = $T.IndexOf([char]10, $at, $last - $at)
                $le = if ($nl -lt 0) { $last } else { $nl }
                $ls = $at
                $at = $le + 1
                if ($le -le $ls) { continue }
                # a notice's attachment; any other line that names one - a
                # turn that talks of it - goes on to the turn's check
                if ($T.IndexOf('"ultra_effort_e', $ls, $le - $ls, $ord) -ge 0) {
                    $k = Get-ChatSessionRecord ($T.Substring($ls, $le - $ls))
                    if ($k -and $k.K -ceq 'N') {
                        if (-not $k.Own) { $uc = $k.On }
                        continue
                    }
                }
                if ($T.IndexOf('"type":"assistant"', $ls, $le - $ls, $ord) -lt 0 -or $T.IndexOf('"effort":', $ls, $le - $ls, $ord) -lt 0) { continue }
                $m = $x.Obj.Match($T.Substring($ls, $le - $ls))
                if (-not $m.Success) { continue }
                $f = @{}
                $ks = $m.Groups['k'].Captures
                $vs = $m.Groups['v'].Captures
                for ($i = 0; $i -lt $ks.Count; $i++) { $f[$ks[$i].Value] = $vs[$i].Value }
                if ($f['"type"'] -cne '"assistant"' -or $f['"isSidechain"'] -ceq 'true') { continue }
                $ep = if ($f['"entrypoint"']) { Read-ChatJsonText $f['"entrypoint"'] } else { $null }
                if (-not $ep -or [Array]::IndexOf($sdk, [string]$ep) -lt 0) { continue }
                $e = if ($f['"effort"']) { Read-ChatJsonText $f['"effort"'] } else { $null }
                if ($e) { $ef = [string]$e; break }
            }
            $pos += $last
        }
        if (-not $ef) { return $none }
        if ($null -ne $uc) { return @{ Ultracode = $uc; Effort = $ef } }
        # no notice of the run's: the last one before it, or a compaction
        # since, read back in a stretch that doubles until a whole record
        # is found, the file's start or -Budget
        $win = [int64]1048576
        while ($true) {
            $w = [Math]::Min($win, [Math]::Min($From, $Budget))
            if ($w -le 0) { $uc = $false; break }
            $B = & $readAt ($From - $w) ([int]$w)
            $hi = $B.Length
            $cut = $false
            while ($hi -gt 0) {
                $p = [Math]::Max($B.LastIndexOf('"ultra_effort_e', $hi - 1, $hi, $ord), $B.LastIndexOf('"compact_boundary"', $hi - 1, $hi, $ord))
                if ($p -lt 0) { break }
                $ls = $B.LastIndexOf([char]10, $p) + 1
                # begun before this stretch: read a longer one
                if ($ls -eq 0 -and $From - $w -gt 0) { $cut = $true; break }
                $le = $B.IndexOf([char]10, $p)
                if ($le -lt 0) { $le = $B.Length }
                $k = Get-ChatSessionRecord ($B.Substring($ls, $le - $ls))
                if ($k -and $k.K -ceq 'N') { $uc = $k.On; break }
                if ($k -and $k.K -ceq 'B') { $uc = $false; break }
                $hi = $ls
            }
            if ($null -ne $uc) { break }
            if (-not $cut -and $From - $w -le 0) { $uc = $false; break }
            if ($w -ge $Budget) { break }
            $win *= 2
        }
        return @{ Ultracode = $uc; Effort = $ef }
    }
    catch { return $none }
    finally { $fs.Dispose() }
}

function Confirm-ChatqRunCarry {
    <#
    A run's carry as it ends: the job's ultracode and effort (set at its
    start, Get-ChatqRunCarry) put right by what the run took
    (Get-ChatqRunTook), and what differed in words for its history -
    'Ultracode not taken', 'ran at effort high, not max', both, or ''.
    What the records do not say leaves the job as its start set it.
    #>
    param($Job, $Took)
    if ($null -eq $Took) { return '' }
    $w = @()
    if ((Get-ChatField $Job 'ultracode') -and $Took.Ultracode -eq $false) {
        Set-ChatqProp $Job 'ultracode' $null
        $w += 'Ultracode not taken'
    }
    $e = [string](Get-ChatField $Job 'effort')
    if ($e -and $Took.Effort -and [string]$Took.Effort -cne $e) {
        Set-ChatqProp $Job 'effort' ([string]$Took.Effort)
        $w += "ran at effort $($Took.Effort), not $e"
    }
    return ($w -join ', ')
}

#endregion

#region running one job -------------------------------------------------------

function Test-ChatqFreshChat {
    # a new chat's job whose chat does not exist yet: nothing to resume, no
    # transcript to check, and no window can have it open
    param($Job)
    return [bool]($Job.kind -eq 'new' -and -not ($Job.path -and (Test-Path -LiteralPath $Job.path)))
}

function Update-ChatqNewChatPath {
    # A new chat's transcript is where its folder's slug says, unless Claude
    # named that folder otherwise: a path over 200 characters is cut and
    # hashed, and CLAUDE_CODE_PROJECT_DIR_NAME names it outright. Looked for
    # by its id in every project, and kept on the job once found - else every
    # retry would pass --session-id again, which Claude refuses once the
    # session exists.
    param($Job)
    if ($Job.kind -ne 'new' -or $Job.provider -ne 'claude' -or -not $Job.sessionId) { return }
    if ($Job.path -and (Test-Path -LiteralPath $Job.path)) { return }
    $base = if ($Job.home) { [string]$Job.home } else { $script:ChatClaudeHome }
    $p = Find-ChatOverlayTranscript $base $null ([string]$Job.sessionId)
    if (-not $p) { return }
    Set-ChatqProp $Job 'path' $p
    Set-ChatqProp $Job 'group' (Split-Path (Split-Path $p -Parent) -Leaf)
}

function Update-ChatqHeldTitle {
    # A phone-made chat with no name runs as 'phone chat 14:02', not as its
    # prompt's first line: every alert carries the job's title through the
    # push service (New-ChatqPhoneNewChat). Once the chat has a title of
    # Claude's own - its ai-title, or a rename - the job takes that and
    # holds it no more. Returns whether the title changed.
    param($Job)
    if (-not (Get-ChatField $Job 'titleHeld') -or $Job.provider -ne 'claude' -or -not $Job.path) { return $false }
    $f = Get-Item -LiteralPath ([string]$Job.path) -EA SilentlyContinue
    if (-not $f) { return $false }
    $rec = try { & $script:ChatProviders['claude'].Describe $f } catch { $null }
    if (-not $rec -or $rec.TitleSource -notin 'auto', 'renamed' -or -not $rec.Title) { return $false }
    Set-ChatqProp $Job 'title' ([string]$rec.Title)
    Set-ChatqProp $Job 'titleHeld' $false
    Set-ChatqHeldTitleMark ([string]$Job.sessionId) $null
    return $true
}

# sessionId -> the neutral title a phone-made chat runs under, kept apart
# from its jobs: chatqrm -Finished or the console's Remove takes those, and
# with them the title, while the chat may still have none of Claude's own
$script:ChatqHeldTitlesPath = Join-Path $script:ChatqData 'held-titles.json'

function Set-ChatqHeldTitleMark {
    # -Title $null drops the chat's mark. Only the newest 200 are kept: a
    # chat held that long ago and never titled since is one nobody runs.
    # Best effort - a lost mark puts back only the prompt's first line.
    param([string]$SessionId, [string]$Title)
    if (-not $SessionId) { return }
    try {
        $o = Read-ChatqJson $script:ChatqHeldTitlesPath
        $map = [ordered]@{}
        if ($o) { foreach ($p in $o.PSObject.Properties) { if ($p.Value -and $p.Value.title) { $map[$p.Name] = $p.Value } } }
        if (-not $Title) {
            if (-not $map.Contains($SessionId)) { return }
            $map.Remove($SessionId)
        }
        else { $map[$SessionId] = [ordered]@{ title = $Title; at = (Get-ChatqStamp) } }
        $keep = [ordered]@{}
        foreach ($k in @($map.Keys | Sort-Object { [string]$map[$_].at } -Descending | Select-Object -First 200)) { $keep[$k] = $map[$k] }
        if (-not $keep.Count) { Remove-Item -LiteralPath $script:ChatqHeldTitlesPath -Force -EA SilentlyContinue; return }
        New-ChatqDir $script:ChatqData
        Save-ChatqJson $script:ChatqHeldTitlesPath $keep
    }
    catch {}
}

function Get-ChatqHeldTitle {
    # The neutral title a phone-made chat still runs under, for a later job
    # into it and for a live alert about it (Update-ChatqLiveAlerts): until
    # Claude titles the chat its row's title is the prompt's first line
    # (Update-ChatqHeldTitle). A job of it that holds one, else the chat's
    # mark in data/held-titles.json, which outlives its jobs. $null when
    # neither has one, or the row's title is Claude's or yours already.
    param($Row)
    if (-not $Row -or $Row.Provider -ne 'claude' -or -not $Row.Id) { return $null }
    if ((Get-ChatField $Row 'Titled') -in 'auto', 'renamed') { return $null }
    foreach ($j in @(Get-ChatqJobs)) {
        if ([string]$j.sessionId -eq [string]$Row.Id -and (Get-ChatField $j 'titleHeld')) { return [string]$j.title }
    }
    $o = Read-ChatqJson $script:ChatqHeldTitlesPath
    if ($o) {
        $m = $o.PSObject.Properties[[string]$Row.Id]
        if ($m -and $m.Value -and $m.Value.title) { return [string]$m.Value.title }
    }
    return $null
}

# What a queued Claude run is given, each only where the watcher's own
# environment does not set it already (Invoke-ChatqRun). Print mode kills a
# background shell 5 s after the turn ends (Claude Code 2.1.283), so a suite
# the model sent to the background died unseen: background tasks off, and it
# runs in the foreground instead - up to an hour, and 30 minutes when the
# model names no timeout, since with background tasks off a long command is
# never moved to the background by itself either. Print mode waits for a
# workflow or an agent the run started, up to the ceiling: an hour, not the
# 10 minutes it would give, nor for ever - one hung workflow must not hold
# every job behind it until the run's 4 h deadline.
$script:ChatqRunEnv = [ordered]@{
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '1'
    BASH_MAX_TIMEOUT_MS                  = '3600000'
    BASH_DEFAULT_TIMEOUT_MS              = '1800000'
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '3600000'
}

function Invoke-ChatqRun {
    # Deliver one job's prompt into its chat and read what came back. The
    # caller owns the job's state; this only runs and classifies. -Permit:
    # New-ChatqPermitRun's run, when a prompt mid-run is to ask the phone.
    # -Carry: the watcher's Get-ChatqRunCarry, judged once for its log;
    # $null judges it here.
    param($Job, [string]$Prompt, [scriptblock]$OnTick, [scriptblock]$OnStart, [object[]]$Files,
        $Permit, $Carry = $null)
    $exe = Find-ChatqExe $Job.provider
    if (-not $exe) { return [pscustomobject]@{ kind = 'failed'; reason = "no $($Job.provider) CLI found - install it or set CHATQ_$($Job.provider.ToUpper())" } }
    $log = Join-Path $script:ChatqLogDir "$($Job.id).jsonl"
    $st = New-ChatqRunState
    $mode = if ($Job.mode) { $Job.mode } elseif ($Job.modeAtQueue) { $Job.modeAtQueue } else { 'default' }
    # Files named under the prompt: all of them for Claude, which opens each
    # itself; for Codex the ones that are not images, which go with -i instead -
    # the shape spike S18 saw both act on
    $Files = @($Files | Where-Object { $_ })
    $imgs = @($Files | Where-Object { $_.Extension.ToLowerInvariant() -in $script:ChatqImageExt })
    if ($Job.provider -eq 'codex') {
        $Prompt += Format-ChatqAttachFooter @($Files | Where-Object { $_.Extension.ToLowerInvariant() -notin $script:ChatqImageExt })
        if ($imgs) { $Prompt += "`n`n($($imgs.Count) image$(if ($imgs.Count -ne 1) { 's are' } else { ' is' }) attached to this message.)" }
    }
    elseif ($Files) { $Prompt += Format-ChatqAttachFooter $Files }
    if ($Job.provider -eq 'codex') {
        # the job's own pick, else the chat's - never a word codex refuses:
        # a job saved with 'managed' would fail as the config loads, so it
        # runs workspace-write and the diary says why
        $sb = Get-ChatqCodexRunSandbox $Job
        if ($sb.Unknown) { Write-ChatqJobLog "#$($Job.seq) its chat's sandbox '$($sb.Unknown)' is no word codex takes - runs in workspace-write $($script:ChatqDot) $($Job.title)" }
        $a = @('exec', 'resume', '--json', '--skip-git-repo-check', '-c', "sandbox_mode=$($sb.Sandbox)")
        # the chat's network setting is workspace-write's alone: read-only
        # has none, and full access has it anyway
        if ($Job.network -and $sb.Sandbox -eq 'workspace-write') { $a += @('-c', 'sandbox_workspace_write.network_access=true') }
        if ($Job.runModel) { $a += @('-m', $Job.runModel) }
        foreach ($f in $imgs) { $a += @('-i', $f.FullName) }
        # -i can take several values, so -- keeps the thread id from being read
        # as one more image
        if ($imgs) { $a += '--' }
        $a += @($Job.sessionId, '-')
        # an npm codex.cmd: an image path holding a quote or a %, refused
        # here as the run's own failure rather than thrown from its start
        $no = Get-ChatqCmdArgRefusal $exe $a
        if ($no) { return [pscustomobject]@{ kind = 'failed'; reason = $no } }
        $proc = Invoke-ChatqProcess -Exe $exe -ArgList $a -WorkDir $Job.cwd -StdIn $Prompt -LogPath $log `
            -SetEnv @{ CODEX_HOME = $Job.home } -OnTick $OnTick -OnLine {
            param($l)
            Update-ChatqCodexState $st $l
            if ($st.Init -and -not $st.Started) { $st.Started = $true; if ($OnStart) { & $OnStart $st } }
        }
        return (Get-ChatqCodexOutcome $st $proc)
    }
    $v = Get-ChatqCliVersion $exe
    if ($v -and ((Compare-ChatVersion $v $script:ChatqClaudeMin) -eq -1)) {
        return [pscustomobject]@{ kind = 'failed'; reason = "Claude Code $v is too old for unattended runs - needs $($script:ChatqClaudeMin)+" }
    }
    # A new chat's first run: the session id it was given when queued, and its
    # name as the title the chat list shows (spike S25). Once its transcript
    # exists - the prompt got that far before a limit or a dropped
    # connection - it is resumed like any other, never started twice.
    # A claude.cmd from npm runs through cmd.exe, which reads \" as no escape
    # at all: a quote in the title would end the argument there and hand the
    # rest - an & and what follows - to cmd as a command of its own. The
    # title shows in a list, and loses nothing it needs without these: the
    # rest of the line is quoted for cmd (ConvertTo-ChatqArgLine), but a
    # quote or a %name% in a title would fail the run, and a ! is cmd's
    # own where delayed expansion is on.
    $name = [string]$Job.title
    if (Test-ChatqCmdExe $exe) { $name = (($name -replace '["%!&|<>^]', ' ') -replace '\s+', ' ').Trim() }
    $start = if (Test-ChatqFreshChat $Job) { @('--session-id', $Job.sessionId, '--name', $name) } else { @('--resume', $Job.sessionId) }
    $a = @('-p') + $start + @('--output-format', 'stream-json', '--verbose',
        '--permission-mode', $mode, '--permission-prompts', 'none')
    # A prompt goes to the phone's bridge rather than being denied outright
    # (src/permit.ps1): its MCP server, the tool that decides, and the run's
    # own rules beside the user's - files named here, never their JSON, which
    # cmd.exe would take apart for a claude.cmd.
    if ($Permit) {
        $a[[Array]::IndexOf($a, '--permission-prompts') + 1] = 'host'
        $a += @('--mcp-config', $Permit.McpPath, '--permission-prompt-tool', $script:ChatqPermitTool, '--settings', $Permit.SettingsPath)
        $Permit.St = $st
    }
    # only when -Model asked for one: a resume keeps the chat's own model, and
    # naming it would pin the run to an id that may since have been retired
    if ($Job.runModel) { $a += @('--model', $Job.runModel) }
    # Ultracode and a session-only level live only in the chat's own
    # process: a run not told starts without them, however the chat was left
    # (Get-ChatqRunCarry). The level by --effort. Ultracode by a settings
    # key, never --effort ultracode, which forces xhigh - and in the one
    # --settings claude reads, the last one given: the permit's own file
    # when the run has one, else a file of the job's (a file, never inline
    # JSON, which cmd.exe would take apart for a claude.cmd).
    if ($null -eq $Carry) { $Carry = Get-ChatqRunCarry $Job }
    if ($Carry.Effort) { $a += @('--effort', [string]$Carry.Effort) }
    $ownSet = $null
    if ($Carry.Ultracode) {
        if ($Permit) {
            # added to the rules the permit's file was written from, never
            # read back from it: a read that failed would save ultracode
            # alone, and the run would go without the permit's deny rules
            $Permit.Settings['ultracode'] = $true
            Save-ChatqJson $Permit.SettingsPath $Permit.Settings
        }
        else {
            $ownSet = Join-Path $script:ChatqRunSettingsDir "$($Job.id).json"
            Save-ChatqJson $ownSet ([ordered]@{ ultracode = $true })
            $a += @('--settings', $ownSet)
        }
    }
    # Claude Code 2.1.280 read files outside the project unasked (spike S18);
    # naming the job's folder keeps that true under a stricter version or a
    # settings file that limits reads to the workspace
    if ($Files) { $a += @('--add-dir', (Get-ChatqAttachDir $Job)) }
    $runEnv = @{ CLAUDE_CONFIG_DIR = $Job.home }
    # claude's own wait on the bridge ends 3 minutes after the bridge's: a
    # call it times out is an error the model retries, never a denial (S35)
    if ($Permit) { $runEnv['MCP_TOOL_TIMEOUT'] = [string]$Permit.TimeoutMs }
    foreach ($k in $script:ChatqRunEnv.Keys) {
        # the user's own setting stands; and never a $null, which removes one
        if ($null -eq [Environment]::GetEnvironmentVariable($k)) { $runEnv[$k] = $script:ChatqRunEnv[$k] }
    }
    # Every argument through an npm claude.cmd is quoted where cmd.exe
    # would act on it; one it cannot carry at all - a data folder whose
    # path holds a quote or a %name% (Get-ChatqCmdArgRefusal) - fails the
    # run with that said, and nothing it wrote for the run is left behind
    $no = Get-ChatqCmdArgRefusal $exe $a
    if ($no) {
        if ($ownSet) { Remove-Item -LiteralPath $ownSet -Force -EA SilentlyContinue }
        if ($Permit) { $null = Close-ChatqPermitRun $Job $Permit }
        return [pscustomobject]@{ kind = 'failed'; reason = $no }
    }
    try {
        $proc = Invoke-ChatqProcess -Exe $exe -ArgList $a -WorkDir $Job.cwd -StdIn $Prompt -LogPath $log `
            -SetEnv $runEnv -OnTick $OnTick -OnLine {
            param($l)
            Update-ChatqClaudeState $st $l
            if ($st.Init -and -not $st.Started) { $st.Started = $true; if ($OnStart) { & $OnStart $st } }
        }
    }
    finally {
        # read at the start only, and gone however the run ended - a start
        # that threw included; one left by a watcher that died is written
        # afresh by the job's next run
        if ($ownSet) { Remove-Item -LiteralPath $ownSet -Force -EA SilentlyContinue }
    }
    if ($Permit) {
        # what the phone answered decides what the denials mean; a run the
        # bridge never came up for says so, for one retry without it
        $closed = Close-ChatqPermitRun $Job $Permit
        $o = Get-ChatqClaudeOutcome $st $proc $mode -Refused $closed.Refused -NoAnswer $closed.NoAnswer
        if (Test-ChatqPermitStartFailed $o $proc.StdErr $st $Permit) { Set-ChatqProp $o 'permitFailed' $true }
        return $o
    }
    return (Get-ChatqClaudeOutcome $st $proc $mode)
}

#endregion
