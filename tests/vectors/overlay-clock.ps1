# tests/vectors/overlay-clock.ps1: native/vectors/overlay-clock.json, the
# words the panel and its tray put on a usage window's reset, from the
# snapshot's epoch ms (native/SPEC.md "M9: the overlay's snapshot"). A Rust
# panel draws them from overlay.json alone, so it must say them as the
# PowerShell host does. Four kinds of case, each at an instant (input.now)
# in a zone:
#
# - reset: Format-ChatOverlayReset of input.resetsAt - the countdown inside
#   a day, the weekday after, 'reset' once it is past.
# - resetAt: Format-ChatOverlayResetAt of input.resetsAt - the clock time
#   still ahead, with the weekday once it is not today; '' else.
# - window: Get-ChatOverlayResetWindow of input.windows - the label whose
#   reset a usage line shows, or null.
# - tooltip: Format-ChatOverlayTooltip of input.snap - the tray icon's
#   tooltip, cut to 127 characters.

function Get-NvOverlayClockNow([string]$At) {
    # the instant as this zone's local time, which the functions take as -Now
    return [datetime]::Parse($At, $script:NvInv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}

function Get-NvOverlayClockMs([string]$At) {
    return [DateTimeOffset]::Parse($At, $script:NvInv).ToUnixTimeMilliseconds()
}

function New-NvOverlayClockCase([string]$Kind, [string]$Label, [string]$Now, [string]$Zone, $Input2) {
    $in = [ordered]@{ kind = $Kind; now = $Now; zone = $Zone }
    foreach ($k in $Input2.Keys) { $in[$k] = $Input2[$k] }
    return [ordered]@{ name = "$Kind $Label"; input = $in }
}

function New-NvOverlayClockSnap($Counts, $Windows, $Extra) {
    # a snapshot as the tooltip reads it: counts, the header's usage, reload
    # and ask
    $h = [ordered]@{ usage = @([ordered]@{ provider = 'Claude'; windows = @($Windows) }); reload = @() }
    if ($Extra) { foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] } }
    return [ordered]@{ counts = $Counts; header = $h }
}

