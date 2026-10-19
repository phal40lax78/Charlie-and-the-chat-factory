# tests/vectors/board.ps1: native/vectors/board.json (native/SPEC.md 6.1).
# data/queue.md as Write-ChatqBoard (src/alerts.ps1) writes it while the
# watcher is not listening: a case's job files, prompt files and state.json
# written into a data/ of its own, the real function run on a pinned clock in
# a culture and a zone, and the file it saved read back. data/watcher.lock is
# held open as chatqd holds it, so Get-ChatqBlocks reads the lanes from
# state.json and the status line says the watcher runs.
#
# The answer is the board's lines, the file split at Environment.NewLine, and
# the --culture argument the real Get-ChatqWatcherLaunch -Native builds in
# that culture, which is all chatqd learns of it (SPEC 2.11). The Rust runner
# joins the lines with its own newline, so the board is checked CRLF on
# Windows and LF elsewhere; for that, no prompt holds a CRLF of its own. A
# board PowerShell does not write (it threw, and the catch kept quiet) has
# null lines.
#
# Two recipes keep the file small, and both sides expand them. A job is its
# number n and the fields it has over n's defaults (Get-NvBoardJobFile); a
# big prompt is fills: a unit repeated, written as the prompt, and the answer
# has <<unit*times>> wherever the board has the run.
#
# Zones with no DST and their offsets in utcOffsetMinutes, so the runner
# needs no zone database: India (+05:30) and Lima (-05:00), the clock at
# 09:00 UTC on Thursday 2026-10-15, 14:30 and 04:00 there. A file is read as
# the tool reads it, so a stamp with no zone is UTC to 5.1 and the zone's
# wall clock to pwsh 7.

