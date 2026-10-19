# tests/vectors/due.ps1: native/vectors/due.json (native/SPEC.md 6.1).
# When the watcher may next pick a job - Get-ChatqDueTime, its lane's limit
# and overload check and the job's own times - and Update-ChatqBlock's skip
# rule: a lane is rescanned at most every 10 minutes, unless forced. The scan
# itself is stubbed: only whether it ran is pinned.
#
# A job is read back from data/queue through Get-ChatqJobs, as the watcher
# reads it, so each PowerShell's own JSON reader makes its dates: a stamp
# with no zone is UTC to 5.1 and the zone's wall clock to pwsh 7. Zones with
# no DST, and their offsets in utcOffsetMinutes, so the Rust runner needs no
# zone database.

function New-NvDueCase {
    # one case: $Fn 'due' or 'rescan', the rest of its input after the clock
    param([string]$Name, [string]$Fn, [string]$Zone, [int]$Off, [System.Collections.IDictionary]$More)
    $in = [ordered]@{ fn = $Fn; zone = $Zone; utcOffsetMinutes = $Off; now = '2026-10-15T09:00:00.0000000Z' }
    foreach ($k in $More.Keys) { $in[$k] = $More[$k] }
    return [ordered]@{ name = $Name; input = $in }
}

function Get-NvDueStamp {
    # a time as the answer gives it: UTC round-trip, or $null. Kind is set
    # by hand: in the zone UTC, pwsh 7's ToUniversalTime keeps Kind Local -
    # FindSystemTimeZoneById('UTC') is TimeZoneInfo.Utc itself - and 'o'
    # would end +00:00 there, Z everywhere else
    param($When)
    if ($null -eq $When) { return $null }
    return [datetime]::SpecifyKind($When.ToUniversalTime(), [System.DateTimeKind]::Utc).ToString('o')
}

