# tests/vectors/log.ps1: native/vectors/log.json - the lines the logs get.
# Add-ChatqLogLine (src/queue.ps1): (Get-Date).ToString('o') - local time
# and its offset - two spaces, the text and a line feed onto
# data/logs/<name>, UTF-8 without a BOM, the file first moved to <name>.1
# (over any there) when it is past 1 MB. Write-ChatqReplyLog (src/phone.ps1):
# the text, each run of CR and LF one space, as 'phone: <text>' in
# watcher.log and as itself in replies.log. Send-ChatqAlert
# (src/alerts.ps1): '<o><tab><event><tab><text>' onto alerts.log before any
# channel, each run of \s in the text one space and the event as it came.
# Rust: native/crates/chatq-core/tests/log_vectors.rs.
#
# A log case runs its steps in a data/ of its own, the clock at each step's
# time, and answers every file in logs/ with its text. Send-ChatqAlert runs
# whole: with no config the toast is its only channel, and tests/vectors.ps1
# sets the toast's seam and the idle seam, so after its line it returns
# $false having reached nothing else. A roll case lays its files down from a
# recipe - n bytes, byte i a line feed where i % 100 is 99 and 'x'
# elsewhere - adds one line, and answers each file's name and size and the
# last line of the one written to.

function New-NvLogCase([string]$Name, $Steps, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540) {
    $in = [ordered]@{ kind = 'log'; zone = $Zone; utcOffsetMinutes = $Offset; steps = @($Steps) }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvLogLine([string]$At, [string]$Log, $Text) {
    return [ordered]@{ at = $At; act = 'line'; log = $Log; text = $Text }
}

function New-NvLogReply([string]$At, $Text) {
    return [ordered]@{ at = $At; act = 'reply'; text = $Text }
}

function New-NvLogAlert([string]$At, $Ev, $Text, [string]$Title) {
    # $Title: the alert is about a job of that title (Send-ChatqAlert -Job)
    $s = [ordered]@{ at = $At; act = 'alert'; event = $Ev; text = $Text }
    if ($Title) { $s['title'] = $Title }
    return $s
}

function New-NvLogRoll([string]$Name, $Files, [string]$Log = 'watcher.log') {
    $in = [ordered]@{
        kind = 'roll'; zone = 'Korea Standard Time'; utcOffsetMinutes = 540; now = '2026-10-15T01:00:00Z'
        files = @($Files); log = $Log; text = 'after the roll'
    }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvLogFile([string]$Name, [int]$Bytes) { return [ordered]@{ name = $Name; bytes = $Bytes } }

function Write-NvLogRecipe([string]$Path, [int]$Bytes) {
    # $Bytes bytes: a line feed where i % 100 is 99, 'x' elsewhere
    $block = ('x' * 99) + "`n"
    $text = ($block * [int][Math]::Ceiling($Bytes / 100)).Substring(0, $Bytes)
    [IO.File]::WriteAllText($Path, $text, $script:NvUtf8)
}

function Get-NvLogNames([string]$Dir) {
    # the files in logs/, in ordinal order
    if (-not (Test-Path -LiteralPath $Dir)) { return , [string[]]@() }
    $names = [string[]]@(Get-ChildItem -LiteralPath $Dir -File | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return , $names
}

function Get-NvLogText([string]$Path) {
    # the bytes as UTF-8, a BOM kept as U+FEFF
    return $script:NvUtf8.GetString([IO.File]::ReadAllBytes($Path))
}

Register-NvVector -Name 'log' -About 'The lines the logs get. Add-ChatqLogLine (src/queue.ps1): local (Get-Date).ToString(''o''), two spaces, the text and LF onto data/logs/<name> as UTF-8 without a BOM, the file first moved over <name>.1 when past 1 MB (1048576 bytes). Write-ChatqReplyLog (src/phone.ps1): each run of CR and LF one space, as ''phone: <text>'' in watcher.log and as itself in replies.log. Send-ChatqAlert (src/alerts.ps1): <o> TAB <event> TAB <text> LF onto alerts.log before any channel, each run of \s in the text one space, the event as it came. A log case runs its steps and answers every file in logs/ with its text; a roll case lays files down from a recipe (n bytes, byte i LF where i % 100 is 99, else x), adds one line, and answers each file''s size and the last line of the one written to. Rust: log::add_log_line_in, write_reply_log, add_alert_line' -Cases {
    $at = '2026-10-15T01:00:00Z'
    $uni = 'caf' + [char]0x00E9 + ' ' + [char]0x4E2D + [char]0x6587 + ' ' + [char]::ConvertFromUtf32(0x1F600) + ' ' + [char]0x00B7
    $dot = [string][char]0x00B7

    New-NvLogCase 'line-first' @((New-NvLogLine $at 'watcher.log' 'watcher 4242 started (9.8.7)'))
    New-NvLogCase 'line-ticks' @(
        (New-NvLogLine '2026-10-15T01:00:00.1234567Z' 'jobs.log' 'a'),
        (New-NvLogLine '2026-10-15T01:00:00.5Z' 'jobs.log' 'b'),
        (New-NvLogLine '2026-10-15T01:00:00.0000001Z' 'jobs.log' 'c'),
        (New-NvLogLine '2026-10-15T01:00:59.9999999Z' 'jobs.log' 'd'))
    New-NvLogCase 'line-negative-zone' @((New-NvLogLine $at 'watcher.log' 'west')) -Zone 'SA Pacific Standard Time' -Offset -300
    New-NvLogCase 'line-half-hour-zone' @((New-NvLogLine $at 'watcher.log' 'half')) -Zone 'India Standard Time' -Offset 330
    # offset 0 by a zone that is not 'UTC' (tests/vectors/state.ps1 says why)
    New-NvLogCase 'line-zero-offset' @((New-NvLogLine $at 'watcher.log' 'zero')) -Zone 'Greenwich Standard Time' -Offset 0
    New-NvLogCase 'line-new-year' @(
        (New-NvLogLine '2026-12-31T14:59:59.9999999Z' 'watcher.log' 'last tick of the year'),
        (New-NvLogLine '2026-12-31T15:00:00Z' 'watcher.log' 'midnight'))
    # the text as it came: no line of its own per line break
    New-NvLogCase 'line-texts' @(
        (New-NvLogLine $at 'watcher.log' ''),
        (New-NvLogLine $at 'watcher.log' $null),
        (New-NvLogLine $at 'watcher.log' "two`r`nlines and a`ttab"),
        (New-NvLogLine $at 'watcher.log' $uni),
        (New-NvLogLine $at 'watcher.log' '  spaced  '),
        (New-NvLogLine $at 'watcher.log' "ends in a line feed`n"))
    New-NvLogCase 'line-two-logs' @(
        (New-NvLogLine '2026-10-15T01:00:00Z' 'watcher.log' 'one'),
        (New-NvLogLine '2026-10-15T01:00:01Z' 'jobs.log' 'two'),
        (New-NvLogLine '2026-10-15T01:00:02Z' 'watcher.log' 'three'))

    New-NvLogCase 'reply-plain' @((New-NvLogReply $at 'reply to j7: sent'))
    New-NvLogCase 'reply-line-breaks' @((New-NvLogReply $at "line one`r`nline two`n`nline three`rend"))
    New-NvLogCase 'reply-breaks-at-ends' @((New-NvLogReply $at "`r`n`r`nlead and trail`n"))
    # only CR and LF: other breaks and white space stay
    $other = "tab`there" + [char]0x2028 + 'ls' + [char]0x2029 + 'ps' + [char]0x0085 + 'nel' + [char]0x000B + 'vt' + [char]0x000C + 'ff  two'
    New-NvLogCase 'reply-other-breaks' @((New-NvLogReply $at $other))
    New-NvLogCase 'reply-unicode' @((New-NvLogReply $at $uni))
    New-NvLogCase 'reply-empty' @(
        (New-NvLogReply '2026-10-15T01:00:00Z' ''),
        (New-NvLogReply '2026-10-15T01:00:01Z' $null),
        (New-NvLogReply '2026-10-15T01:00:02Z' "`n"))
    New-NvLogCase 'reply-among-watcher-lines' @(
        (New-NvLogLine '2026-10-15T01:00:00Z' 'watcher.log' 'watcher 4242 started (9.8.7)'),
        (New-NvLogReply '2026-10-15T01:00:01Z' "reply: done`r`nnext"),
        (New-NvLogLine '2026-10-15T01:00:02Z' 'watcher.log' 'pass'))

    # every character \s takes, each between two w's; then ones it does not
    $white = @(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680) + @(0x2000..0x200A) + @(0x2028, 0x2029, 0x202F, 0x205F, 0x3000)
    $allWhite = 'w' + (-join @(foreach ($c in $white) { [string][char]$c + 'w' }))
    $notWhite = 'n' + (-join @(foreach ($c in @(0x00, 0x1C, 0x1D, 0x1E, 0x1F, 0x7F, 0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF)) { [string][char]$c + 'n' }))
    New-NvLogCase 'alert-plain' @((New-NvLogAlert $at 'done' "Release notes $dot done $dot 4m"))
    New-NvLogCase 'alert-every-white-space' @((New-NvLogAlert $at 'test' $allWhite))
    New-NvLogCase 'alert-no-white-space' @((New-NvLogAlert $at 'test' $notWhite))
    New-NvLogCase 'alert-runs' @((New-NvLogAlert $at 'failed' ("a `t `r`n  b" + [char]0x00A0 + [char]0x3000 + "c`n`n`nd")))
    New-NvLogCase 'alert-ends' @((New-NvLogAlert $at 'limited' "`t lead and trail `r`n"))
    New-NvLogCase 'alert-event-as-it-came' @(
        (New-NvLogAlert '2026-10-15T01:00:00Z' 'needs input' 'x'),
        (New-NvLogAlert '2026-10-15T01:00:01Z' "odd`tevent  two" 'y'),
        (New-NvLogAlert '2026-10-15T01:00:02Z' "broken`r`nevent" 'z'),
        (New-NvLogAlert '2026-10-15T01:00:03Z' '' 'no event'),
        (New-NvLogAlert '2026-10-15T01:00:04Z' $null 'null event'))
    New-NvLogCase 'alert-empty-text' @(
        (New-NvLogAlert '2026-10-15T01:00:00Z' 'done' ''),
        (New-NvLogAlert '2026-10-15T01:00:01Z' 'done' $null),
        (New-NvLogAlert '2026-10-15T01:00:02Z' 'done' "`r`n"))
    # the job's title goes to the toast's title; alerts.log keeps the text
    New-NvLogCase 'alert-about-a-job' @((New-NvLogAlert $at 'done' "Release notes $dot 4m $dot 2 turns" 'Release notes'))
    New-NvLogCase 'alert-long' @((New-NvLogAlert $at 'reply' ('y' * 500)))
    New-NvLogCase 'alert-half-hour-zone' @(
        (New-NvLogAlert '2026-10-15T01:00:00.25Z' 'done' 'first'),
        (New-NvLogAlert '2026-10-15T18:29:59Z' 'failed' 'second')) -Zone 'India Standard Time' -Offset 330
    New-NvLogCase 'all-three' @(
        (New-NvLogLine '2026-10-15T01:00:00Z' 'watcher.log' 'pass'),
        (New-NvLogAlert '2026-10-15T01:00:01Z' 'reply' "an answer`r`nin two lines"),
        (New-NvLogReply '2026-10-15T01:00:02Z' "an answer`r`nin two lines")) -Zone 'SA Pacific Standard Time' -Offset -300

    New-NvLogRoll 'roll-at-1mb' @((New-NvLogFile 'watcher.log' 1048576))
    New-NvLogRoll 'roll-past-1mb' @((New-NvLogFile 'watcher.log' 1048577))
    New-NvLogRoll 'roll-well-past' @((New-NvLogFile 'watcher.log' 3000000))
    New-NvLogRoll 'roll-over-the-old' @((New-NvLogFile 'watcher.log' 1048600), (New-NvLogFile 'watcher.log.1' 4321))
    New-NvLogRoll 'roll-old-left-alone' @((New-NvLogFile 'watcher.log' 300), (New-NvLogFile 'watcher.log.1' 1048577))
    New-NvLogRoll 'roll-empty-file' @((New-NvLogFile 'watcher.log' 0))
    New-NvLogRoll 'roll-no-file' @()
    New-NvLogRoll 'roll-only-its-own' @((New-NvLogFile 'jobs.log' 1048577), (New-NvLogFile 'replies.log' 2000)) -Log 'replies.log'
} -Expect {
    param($In, $Name)
    $null = Enter-NvData $Name
    $logDir = $script:ChatqLogDir
    $logWas = @{
        Foreground = $script:ChatqForeground; Report = $script:ChatqAlertReport
        Aid = $script:ChatqLastAlertAid; Error = $script:ChatqLastAlertError
    }
    $script:ChatqForeground = $false
    try {
        if ([string]$In.kind -eq 'roll') {
            $logLaid = @($In.files)
            if ($logLaid.Count) { $null = New-Item -ItemType Directory -Path $logDir -Force }
            foreach ($logFile in $logLaid) { Write-NvLogRecipe (Join-Path $logDir ([string]$logFile.name)) ([int]$logFile.bytes) }
            $null = Use-NvCulture 'en-US' {
                Use-NvTimeZone ([string]$In.zone) {
                    Use-NvClock ([string]$In.now) { Add-ChatqLogLine ([string]$In.log) $In.text }
                }
            }
            $logFiles = @(foreach ($logName in (Get-NvLogNames $logDir)) { [ordered]@{ name = $logName; size = (Get-Item -LiteralPath (Join-Path $logDir $logName)).Length } })
            $logText = Get-NvLogText (Join-Path $logDir ([string]$In.log))
            $logCut = if ($logText.EndsWith("`n", [StringComparison]::Ordinal)) { $logText.Substring(0, $logText.Length - 1) } else { $logText }
            return [ordered]@{ files = $logFiles; tail = $logText.Substring($logCut.LastIndexOf([char]10) + 1) }
        }
        $logSteps = @($In.steps)
        $null = Use-NvCulture 'en-US' {
            Use-NvTimeZone ([string]$In.zone) {
                Use-NvClock ([string]$logSteps[0].at) {
                    foreach ($logStep in $logSteps) {
                        Set-NvClock ([string]$logStep.at)
                        if ([string]$logStep.act -eq 'line') { Add-ChatqLogLine ([string]$logStep.log) $logStep.text }
                        elseif ([string]$logStep.act -eq 'reply') { Write-ChatqReplyLog $logStep.text }
                        elseif ([string]$logStep.act -eq 'alert') {
                            $logJob = if (Get-NvHas $logStep 'title') { [pscustomobject]@{ title = [string]$logStep.title } } else { $null }
                            $null = Send-ChatqAlert $logStep.event $logStep.text -Job $logJob
                        }
                        else { throw "a step that does '$($logStep.act)'" }
                    }
                }
            }
        }
        $logFiles = @(foreach ($logName in (Get-NvLogNames $logDir)) { [ordered]@{ name = $logName; text = (Get-NvLogText (Join-Path $logDir $logName)) } })
        return [ordered]@{ files = $logFiles }
    }
    finally {
        $script:ChatqForeground = $logWas.Foreground
        $script:ChatqAlertReport = $logWas.Report
        $script:ChatqLastAlertAid = $logWas.Aid
        $script:ChatqLastAlertError = $logWas.Error
    }
}