Register-NvVector -Name 'overlay-clock' -About "The panel's words for a usage reset at an instant in a zone: Format-ChatOverlayReset and Format-ChatOverlayResetAt of an epoch ms, Get-ChatOverlayResetWindow of a usage's windows (a label or null), and Format-ChatOverlayTooltip of a snapshot" -Cases {
    $kst = 'Korea Standard Time'
    $now = '2026-10-15T03:00:00.0000000Z'
    $nowMs = Get-NvOverlayClockMs $now
    # --- the countdown --------------------------------------------------------
    foreach ($p in @(
            @('none', $null), @('zero', 0), @('past', ($nowMs - 1000)), @('now', $nowMs),
            @('in 1 ms', ($nowMs + 1)), @('in 59.4 s', ($nowMs + 59400)), @('in 60 s', ($nowMs + 60000)),
            @('in 59 m 59 s', ($nowMs + 3599000)), @('in 1 h', ($nowMs + 3600000)), @('in 4 h 7 m', ($nowMs + 14820000)),
            @('in 23 h 59 m', ($nowMs + 86340000)), @('in exactly a day', ($nowMs + 86400000)), @('in 3 days', ($nowMs + 259200000)))) {
        New-NvOverlayClockCase 'reset' $p[0] $now $kst ([ordered]@{ resetsAt = $p[1] })
    }
    New-NvOverlayClockCase 'reset' 'a day off in Pacific' '2026-10-15T03:00:00.0000000Z' 'Pacific Standard Time' ([ordered]@{ resetsAt = ($nowMs + 90000000) })
    # --- the clock time -------------------------------------------------------
    foreach ($p in @(
            @('none', $null), @('past', ($nowMs - 1)), @('later today', ($nowMs + 7200000)),
            @('after midnight in the zone', ($nowMs + 54000000)), @('next week', ($nowMs + 604800000)))) {
        New-NvOverlayClockCase 'resetAt' $p[0] $now $kst ([ordered]@{ resetsAt = $p[1] })
    }
    New-NvOverlayClockCase 'resetAt' 'India, later today' $now 'India Standard Time' ([ordered]@{ resetsAt = ($nowMs + 7200000) })
    New-NvOverlayClockCase 'resetAt' 'Pacific, across the DST end' '2026-11-01T07:00:00.0000000Z' 'Pacific Standard Time' ([ordered]@{ resetsAt = (Get-NvOverlayClockMs '2026-11-01T10:30:00Z') })
    # --- which window ---------------------------------------------------------
    $w5 = [ordered]@{ label = '5h'; percent = 40; limited = $false; resetsAt = ($nowMs + 3600000) }
    $wk = [ordered]@{ label = 'week'; percent = 100; limited = $true; resetsAt = ($nowMs + 172800000) }
    $w5l = [ordered]@{ label = '5h'; percent = 100; limited = $true; resetsAt = ($nowMs + 3600000) }
    $w5p = [ordered]@{ label = '5h'; percent = 10; limited = $false; resetsAt = ($nowMs - 1) }
    New-NvOverlayClockCase 'window' '5h ahead' $now $kst ([ordered]@{ windows = @($w5) })
    New-NvOverlayClockCase 'window' 'week limited beats 5h' $now $kst ([ordered]@{ windows = @($w5, $wk) })
    New-NvOverlayClockCase 'window' 'the later of two limited' $now $kst ([ordered]@{ windows = @($w5l, $wk) })
    New-NvOverlayClockCase 'window' '5h past' $now $kst ([ordered]@{ windows = @($w5p) })
    New-NvOverlayClockCase 'window' 'none' $now $kst ([ordered]@{ windows = @() })
    # --- the tooltip ----------------------------------------------------------
    $zero = [ordered]@{ waiting = 0; busy = 0; idle = 0; running = 0; queued = 0; needsInput = 0; cutOff = 0; unread = 0 }
    $some = [ordered]@{ waiting = 1; busy = 2; idle = 3; running = 1; queued = 4; needsInput = 1; cutOff = 3; unread = 2 }
    New-NvOverlayClockCase 'tooltip' 'nothing open' $now $kst ([ordered]@{ snap = (New-NvOverlayClockSnap $zero @() $null) })
    New-NvOverlayClockCase 'tooltip' 'every count, 5h and its reset' $now $kst ([ordered]@{ snap = (New-NvOverlayClockSnap $some @($w5) $null) })
    New-NvOverlayClockCase 'tooltip' 'week holds: no reset said' $now $kst ([ordered]@{ snap = (New-NvOverlayClockSnap $some @($w5, $wk) $null) })
    New-NvOverlayClockCase 'tooltip' 'reloads and an ask' $now $kst ([ordered]@{ snap = (New-NvOverlayClockSnap $some @($w5) ([ordered]@{
                        reload = @([ordered]@{ pid = 10; id = 'a' }, [ordered]@{ pid = 11; id = 'b' }); ask = [ordered]@{ count = 2 } })) })
    $many = [ordered]@{ waiting = 1234; busy = 5678; idle = 9012; running = 3456; queued = 7890; needsInput = 1234; cutOff = 5678; unread = 9012 }
    New-NvOverlayClockCase 'tooltip' 'cut to 127' $now $kst ([ordered]@{ snap = (New-NvOverlayClockSnap $many @($w5) ([ordered]@{
                        reload = @([ordered]@{ pid = 10; id = 'a' }); ask = [ordered]@{ count = 77 } })) })
} -Expect {
    param($In, $Name)
    return (Use-NvTimeZone ([string]$In.zone) {
            $n = Get-NvOverlayClockNow ([string]$In.now)
            switch ([string]$In.kind) {
                'reset' { Format-ChatOverlayReset $In.resetsAt $n }
                'resetAt' { Format-ChatOverlayResetAt $In.resetsAt $n }
                'window' { $w = Get-ChatOverlayResetWindow @($In.windows) $n; if ($null -eq $w) { $null } else { [string]$w } }
                'tooltip' { Format-ChatOverlayTooltip $In.snap $n }
                default { throw "a case of kind '$($In.kind)'" }
            }
        })
}