function New-NvBoardCase {
    # one case: the clock in $Zone, $Culture, and the rest of its input
    param([string]$Name, [System.Collections.IDictionary]$More, [string]$Culture = 'en-US', [string]$Zone = 'India Standard Time', [int]$Off = 330)
    $in = [ordered]@{ culture = $Culture; zone = $Zone; utcOffsetMinutes = $Off; now = '2026-10-15T09:00:00.0000000Z' }
    foreach ($k in $More.Keys) { $in[$k] = $More[$k] }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvBoardJob {
    # a job's recipe: its number, its state where that is not queued, and
    # $Set's fields over n's defaults ($null drops one)
    param([int]$N, [string]$State, [System.Collections.IDictionary]$Set)
    $e = [ordered]@{ n = $N }
    if ($State -and $State -cne 'queued') { $e['state'] = $State }
    if ($Set) { foreach ($k in @($Set.Keys)) { $e[$k] = $Set[$k] } }
    return $e
}

function Get-NvBoardJobFile {
    # a job file from its recipe: id j<n>, seq n, title "chat <n>", provider
    # claude, cwd code\app, rule typed, kind prompt, promptFile p<n>.md, mode
    # default, state queued, made n minutes past 08:00 UTC the day before (so
    # n is the queue order within a group), and the recipe's other fields
    # over these in order, a null one dropping the field
    param($E)
    $n = [int]$E.n
    $j = [ordered]@{
        id = "j$n"; seq = $n; title = "chat $n"; provider = 'claude'; cwd = 'code\app'; rule = 'typed'; kind = 'prompt'
        promptFile = "p$n.md"; mode = 'default'; state = 'queued'; createdAt = ('2026-10-14T08:' + ([string]$n).PadLeft(2, '0') + ':00.0000000Z')
    }
    foreach ($p in $E.PSObject.Properties) {
        if ($p.Name -ceq 'n') { continue }
        if ($null -eq $p.Value) { $j.Remove($p.Name) } else { $j[$p.Name] = $p.Value }
    }
    return $j
}

function New-NvBoardInput {
    # a case's files: its job recipes, a prompt for each job that names a
    # file - "Prompt <n>." unless $Prompts gives its own, none where that is
    # $null or a fill makes it - state.json when $State is given, and $More's
    # fields
    param([object[]]$Jobs, [System.Collections.IDictionary]$Prompts, $State, [System.Collections.IDictionary]$More)
    $filled = @(if ($More -and $More.Contains('fills')) { foreach ($x in $More['fills']) { $x['file'] } })
    $p = [ordered]@{}
    foreach ($e in $Jobs) {
        $f = if ($e.Contains('promptFile')) { $e['promptFile'] } else { "p$($e['n']).md" }
        if (-not $f -or $filled -contains $f) { continue }
        if ($Prompts -and $Prompts.Contains($f)) {
            if ($null -ne $Prompts[$f]) { $p[$f] = $Prompts[$f] }
        }
        else { $p[$f] = "Prompt $($e['n'])." }
    }
    $in = [ordered]@{ jobs = $Jobs; prompts = $p }
    if ($null -ne $State) { $in['state'] = $State }
    if ($More) { foreach ($k in $More.Keys) { $in[$k] = $More[$k] } }
    return $in
}

function Get-NvBoardLine {
    # $N characters of the alphabet, over and over
    param([int]$N)
    return (('abcdefghijklmnopqrstuvwxyz' * 8).Substring(0, $N))
}

function Get-NvBoardFull {
    # the full board: a row of each kind, a lane of each kind of wait, and a
    # running job that asks the phone
    $jobs = @(
        (New-NvBoardJob 1 'running' ([ordered]@{ title = 'fix the build'; mode = 'acceptEdits'; permitWaiting = [ordered]@{ tool = 'Bash'; until = '2026-10-15T09:30:00.0000000Z' } })),
        (New-NvBoardJob 2 'queued' ([ordered]@{ title = 'refactor | split'; rule = 'auto'; kind = 'continue'; promptFile = $null; auto = $true })),
        (New-NvBoardJob 3 'queued' ([ordered]@{ title = 'docs'; first = '2026-10-15T08:30:00.0000000Z' })),
        (New-NvBoardJob 4 'queued' ([ordered]@{ title = 'port the parser'; provider = 'codex'; mode = 'full-auto' })),
        (New-NvBoardJob 5 'queued' ([ordered]@{ title = 'tests for the parser'; provider = 'codex'; mode = 'full-auto' })),
        (New-NvBoardJob 6 'queued' ([ordered]@{ title = 'release notes'; home = 'work' })),
        (New-NvBoardJob 7 'queued' ([ordered]@{ title = 'flaky test'; retryAt = '2026-10-15T11:00:00.0000000Z' })),
        (New-NvBoardJob 8 'needs-input' ([ordered]@{ title = 'merge'; result = [ordered]@{ kind = 'question'; reason = 'asks which branch'; excerpt = "Which branch?`nmain | dev" } })),
        (New-NvBoardJob 9 'failed' ([ordered]@{ title = 'installer'; result = [ordered]@{ kind = 'error'; reason = 'exit 1' } })),
        (New-NvBoardJob 10 'done' ([ordered]@{ title = 'changelog'; endedAt = '2026-10-15T07:00:00.0000000Z'; result = [ordered]@{ kind = 'done' } })),
        (New-NvBoardJob 11 'skipped' ([ordered]@{ title = 'old one'; endedAt = '2026-10-12T09:00:00.0000000Z' }))
    )
    $prompts = [ordered]@{
        'p1.md' = "<!-- chatq: prompt for 'fix the build' (claude). -->`n`nRun the tests and fix what fails.`nThen commit."
        'p3.md' = 'Write the docs for <Parser> & "Lexer" - it''s the long first line, past eighty characters, so it folds.'
        'p4.md' = "Port the parser to Rust.`n`n``````rust`nfn main() {}`n``````"
        'p10.md' = 'Update the changelog, caf' + [char]0xE9 + ' style.'
    }
    $state = [ordered]@{
        blocked = [ordered]@{
            codex = [ordered]@{ until = '2026-10-16T11:00:00.0000000Z'; type = 'weekly'; source = 'probe'; at = '2026-10-15T08:00:00.0000000Z' }
            'codex|ci' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
            claude = [ordered]@{ until = '2026-10-15T08:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
        }
        outage = [ordered]@{
            'claude|work' = [ordered]@{ since = '2026-10-15T08:10:00.0000000Z'; next = '2026-10-15T09:20:00.0000000Z'; status = 'major_outage'; attempts = 2; alerted = $true }
        }
        listening = $false
    }
    return (New-NvBoardInput $jobs $prompts $state)
}

function Get-NvBoardClocks {
    # what the culture and the zone change: the times on the status line,
    # the sends column and the phone's wait, the day a time falls on, and
    # big counts
    $jobs = @(
        (New-NvBoardJob 1 'running' ([ordered]@{ title = 'build'; permitWaiting = [ordered]@{ tool = 'Bash'; until = '2026-10-15T09:30:00.0000000Z' } })),
        (New-NvBoardJob 2 'queued' ([ordered]@{ provider = 'codex' })),
        (New-NvBoardJob 3 'queued' ([ordered]@{ home = 'work' })),
        (New-NvBoardJob 4 'queued' ([ordered]@{ notBefore = '2026-10-15T20:00:00.0000000Z' })),
        (New-NvBoardJob 5 'queued' ([ordered]@{ provider = 'codex'; home = 'ci' }))
    )
    $state = [ordered]@{
        blocked = [ordered]@{
            codex = [ordered]@{ until = '2026-10-16T11:00:00.0000000Z'; type = 'weekly'; source = 'probe' }
            'codex|ci' = [ordered]@{ until = '2026-10-15T19:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
        }
        outage = [ordered]@{ 'claude|work' = [ordered]@{ since = '2026-10-15T08:10:00.0000000Z'; status = 'major_outage' } }
    }
    $fills = [ordered]@{ fills = @(
            [ordered]@{ file = 'p1.md'; unit = 'x'; times = 1234 },
            [ordered]@{ file = 'p2.md'; unit = 'y'; times = 123456 },
            [ordered]@{ file = 'p3.md'; unit = 'z'; times = 1234567 }
        )
    }
    return (New-NvBoardInput $jobs $null $state $fills)
}

function Get-NvBoardList {
    # an input's list, empty when the case has none
    param($In, [string]$Field)
    if (-not $In.PSObject.Properties[$Field]) { return , @() }
    return , @($In.$Field)
}

function Write-NvBoardText {
    param([string]$Path, [string]$Text)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-NvBoardCulture {
    # the value after --culture in the native launch the real
    # Get-ChatqWatcherLaunch builds in this thread's culture; it starts nothing
    $a = @((Get-ChatqWatcherLaunch -Path 'chatq.ps1' -Native 'chatqd').Args)
    $k = [array]::IndexOf($a, '--culture')
    if ($k -lt 0 -or $k + 1 -ge $a.Count) { throw 'the native launch has no --culture' }
    return [string]$a[$k + 1]
}

Register-NvVector -Name 'board' -About 'data/queue.md as Write-ChatqBoard (src/alerts.ps1) writes it while the watcher is not listening, golden: the job files, prompt files and state.json of the input in a data/ of its own, data/watcher.lock held open (the watcher runs, so the lanes come from state.json through Get-ChatqBlocks), the clock at now in zone (utcOffsetMinutes east of UTC) and the culture, whose --culture argument (Get-ChatqWatcherLaunch -Native) the answer carries. jobs: queue/j<n>.json each, from id j<n>, seq n, title "chat <n>", provider claude, cwd code\app, rule typed, kind prompt, promptFile p<n>.md, mode default, state queued, createdAt n minutes past 2026-10-14T08:00:00Z, with the other fields over these in order, a null one dropping the field. prompts: queue/<name> each. fills: queue/<file>, unit repeated times. lines: the saved file split at Environment.NewLine, the last one empty, with <<unit*times>> where it has a fill; null where PowerShell wrote no board. A stamp with no zone is UTC to 5.1 and the zone''s wall clock to pwsh 7.' -Cases {
    $india = 'India Standard Time'
    $lima = 'SA Pacific Standard Time'

    # --- the culture and the zone ------------------------------------------------
    New-NvBoardCase 'full board' (Get-NvBoardFull)
    foreach ($c in 'en-US', 'de-DE', 'hi-IN') {
        New-NvBoardCase "clocks and counts, $c, India" (Get-NvBoardClocks) $c $india 330
        New-NvBoardCase "clocks and counts, $c, Lima" (Get-NvBoardClocks) $c $lima -300
    }
    New-NvBoardCase 'clocks and counts, fi-FI, India' (Get-NvBoardClocks) 'fi-FI' $india 330
    foreach ($c in 'en-US', 'de-DE', 'hi-IN') {
        New-NvBoardCase "empty queue, $c, India" ([ordered]@{}) $c $india 330
        New-NvBoardCase "empty queue, $c, Lima" ([ordered]@{}) $c $lima -300
    }
    New-NvBoardCase 'nothing to show: old jobs and a lane free again' (New-NvBoardInput @(
            (New-NvBoardJob 1 'cancelled'),
            (New-NvBoardJob 2 'done' ([ordered]@{ endedAt = '2026-10-12T09:00:00.0000000Z' })),
            (New-NvBoardJob 3 'skipped')
        ) $null ([ordered]@{ blocked = [ordered]@{ claude = [ordered]@{ until = '2026-10-15T08:59:00.0000000Z'; type = 'five-hour'; source = 'probe' } } }))

    # --- rows ----------------------------------------------------------------------
    New-NvBoardCase 'states: what shows, in queue order' (New-NvBoardInput @(
            (New-NvBoardJob 1 'queued'),
            (New-NvBoardJob 2 'QUEUED'),
            (New-NvBoardJob 3 'needs-input'),
            (New-NvBoardJob 4 'failed'),
            (New-NvBoardJob 5 'done' ([ordered]@{ endedAt = '2026-10-15T08:00:00.0000000Z' })),
            (New-NvBoardJob 6 'skipped' ([ordered]@{ endedAt = '2026-10-15T08:00:00.0000000Z' })),
            (New-NvBoardJob 7 'cancelled'),
            (New-NvBoardJob 8 'paused'),
            (New-NvBoardJob 9 'running'),
            (New-NvBoardJob 10 'failed' ([ordered]@{ id = $null }))
        ))
    New-NvBoardCase 'continue: the table names it, the prompt is the continue text' (New-NvBoardInput @(
            (New-NvBoardJob 1 'queued' ([ordered]@{ kind = 'continue'; auto = $true; promptFile = $null })),
            (New-NvBoardJob 2 'queued' ([ordered]@{ kind = 'continue'; auto = $false; promptFile = $null })),
            (New-NvBoardJob 3 'queued' ([ordered]@{ kind = 'Continue'; auto = 'yes'; promptFile = $null })),
            (New-NvBoardJob 4 'failed' ([ordered]@{ kind = 'continue' })),
            (New-NvBoardJob 5 'queued' ([ordered]@{ kind = $true; promptFile = $null })),
            (New-NvBoardJob 6 'queued' ([ordered]@{ rule = 'restart' }))
        ))
    New-NvBoardCase 'first line: cut at 60 in the table and at 80 in the summary' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed'), (New-NvBoardJob 2 'failed'), (New-NvBoardJob 3 'failed'),
            (New-NvBoardJob 4 'failed'), (New-NvBoardJob 5 'failed')
        ) ([ordered]@{
                'p1.md' = (Get-NvBoardLine 60); 'p2.md' = (Get-NvBoardLine 61); 'p3.md' = (Get-NvBoardLine 80)
                'p4.md' = (Get-NvBoardLine 81) + "`nthe second line"; 'p5.md' = "short   `n`nsecond line`nthird"
            }))
    $smile = [char]::ConvertFromUtf32(0x1F600)
    New-NvBoardCase 'first line: an emoji whole, and cut in half' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ title = "smile $smile" })), (New-NvBoardJob 2 'failed')
        ) ([ordered]@{ 'p1.md' = (Get-NvBoardLine 59) + $smile + ' tail'; 'p2.md' = (Get-NvBoardLine 79) + $smile + ' tail' }))
    New-NvBoardCase 'summary: HTML encoded there, not in the table' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ title = '<b>bold</b> & co' })), (New-NvBoardJob 2 'failed')
        ) ([ordered]@{
                'p1.md' = 'Use <b> & "quotes", it''s caf' + [char]0xE9 + [char]0xA0 + [char]0xFF + [char]0x100 + ' > all'
                'p2.md' = "a carriage`rreturn alone`nsecond line"
            }))
    New-NvBoardCase 'fence: longer than any backtick run' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed'), (New-NvBoardJob 2 'failed'), (New-NvBoardJob 3 'failed'), (New-NvBoardJob 4 'failed')
        ) ([ordered]@{
                'p1.md' = "Run:`n``````sh`nmake`n``````"; 'p2.md' = 'Five: ``````````'
                'p3.md' = 'One `tick` only'; 'p4.md' = 'Two `` ticks'
            }))
    New-NvBoardCase 'titles: pipes, newlines, none, a number' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ title = 'a | b' })),
            (New-NvBoardJob 2 'failed' ([ordered]@{ title = "two`nlines" })),
            (New-NvBoardJob 3 'failed' ([ordered]@{ title = "crlf`r`n`r`nend" })),
            (New-NvBoardJob 4 'failed' ([ordered]@{ title = $null })),
            (New-NvBoardJob 5 'failed' ([ordered]@{ title = 42 })),
            (New-NvBoardJob 6 'failed' ([ordered]@{ title = 'grep a\|b' })),
            (New-NvBoardJob 7 'failed' ([ordered]@{ seq = $null })),
            (New-NvBoardJob 8 'failed' ([ordered]@{ seq = '8' }))
        ))
    # [string] of what is no text: an object is @{...}, a double has 15 digits
    New-NvBoardCase 'titles: an object and doubles' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ title = [ordered]@{ x = 1 } })),
            (New-NvBoardJob 2 'failed' ([ordered]@{ title = [double]1e20 })),
            (New-NvBoardJob 3 'failed' ([ordered]@{ title = [double]1e-7 }))
        ))
    New-NvBoardCase 'results: reason, excerpt, both, neither' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ result = [ordered]@{ kind = 'error'; reason = 'exit 1 | broken' } })),
            (New-NvBoardJob 2 'failed' ([ordered]@{ result = [ordered]@{ kind = 'limit'; excerpt = "line one`nline two" } })),
            (New-NvBoardJob 3 'needs-input' ([ordered]@{ result = [ordered]@{ kind = 'question'; reason = "two`r`nlines"; excerpt = 'pick one' } })),
            (New-NvBoardJob 4 'done' ([ordered]@{ endedAt = '2026-10-15T08:00:00.0000000Z'; result = [ordered]@{ kind = 'done' } })),
            (New-NvBoardJob 5 'failed' ([ordered]@{ result = [ordered]@{ reason = 'no kind' } })),
            (New-NvBoardJob 6 'failed' ([ordered]@{ result = 'oops' })),
            (New-NvBoardJob 7 'failed' ([ordered]@{ result = [ordered]@{ kind = 'error'; reason = ''; excerpt = '' } }))
        ))
    New-NvBoardCase 'mode: mode, else modeAtQueue' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ provider = 'codex'; mode = 'plan'; modeAtQueue = 'default'; rule = 'last'; cwd = 'src' })),
            (New-NvBoardJob 2 'failed' ([ordered]@{ mode = ''; modeAtQueue = 'acceptEdits' })),
            (New-NvBoardJob 3 'failed' ([ordered]@{ mode = $null })),
            (New-NvBoardJob 4 'failed' ([ordered]@{ mode = $false; modeAtQueue = 'bypassPermissions' }))
        ))
    $head = "<!-- chatq: prompt for 'chat 1' (claude). Everything after this comment is sent as it is when the limit resets. Save and close the tab to queue it; leave it empty to cancel. -->`n`n"
    $bom = [string][char]0xFEFF
    New-NvBoardCase 'prompt files: header, BOM, missing, empty' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed'), (New-NvBoardJob 2 'failed'), (New-NvBoardJob 3 'failed'), (New-NvBoardJob 4 'failed'),
            (New-NvBoardJob 5 'failed'), (New-NvBoardJob 6 'failed'), (New-NvBoardJob 7 'failed'), (New-NvBoardJob 8 'failed'),
            (New-NvBoardJob 9 'failed'), (New-NvBoardJob 10 'failed')
        ) ([ordered]@{
                'p1.md' = $head + 'The real prompt.'
                'p2.md' = $bom + "<!-- chatq: x -->`n`nAfter a BOM."
                'p3.md' = $null
                'p4.md' = $head
                'p5.md' = "   `n`t`n  "
                'p6.md' = "Keep this.`n<!-- chatq: not a header -->"
                'p7.md' = "<!-- chatq: one -->`n<!-- chatq: two -->`nText"
                'p8.md' = "  `n <!--chatq:x-->Body"
                'p9.md' = "<!-- note -->`nBody"
                'p10.md' = $bom + $bom + 'Body'
            }))
    New-NvBoardCase 'no promptFile: the board is not written' (New-NvBoardInput @(
            (New-NvBoardJob 1 'failed' ([ordered]@{ promptFile = $null }))
        ))

    # --- the status line -------------------------------------------------------------
    $lanes = [ordered]@{
        blocked = [ordered]@{
            claude = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
            codex = [ordered]@{ until = '2026-10-16T11:00:00.0000000Z'; type = 'weekly'; source = 'probe' }
            'claude|home' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'login needed'; source = 'probe' }
            'claude|w2' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'login needed'; source = 'Invalid API key' }
            'codex|x' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'Login Needed' }
            'claude|old' = [ordered]@{ until = '2026-10-15T08:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
            'codex|y' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'Overloaded'; source = 'probe' }
            'claude|r' = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'five-hour'; source = 'probe' }
        }
        outage = [ordered]@{
            'codex|z' = [ordered]@{ since = '2026-10-15T08:10:00.0000000Z'; next = '2026-10-15T09:20:00.0000000Z'; status = 'partial_outage'; attempts = 1 }
            'claude|q' = [ordered]@{ next = '2026-10-15T09:20:00.0000000Z' }
            'Claude|R' = [ordered]@{ since = '2026-10-14T20:00:00.0000000Z' }
        }
    }
    $laneJobs = @(
        (New-NvBoardJob 1 'queued' ([ordered]@{ home = 'home' })),
        (New-NvBoardJob 2 'queued' ([ordered]@{ provider = 'codex'; home = 'y' })),
        (New-NvBoardJob 3 'queued' ([ordered]@{ home = 'R' })),
        (New-NvBoardJob 4 'queued' ([ordered]@{ home = 'old' }))
    )
    New-NvBoardCase 'status line: every kind of lane, India' (New-NvBoardInput $laneJobs $null $lanes)
    New-NvBoardCase 'status line: every kind of lane, Lima' (New-NvBoardInput $laneJobs $null $lanes) 'en-US' $lima -300
    New-NvBoardCase 'status line: every kind of lane, fi-FI' (New-NvBoardInput @() $null $lanes) 'fi-FI' $india 330

    # --- sends ---------------------------------------------------------------------
    New-NvBoardCase 'sends: every wait a queued job has' (New-NvBoardInput @(
            (New-NvBoardJob 1 'running'),
            (New-NvBoardJob 2 'queued'),
            (New-NvBoardJob 3 'queued' ([ordered]@{ notBefore = '2026-10-15T09:45:00.0000000Z' })),
            (New-NvBoardJob 4 'queued' ([ordered]@{ notBefore = '2026-10-15T08:00:00.0000000Z' })),
            (New-NvBoardJob 5 'queued' ([ordered]@{ retryAt = '2026-10-15T10:00:00.0000000Z' })),
            (New-NvBoardJob 6 'queued' ([ordered]@{ retryAt = '2026-10-15T08:00:00.0000000Z' })),
            (New-NvBoardJob 7 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:05:00.0000000Z' })),
            (New-NvBoardJob 8 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:10:00.0000000Z'; deferWhy = 'vscode' })),
            (New-NvBoardJob 9 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:15:00.0000000Z'; deferWhy = 'in-use' })),
            (New-NvBoardJob 10 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:20:00.0000000Z'; deferWhy = 'in-use'; notBefore = '2026-10-15T11:00:00.0000000Z' })),
            (New-NvBoardJob 11 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:25:00.0000000Z'; deferWhy = 'background'; deferSince = '2026-10-15T07:30:00.0000000Z' })),
            (New-NvBoardJob 12 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:30:00.0000000Z'; deferWhy = 'Background'; deferSince = '2026-10-12T07:30:00.0000000Z' })),
            (New-NvBoardJob 13 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:35:00.0000000Z'; deferWhy = 'background'; deferSince = '2026-10-05T07:30:00.0000000Z' })),
            (New-NvBoardJob 14 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:40:00.0000000Z'; deferWhy = 'background' })),
            (New-NvBoardJob 15 'queued' ([ordered]@{ deferUntil = '2026-10-15T08:00:00.0000000Z'; deferWhy = 'in-use' })),
            (New-NvBoardJob 16 'queued' ([ordered]@{ deferUntil = '2026-10-15T10:45:00.0000000Z'; retryAt = '2026-10-15T11:30:00.0000000Z' })),
            (New-NvBoardJob 17 'queued' ([ordered]@{ provider = 'codex' }))
        ) $null ([ordered]@{ outage = [ordered]@{ codex = [ordered]@{ since = '2026-10-15T08:00:00.0000000Z'; next = '2026-10-15T09:10:00.0000000Z'; status = 'major_outage' } } }))
    $days = @(
        (New-NvBoardJob 1 'queued' ([ordered]@{ deferUntil = '2026-10-15T20:00:00.0000000Z'; deferWhy = 'background'; deferSince = '2026-10-14T20:00:00.0000000Z' })),
        (New-NvBoardJob 2 'queued' ([ordered]@{ notBefore = '2026-10-15T19:00:00.0000000Z' })),
        (New-NvBoardJob 3 'queued' ([ordered]@{ deferUntil = '2026-10-15T20:00:00.0000000Z'; deferWhy = 'background'; deferSince = '2026-10-09T09:00:00.0000000Z' })),
        (New-NvBoardJob 4 'queued' ([ordered]@{ deferUntil = '2026-10-15T20:00:00.0000000Z'; deferWhy = 'background'; deferSince = '2026-10-09T09:01:00.0000000Z' })),
        (New-NvBoardJob 5 'queued')
    )
    New-NvBoardCase 'sends: days apart, India' (New-NvBoardInput $days)
    New-NvBoardCase 'sends: days apart, Lima' (New-NvBoardInput $days) 'en-US' $lima -300
    New-NvBoardCase 'sends: ties, one after another, and nothing running' (New-NvBoardInput @(
            (New-NvBoardJob 1 'queued'),
            (New-NvBoardJob 2 'queued'),
            (New-NvBoardJob 3 'queued'),
            (New-NvBoardJob 4 'queued' ([ordered]@{ provider = 'codex' })),
            (New-NvBoardJob 5 'queued' ([ordered]@{ provider = 'codex' })),
            (New-NvBoardJob 6 'queued' ([ordered]@{ provider = 'codex'; notBefore = '2026-10-15T11:01:00.0000000Z' })),
            (New-NvBoardJob 7 'queued' ([ordered]@{ retryAt = '2026-10-15T10:00:00.0000000Z' }))
        ) $null ([ordered]@{ blocked = [ordered]@{ claude = [ordered]@{ until = '2026-10-15T11:00:00.0000000Z'; type = 'five-hour'; source = 'probe' } } }))
    New-NvBoardCase 'permit: the phone asked, or not' (New-NvBoardInput @(
            (New-NvBoardJob 1 'running' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Bash'; until = '2026-10-15T09:30:00.0000000Z' } })),
            (New-NvBoardJob 2 'running' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Edit'; until = '2026-10-15T08:59:00.0000000Z' } })),
            (New-NvBoardJob 3 'running' ([ordered]@{ permitWaiting = [ordered]@{ until = '2026-10-15T09:30:00.0000000Z' } })),
            (New-NvBoardJob 4 'running' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Write'; until = '2026-10-15T09:00:00.0000000Z' } })),
            (New-NvBoardJob 5 'running' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Bash' } })),
            (New-NvBoardJob 6 'queued' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Bash'; until = '2026-10-15T09:30:00.0000000Z' } }))
        ))

    # --- recent and older ------------------------------------------------------------
    New-NvBoardCase 'recent: done and skipped within two days' (New-NvBoardInput @(
            (New-NvBoardJob 1 'done' ([ordered]@{ endedAt = '2026-10-15T08:00:00.0000000Z' })),
            (New-NvBoardJob 2 'done' ([ordered]@{ endedAt = '2026-10-13T10:00:00.0000000Z' })),
            (New-NvBoardJob 3 'done' ([ordered]@{ endedAt = '2026-10-13T09:00:00.0000000Z' })),
            (New-NvBoardJob 4 'done' ([ordered]@{ endedAt = '2026-10-13T09:00:01.0000000Z' })),
            (New-NvBoardJob 5 'skipped' ([ordered]@{ endedAt = '2026-10-14T09:00:00.0000000Z' })),
            (New-NvBoardJob 6 'done'),
            (New-NvBoardJob 7 'done' ([ordered]@{ endedAt = 'not a date' })),
            (New-NvBoardJob 8 'failed' ([ordered]@{ endedAt = '2026-10-01T09:00:00.0000000Z' })),
            (New-NvBoardJob 9 'skipped' ([ordered]@{ endedAt = '2026-10-15T10:00:00.0000000Z' }))
        ))

    # --- stamps with no zone, west of UTC ------------------------------------------
    New-NvBoardCase 'zoneless stamps, Lima' (New-NvBoardInput @(
            (New-NvBoardJob 1 'queued'),
            (New-NvBoardJob 2 'done' ([ordered]@{ endedAt = '2026-10-13T06:00:00' })),
            (New-NvBoardJob 3 'running' ([ordered]@{ permitWaiting = [ordered]@{ tool = 'Bash'; until = '2026-10-15T06:00:00' } }))
        ) $null ([ordered]@{ blocked = [ordered]@{ claude = [ordered]@{ until = '2026-10-15T06:00:00'; type = 'five-hour'; source = 'probe' } } })) 'en-US' $lima -300
} -Expect {
    param($In, $Name)
    $null = Enter-NvData $Name
    Use-NvCulture ([string]$In.culture) {
        Use-NvTimeZone ([string]$In.zone) {
            Use-NvClock ([string]$In.now) {
                $bdOff = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
                if ($bdOff -ne [int]$In.utcOffsetMinutes) { throw "$($In.zone) is $bdOff minutes from UTC, not $($In.utcOffsetMinutes)" }
                $null = New-Item -ItemType Directory -Path $script:ChatqQueueDir -Force
                foreach ($bdE in (Get-NvBoardList $In 'jobs')) {
                    Write-NvBoardText (Join-Path $script:ChatqQueueDir "j$([int]$bdE.n).json") (ConvertTo-NvJson (Get-NvBoardJobFile $bdE))
                }
                if ($In.PSObject.Properties['prompts']) {
                    foreach ($bdP in $In.prompts.PSObject.Properties) {
                        # the runner joins the lines with its own newline: a
                        # CRLF of the prompt's own would read as a line end
                        if (([string]$bdP.Value).Contains("`r`n")) { throw "$($bdP.Name) holds a CRLF" }
                        Write-NvBoardText (Join-Path $script:ChatqQueueDir $bdP.Name) ([string]$bdP.Value)
                    }
                }
                $bdRuns = New-Object System.Collections.Generic.List[object]
                foreach ($bdF in (Get-NvBoardList $In 'fills')) {
                    $bdRun = ([string]$bdF.unit) * [int]$bdF.times
                    Write-NvBoardText (Join-Path $script:ChatqQueueDir ([string]$bdF.file)) $bdRun
                    $bdRuns.Add(@($bdRun, "<<$([string]$bdF.unit)*$([int]$bdF.times)>>"))
                }
                if ($In.PSObject.Properties['state']) { Write-NvBoardText $script:ChatqStatePath (ConvertTo-NvJson $In.state) }
                # the lock held, as chatqd holds it: Test-ChatqWatcherAlive is true
                $bdLock = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
                try { $null = Write-ChatqBoard }
                finally { $bdLock.Dispose() }
                $bdLines = $null
                if ([System.IO.File]::Exists($script:ChatqBoardPath)) {
                    $bdText = [System.IO.File]::ReadAllText($script:ChatqBoardPath, (New-Object System.Text.UTF8Encoding $false))
                    foreach ($bdR in $bdRuns) { $bdText = $bdText.Replace([string]$bdR[0], [string]$bdR[1]) }
                    $bdLines = $bdText.Split([string[]]@([Environment]::NewLine), [System.StringSplitOptions]::None)
                }
                return [ordered]@{ culture = (Get-NvBoardCulture); lines = $bdLines }
            }
        }
    }
}