Register-NvVector -Name 'due' -About 'Get-ChatqDueTime (src/watcher.ps1): the latest of the lane''s limit plus 60 s, its next overload check, notBefore, deferUntil and retryAt that is still ahead, or null for now; and Update-ChatqBlock''s skip rule: a lane rescanned at most every 10 minutes unless forced. Lanes are case-blind hashtable keys. A job is read from data/queue, so a zoneless stamp is UTC to 5.1 and the zone''s wall clock to pwsh 7.' -Cases {
    $u = 'UTC'
    $claude = [ordered]@{ id = 'j1'; provider = 'claude' }
    New-NvDueCase 'nothing to wait for' 'due' $u 0 ([ordered]@{ job = $claude })
    New-NvDueCase 'a limit ahead: a minute past its reset' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T11:00:00.0000000Z' } })
    New-NvDueCase 'a limit a second ahead' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T09:00:01.0000000Z' } })
    New-NvDueCase 'a limit ending now' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T09:00:00.0000000Z' } })
    New-NvDueCase 'a limit just over' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T08:59:59.0000000Z' } })
    New-NvDueCase 'another lane''s limit' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'codex'; until = '2026-10-15T11:00:00.0000000Z' } })
    New-NvDueCase 'a lane key in other letters' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'Claude'; until = '2026-10-15T11:00:00.0000000Z' } })
    New-NvDueCase 'a home is a lane of its own' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; home = 'work' }; blocked = [ordered]@{ lane = 'claude|work'; until = '2026-10-15T11:00:00.0000000Z' } })
    New-NvDueCase 'no home is not that lane' 'due' $u 0 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude|work'; until = '2026-10-15T11:00:00.0000000Z' } })
    New-NvDueCase 'a codex job on its own lane' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'codex' }; blocked = [ordered]@{ lane = 'codex'; until = '2026-10-15T10:30:00.0000000Z' } })
    New-NvDueCase 'an overload check ahead' 'due' $u 0 ([ordered]@{ job = $claude; outage = [ordered]@{ lane = 'claude'; next = '2026-10-15T09:05:00.0000000Z' } })
    New-NvDueCase 'an overload check due now' 'due' $u 0 ([ordered]@{ job = $claude; outage = [ordered]@{ lane = 'claude'; next = '2026-10-15T09:00:00.0000000Z' } })
    New-NvDueCase 'notBefore ahead' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T12:00:00.0000000Z' } })
    New-NvDueCase 'notBefore passed' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T08:00:00.0000000Z' } })
    New-NvDueCase 'notBefore a tick ahead' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T09:00:00.0000001Z' } })
    New-NvDueCase 'deferUntil ahead, with an offset' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; deferUntil = '2026-10-15T20:30:00.0000000+09:00' } })
    New-NvDueCase 'retryAt ahead' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; retryAt = '2026-10-15T09:10:00.0000000Z' } })
    New-NvDueCase 'the latest of them all' 'due' $u 0 ([ordered]@{
            job     = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T11:00:00.0000000Z'; deferUntil = '2026-10-15T09:10:00.0000000Z'; retryAt = '2026-10-15T10:30:00.0000000Z' }
            blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T10:00:00.0000000Z' }; outage = [ordered]@{ lane = 'claude'; next = '2026-10-15T09:30:00.0000000Z' }
        })
    New-NvDueCase 'a limit beats a notBefore at its reset' 'due' $u 0 ([ordered]@{
            job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T10:00:00.0000000Z' }; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T10:00:00.0000000Z' }
        })
    New-NvDueCase 'only what is still ahead counts' 'due' $u 0 ([ordered]@{
            job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T08:00:00.0000000Z'; retryAt = '2026-10-15T09:20:00.0000000Z' }; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T08:30:00.0000000Z' }
        })
    New-NvDueCase 'notBefore no time at all' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = 'tomorrow' } })
    New-NvDueCase 'notBefore empty' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '' } })
    New-NvDueCase 'a zoneless notBefore in UTC' 'due' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T10:00:00' } })
    New-NvDueCase 'a zoneless notBefore east of UTC' 'due' 'India Standard Time' 330 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T10:00:00' } })
    New-NvDueCase 'a zoneless notBefore west of UTC' 'due' 'SA Pacific Standard Time' -300 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T08:00:00' } })
    New-NvDueCase 'stamps with a zone, east of UTC' 'due' 'India Standard Time' 330 ([ordered]@{
            job = [ordered]@{ id = 'j1'; provider = 'claude'; notBefore = '2026-10-15T12:00:00.0000000Z'; retryAt = '2026-10-15T16:00:00.0000000+05:30' }; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T10:00:00.0000000Z' }
        })
    New-NvDueCase 'a limit west of UTC' 'due' 'SA Pacific Standard Time' -300 ([ordered]@{ job = $claude; blocked = [ordered]@{ lane = 'claude'; until = '2026-10-15T09:30:00.0000000Z' } })

    New-NvDueCase 'rescan: never scanned' 'rescan' $u 0 ([ordered]@{ job = $claude; force = $false })
    New-NvDueCase 'rescan: scanned 9:59 ago' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:50:01.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: scanned 10 minutes ago' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:50:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: scanned a tick under 10 minutes ago' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:50:00.0000001Z' }; force = $false })
    New-NvDueCase 'rescan: scanned an hour ago' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:00:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: forced a minute after a scan' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:59:00.0000000Z' }; force = $true })
    New-NvDueCase 'rescan: scanned ahead of the clock' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T09:05:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: a lane key in other letters' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'CLAUDE'; at = '2026-10-15T08:59:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: another lane scanned' 'rescan' $u 0 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'codex'; at = '2026-10-15T08:59:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: a home is a lane of its own' 'rescan' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; home = 'work' }; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:59:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: a home lane scanned' 'rescan' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'claude'; home = 'work' }; scanned = [ordered]@{ lane = 'claude|work'; at = '2026-10-15T08:59:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: a codex lane scanned' 'rescan' $u 0 ([ordered]@{ job = [ordered]@{ id = 'j1'; provider = 'codex' }; scanned = [ordered]@{ lane = 'codex'; at = '2026-10-15T08:55:00.0000000Z' }; force = $false })
    New-NvDueCase 'rescan: scanned 9:59 ago, east of UTC' 'rescan' 'India Standard Time' 330 ([ordered]@{ job = $claude; scanned = [ordered]@{ lane = 'claude'; at = '2026-10-15T08:50:01.0000000Z' }; force = $false })
} -Expect {
    param($In, $Name)
    $dueDir = Enter-NvData $Name
    Use-NvTimeZone ([string]$In.zone) {
        Use-NvClock ([string]$In.now) {
            $dueOff = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
            if ($dueOff -ne [int]$In.utcOffsetMinutes) { throw "$($In.zone) is $dueOff minutes from UTC, not $($In.utcOffsetMinutes)" }
            $dueW = New-ChatqWatchState
            if ($In.fn -eq 'due') {
                if ($In.PSObject.Properties['blocked']) {
                    $dueW.blocked[[string]$In.blocked.lane] = [pscustomobject]@{ Until = (ConvertTo-ChatqDate $In.blocked.until); Type = 'limit'; Source = 'vector' }
                }
                if ($In.PSObject.Properties['outage']) {
                    $dueW.outage[[string]$In.outage.lane] = @{ Since = (Get-Date).AddMinutes(-10); Attempts = 1; Status = $null; Alerted = $true; LastProbe = (Get-Date).AddMinutes(-1); NextCheck = (ConvertTo-ChatqDate $In.outage.next) }
                }
                # the job as the watcher reads it, from its file
                $null = New-Item -ItemType Directory -Path $script:ChatqQueueDir -Force
                [System.IO.File]::WriteAllText((Join-Path $script:ChatqQueueDir "$($In.job.id).json"), (ConvertTo-NvJson $In.job), (New-Object System.Text.UTF8Encoding $false))
                $dueJobs = @(Get-ChatqJobs)
                if ($dueJobs.Count -ne 1) { throw "data/queue gave $($dueJobs.Count) jobs, not 1" }
                $dueAt = Get-ChatqDueTime $dueW $dueJobs[0] (Get-Date)
                return [ordered]@{ due = (Get-NvDueStamp $dueAt) }
            }
            # rescan: the scan stubbed, so only whether it ran is seen
            $dueScan = @{ Ran = $false }
            function Get-ChatqClaudeBlock { $dueScan.Ran = $true; return $null }
            function Get-ChatqCodexBlock { $dueScan.Ran = $true; return $null }
            if ($In.PSObject.Properties['scanned']) { $dueW.scannedAt[[string]$In.scanned.lane] = ConvertTo-ChatqDate $In.scanned.at }
            $dueJob = [pscustomobject]@{ id = [string]$In.job.id; provider = [string]$In.job.provider; home = $(if ($In.job.PSObject.Properties['home']) { [string]$In.job.home } else { $null }) }
            Update-ChatqBlock $dueW $dueJob -Force:([bool]$In.force)
            return [ordered]@{ scanned = $dueScan.Ran; scannedAt = (Get-NvDueStamp $dueW.scannedAt[(Get-ChatqLane $dueJob)]) }
        }
    }
}
