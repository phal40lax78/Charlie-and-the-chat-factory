# tests/vectors/timers.ps1: native/vectors/timers.json (native/SPEC.md 6.1).
# Which of the watcher loop's timers fire on which pass. The real
# Invoke-ChatqWatchLoop (src/watcher.ps1) runs, with every action it takes
# stubbed by a recorder: the answer is the list of recorders that fired, pass
# by pass, in the order the loop called them.
#
# The clock is scripted. Test-ChatqHeldWaiting is the loop's first call of a
# pass, so its stub marks the pass: it moves the clock to that pass's time
# (Set-NvClock) and opens a new list for the pass. Waits do not wait - the
# stub only records how long the loop asked for - and the marker writes
# data/stop on the last scripted pass, so the loop leaves through its own
# stop path. A pass more than the script throws rather than spin.
#
# Pinned here: auto scan at the start then every 5 minutes, stray sweep at
# the start then every 6 hours, a lane's limits re-read at most every 10
# minutes, an answer from the phone checked 20 s on, the board and the state
# written at most every 30 s while listening (and whenever a poll did
# something), the default 15 minute wait, the wait capped at the poll
# interval while listening, keep-awake only for a wait of 6 hours or less,
# and the two ways the loop ends (SPEC 2.10).
#
# The in-run tick (heartbeat every 60 s, in-run poll, ask -Quick) is a
# closure inside Invoke-ChatqJob and cannot be reached without driving a
# whole run, so it is not here: only its constants are pinned, in
# native/crates/chatq-core/src/timers.rs.

function New-NvTimersCase {
    # one case: the scripted pass times in seconds from the start, the rest
    # of its input after them
    param([string]$Name, [int[]]$Passes, [System.Collections.IDictionary]$More)
    $in = [ordered]@{ start = '2026-10-15T09:00:00.0000000Z'; utcOffsetMinutes = 0; pollSeconds = 20; passes = $Passes }
    if ($More) { foreach ($k in $More.Keys) { $in[$k] = $More[$k] } }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvTimersJob {
    # a queued job as data/queue holds it, oldest first by its number
    param([int]$Seq, [string]$Provider = 'claude', [string]$Dir = '', [string]$NotBefore = '')
    $j = [ordered]@{ id = "j$Seq"; seq = $Seq; state = 'queued'; kind = 'prompt'; title = "chat $Seq"; createdAt = "2026-10-15T08:0${Seq}:00.0000000Z"; provider = $Provider }
    if ($Dir) { $j['home'] = $Dir }
    if ($NotBefore) { $j['notBefore'] = $NotBefore }
    return $j
}

function Get-NvTimersStamp {
    # a pass time: the start plus so many seconds, as a UTC round-trip stamp
    # for Set-NvClock. Kind is set by hand: in the zone UTC, pwsh 7's
    # ToUniversalTime keeps Kind Local and 'o' would end +00:00 there
    param([string]$Start, [int]$Seconds)
    $t = [datetime]::Parse($Start, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    return [datetime]::SpecifyKind($t.ToUniversalTime(), [System.DateTimeKind]::Utc).AddSeconds($Seconds).ToString('o')
}

function Get-NvTimersWhen {
    # the same instant as local time, for a stub that hands the loop a time
    param([string]$Start, [int]$Seconds)
    return [datetime]::Parse((Get-NvTimersStamp $Start $Seconds), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}

function Get-NvTimersInts {
    # a case's list of pass numbers, empty when it has none
    param($In, [string]$Field)
    if (-not $In.PSObject.Properties[$Field]) { return @() }
    return @(foreach ($v in @($In.$Field)) { [int]$v })
}

function Get-NvTimersList {
    # a case's list, empty when it has none
    param($In, [string]$Field)
    if (-not $In.PSObject.Properties[$Field]) { return @() }
    return @($In.$Field)
}

Register-NvVector -Name 'timers' -About 'Invoke-ChatqWatchLoop (src/watcher.ps1) on a scripted clock: which of its timers fire on which pass. Every action the loop takes is stubbed by a recorder, so each pass answers with the recorders that fired in order - auto scan (5 min), stray sweep (6 h), a lane''s block rescan (10 min per lane), the ask-landed check (20 s), the board and state writes (at most every 30 s while listening), keep-awake, the run, and how long each wait asked for. The pass marker is the Test-ChatqHeldWaiting stub, which moves the clock and writes data/stop on the last scripted pass.' -Cases {
    $later = '2026-10-15T21:00:00.0000000Z'
    $hold = @(New-NvTimersJob 1 'claude' '' $later)

    New-NvTimersCase 'pass 1 runs the auto scan and the stray sweep' @(0, 120) ([ordered]@{ jobs = $hold })
    New-NvTimersCase 'the auto scan every 5 minutes' @(0, 240, 300, 301, 600) ([ordered]@{ jobs = $hold })
    New-NvTimersCase 'the stray sweep every 6 hours' @(0, 21599, 21600, 43200) ([ordered]@{ jobs = @(New-NvTimersJob 1 'claude' '' '2026-10-16T21:00:00.0000000Z') })
    New-NvTimersCase 'a sweep that took something says so' @(0) ([ordered]@{ jobs = $hold; strayFiles = @('one.png', 'two.png') })
    New-NvTimersCase 'a lane is re-read at most every 10 minutes' @(0, 300, 600, 900) ([ordered]@{
            jobs = @((New-NvTimersJob 1 'claude' '' $later), (New-NvTimersJob 2 'claude' 'work' $later), (New-NvTimersJob 3 'claude' '' $later))
        })
    New-NvTimersCase 'a codex lane is read on its own' @(0, 660) ([ordered]@{
            jobs = @((New-NvTimersJob 1 'codex' '' $later), (New-NvTimersJob 2 'claude' '' $later))
        })
    New-NvTimersCase 'the wait ends at the nearest due time' @(0) ([ordered]@{ jobs = @(New-NvTimersJob 1 'claude' '' '2026-10-15T09:05:00.0000000Z') })
    New-NvTimersCase 'a soon alert shortens the wait' @(0) ([ordered]@{ jobs = @(New-NvTimersJob 1 'claude' '' '2026-10-15T09:05:00.0000000Z'); soonSeconds = 200 })
    New-NvTimersCase 'the board at most every 30 s while listening' @(0, 20, 40, 75) ([ordered]@{ jobs = $hold; openPasses = @(1, 2, 3, 4) })
    New-NvTimersCase 'a poll that did something writes the board' @(0, 10, 20) ([ordered]@{ jobs = $hold; openPasses = @(1, 2, 3); polledPasses = @(2) })
    New-NvTimersCase 'a due time sooner than the poll interval' @(0) ([ordered]@{ jobs = @(New-NvTimersJob 1 'claude' '' '2026-10-15T09:00:10.0000000Z'); openPasses = @(1) })
    New-NvTimersCase 'nothing queued, only listening' @(0, 20, 40) ([ordered]@{ openPasses = @(1, 2, 3); polledPasses = @(2) })
    New-NvTimersCase 'the queue empties and the watcher stops' @(0) ([ordered]@{})
    New-NvTimersCase 'the held summary goes out every pass' @(0, 10) ([ordered]@{ jobs = $hold; held = $true })
    New-NvTimersCase 'an answer from the phone lands 20 s on' @(0, 10, 25, 30) ([ordered]@{
            jobs = $hold; asks = @([ordered]@{ rid = 'r1'; ageSeconds = 0; title = 'a chat' }, [ordered]@{ rid = 'r2'; ageSeconds = 15 })
        })
    New-NvTimersCase 'a job picked runs, and that pass does not wait' @(0, 5) ([ordered]@{
            jobs = @((New-NvTimersJob 1 'claude'), (New-NvTimersJob 2 'codex' '' $later))
        })
    New-NvTimersCase 'the window closing is logged once' @(0, 10, 20) ([ordered]@{ jobs = $hold; openPasses = @(1) })
} -Expect {
    param($In, $Name)
    $null = Enter-NvData $Name
    $tmSentWas = $script:ChatqAskSent
    $tmForeWas = $script:ChatqForeground
    $tmAlertWas = $script:ChatqAlertJob
    try {
        Use-NvCulture 'en-US' {
            Use-NvTimeZone 'UTC' {
                Use-NvClock ([string]$In.start) {
                    $tmOff = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
                    if ($tmOff -ne [int]$In.utcOffsetMinutes) { throw "the zone is $tmOff minutes from UTC, not $($In.utcOffsetMinutes)" }
                    $tm = @{
                        Pass        = 0
                        Zero        = (Get-Date)
                        Stamps      = @(foreach ($s in @($In.passes)) { Get-NvTimersStamp ([string]$In.start) ([int]$s) })
                        Held        = [bool]$In.held
                        Open        = (Get-NvTimersInts $In 'openPasses')
                        Polled      = (Get-NvTimersInts $In 'polledPasses')
                        PollSeconds = [int]$In.pollSeconds
                        Stray       = (Get-NvTimersList $In 'strayFiles')
                        SoonAt      = $(if ($In.PSObject.Properties['soonSeconds']) { Get-NvTimersWhen ([string]$In.start) ([int]$In.soonSeconds) } else { $null })
                        Recs        = (New-Object System.Collections.Generic.List[object])
                        Before      = (New-Object System.Collections.Generic.List[string])
                        After       = (New-Object System.Collections.Generic.List[string])
                    }
                    $tm.Cur = $tm.Before

                    # the pass marker: the loop calls this once a pass, before
                    # anything else of its own
                    function Test-ChatqHeldWaiting {
                        $tm.Pass++
                        if ($tm.Pass -gt $tm.Stamps.Count) { throw "the loop went round $($tm.Pass) times, $($tm.Stamps.Count) scripted" }
                        Set-NvClock ([string]$tm.Stamps[$tm.Pass - 1])
                        $tm.Cur = New-Object System.Collections.Generic.List[string]
                        $tm.Recs.Add([ordered]@{ at = [int][Math]::Round(((Get-Date) - $tm.Zero).TotalSeconds); fired = $tm.Cur })
                        # the last scripted pass is the last one: the loop sees
                        # data/stop at the top of the next
                        if ($tm.Pass -eq $tm.Stamps.Count) { Set-Content -LiteralPath $script:ChatqStopPath -Value 'stop' -Encoding ASCII }
                        return $tm.Held
                    }
                    # the loop's start, before the first pass
                    function Restore-ChatqWatchState { param($W) return $false }
                    function Repair-ChatqInterrupted { $tm.Cur.Add('repair') }
                    # what each pass may do
                    function Send-ChatqHeldSummary { $tm.Cur.Add('held summary'); return $true }
                    function Test-ChatqReplyOpen { param($Cfg) return ($tm.Open -contains $tm.Pass) }
                    function Get-ChatqReplyPollSeconds { param([switch]$InRun) return $tm.PollSeconds }
                    function Invoke-ChatqReplyPoll {
                        param([switch]$Force, [int]$TimeoutSec = 8, [int]$MinSeconds = 15, [int]$MaxMessages = 10, [switch]$Quick)
                        $tm.Cur.Add("poll $MinSeconds")
                        if ($tm.Polled -contains $tm.Pass) { return 1 }
                        return 0
                    }
                    # the ask-landed check runs for real; what it reads of the
                    # transcript does not
                    function Get-ChatqAskResult { param([string]$Path, [string]$ToolUseId) return [pscustomobject]@{ Found = $true; Answers = $null } }
                    function Write-ChatqReplyLog { param([string]$Text) $tm.Cur.Add("reply log: $Text") }
                    function Invoke-ChatqWatchAutoScan { param($W) $tm.Cur.Add('auto'); return 0 }
                    function Clear-ChatqStrayFiles { $tm.Cur.Add('stray'); return @($tm.Stray) }
                    function Get-ChatqClaudeBlock { param($Where) $tm.Cur.Add("block claude$(if ($Where) { "|$Where" })"); return $null }
                    function Get-ChatqCodexBlock { param($Where) $tm.Cur.Add("block codex$(if ($Where) { "|$Where" })"); return $null }
                    function Set-ChatqKeepAwake { param([bool]$On) $tm.Cur.Add("awake $(if ($On) { 'on' } else { 'off' })") }
                    function Save-ChatqWatchState { param($W) $tm.Cur.Add('state') }
                    function Write-ChatqBoard { $tm.Cur.Add('board') }
                    function Send-ChatqUsageSoon { param($W, $Queued) $tm.Cur.Add('soon'); return $tm.SoonAt }
                    function Confirm-ChatqAllowed { param($W, $Job) return $true }
                    function Invoke-ChatqJob {
                        param($W, $Job)
                        $tm.Cur.Add("run #$($Job.seq)")
                        $null = Set-ChatqProp $Job 'state' 'done'
                        $null = Save-ChatqJob $Job -Existing
                    }
                    function Wait-ChatqUntil { param([datetime]$When) $tm.Cur.Add("wait $([int][Math]::Round(($When - (Get-Date)).TotalSeconds))") }
                    function Start-ChatqWatcherProcess { $tm.Cur.Add('respawn'); return $true }
                    function Write-ChatqWatchLog {
                        param([string]$Text)
                        # this watcher's own pid and version are not a vector's
                        if ($Text -match '^watcher \d+ (started|stopped)') { return }
                        # the stop is the way out: what follows it is the exit
                        if ($Text -eq 'stop requested') { $tm.Cur = $tm.After }
                        $tm.Cur.Add("log: $Text")
                        if ($Text -eq 'queue empty') { $tm.Cur = $tm.After }
                    }

                    $script:ChatqAskSent = @{}
                    foreach ($a in @(Get-NvTimersList $In 'asks')) {
                        $tmRid = [string]$a.rid
                        $script:ChatqAskSent[$tmRid] = @{
                            Rid = $tmRid; At = (Get-Date).AddSeconds(-[int]$a.ageSeconds); ToolUseId = 'tu1'
                            Answers = @{}; Transcript = 'chat.jsonl'; SessionId = 's1'
                            Title = $(if ($a.PSObject.Properties['title']) { [string]$a.title } else { $null })
                        }
                    }
                    $null = New-Item -ItemType Directory -Path $script:ChatqQueueDir -Force
                    foreach ($tmJob in @(Get-NvTimersList $In 'jobs')) {
                        [System.IO.File]::WriteAllText((Join-Path $script:ChatqQueueDir "$($tmJob.id).json"), (ConvertTo-NvJson $tmJob), (New-Object System.Text.UTF8Encoding $false))
                    }
                    Invoke-ChatqWatchLoop
                    return [ordered]@{
                        before = @($tm.Before.ToArray())
                        passes = @(foreach ($r in $tm.Recs) { [ordered]@{ at = $r.at; fired = @($r.fired.ToArray()) } })
                        after  = @($tm.After.ToArray())
                    }
                }
            }
        }
    }
    finally {
        $script:ChatqAskSent = $tmSentWas
        $script:ChatqForeground = $tmForeWas
        $script:ChatqAlertJob = $tmAlertWas
    }
}
