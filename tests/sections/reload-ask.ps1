# tests/sections/reload-ask.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'a reload asked for, on the overlay too'
# the files a VS Code window keeps while its reload notice is up
# (extension.js askReload), as this process's: a pid that is alive
$rpDir = $script:ChatReloadPendingDir
$null = New-Item -ItemType Directory -Path $rpDir -Force
$meStart = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds()
function Write-RpFile([int]$HostPid, [int64]$Started, [object[]]$Asks, [string]$Window = 'Hospital beds') {
    $o = [ordered]@{ v = 1; pid = $HostPid; started = $Started; window = $Window; asks = @($Asks) }
    [System.IO.File]::WriteAllText((Join-Path $rpDir "$HostPid.json"), ($o | ConvertTo-Json -Compress -Depth 5), [System.Text.UTF8Encoding]::new($true))
}
$askA = [ordered]@{ id = "$PID-1-a"; state = 'offered'; say = '"Old chat" deleted - the chat list still shows it'; text = 'Reload to drop it.'; at = 1 }
$askB = [ordered]@{ id = "$PID-2-b"; state = 'anyway'; say = 'it would stop 2 working chats'; text = 'Reload anyway? Two chats work here.'; at = 2 }
Write-RpFile $PID $meStart @($askA, $askB)
# a window gone: a multiple of 4 - Windows drops a pid's low two bits as it
# opens one - that no running process has
$pidsNow = @(Get-Process | ForEach-Object Id)
$gonePid = 4000
while ($pidsNow -contains $gonePid) { $gonePid += 4 }
Write-RpFile $gonePid $meStart @($askA)
[System.IO.File]::WriteAllText((Join-Path $rpDir 'notes.json'), '{}', $utf8)
$rp = @(Read-ChatReloadPending)
Check 'the reloads windows ask about: one entry a window, its newest ask, and a gone window''s file removed' ($rp.Count -eq 1 -and $rp[0].pid -eq $PID -and
    $rp[0].id -eq "$PID-2-b" -and $rp[0].state -eq 'anyway' -and $rp[0].count -eq 2 -and $rp[0].window -eq 'Hospital beds' -and
    -not (Test-Path -LiteralPath (Join-Path $rpDir "$gonePid.json"))) ($rp | ConvertTo-Json -Compress)
# a pid alive but started days after the file says: reused, not that window
Write-RpFile $PID ($meStart - 3 * 86400000) @($askA)
$rpReused = @(Read-ChatReloadPending)
Check 'a file whose pid now names a process started long after it is removed as a reused pid' ($rpReused.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $rpDir "$PID.json"))) "$($rpReused.Count)"
Write-RpFile $PID $meStart @()
Check 'a window with no ask left open shows nothing' (@(Read-ChatReloadPending).Count -eq 0) ''
Check 'no pending folder at all: nothing, and no error' (@(Read-ChatReloadPending -Dir (Join-Path $sb 'no-such-pending')).Count -eq 0) ''

# the answer the window reads (extension.js onReloadAnswer): no BOM, which
# JSON.parse would take for a character, and an at Date.parse reads
Write-ChatReloadAnswer -HostPid $PID -Id "$PID-2-b" -Answer later
$ansFile = Join-Path $script:ChatReloadAnswerDir "$PID.json"
$ansBytes = [System.IO.File]::ReadAllBytes($ansFile)
$ansText = [System.IO.File]::ReadAllText($ansFile)
$ans = $ansText | ConvertFrom-Json
# at matched in the text: pwsh 7's ConvertFrom-Json turns an ISO time into a DateTime
Check 'the overlay''s answer: reload-answer/<pid>.json with the ask''s id, the answer and a UTC at, without a BOM' ($ansBytes[0] -eq [byte][char]'{' -and
    $ans.id -eq "$PID-2-b" -and $ans.answer -eq 'later' -and $ansText -match '"at":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"') ([System.Text.Encoding]::UTF8.GetString($ansBytes))
Remove-Item -LiteralPath $ansFile -Force

# the collector: the snapshot's header.reload, its note, the tooltip; one
# answered here is left out until the window has taken it
Write-RpFile $PID $meStart @($askA, $askB)
$ctxR = New-ChatOverlayContext
$snapR = Invoke-ChatOverlayCycle $ctxR -Peek
$hdR = @($snapR.header.reload)
$noteR = @($snapR.header.notes | Where-Object { (Get-ChatField $_ 'kind') -eq 'reload' })
Check 'a pass puts the ask in header.reload, and a note of kind reload for -Print and the macOS panel' ($hdR.Count -eq 1 -and $hdR[0].id -eq "$PID-2-b" -and
    $noteR.Count -eq 1 -and $noteR[0].text -eq 'Hospital beds needs a reload - it would stop 2 working chats' -and $noteR[0].tone -eq 'warn') ($snapR.header | ConvertTo-Json -Compress -Depth 4)
Check 'the tray tooltip counts it' ((Format-ChatOverlayTooltip $snapR) -like 'Charlie: *1 reload asked*') (Format-ChatOverlayTooltip $snapR)
# two windows asking at once: one entry each, and the pass takes both
$other = Get-Process | Where-Object { $_.Id -ne $PID -and $_.Id -gt 4 } | ForEach-Object { try { if ($_.StartTime) { $_ } } catch {} } | Select-Object -First 1
if ($other) {
    Write-RpFile $other.Id ([DateTimeOffset]::new($other.StartTime).ToUnixTimeMilliseconds()) @([ordered]@{ id = "$($other.Id)-1-c"; state = 'offered'; say = 'x'; text = 't'; at = 3 }) 'Second window'
    $ctxT = New-ChatOverlayContext
    $snapT = Invoke-ChatOverlayCycle $ctxT -Peek
    $hdT = @($snapT.header.reload)
    Remove-Item -LiteralPath (Join-Path $rpDir "$($other.Id).json") -Force -EA SilentlyContinue
    Check 'two windows asking at once: an entry each, in header.reload and the notes' ($hdT.Count -eq 2 -and
        @($hdT | ForEach-Object { $_.window } | Sort-Object) -join ',' -eq 'Hospital beds,Second window' -and
        @($snapT.header.notes | Where-Object { (Get-ChatField $_ 'kind') -eq 'reload' }).Count -eq 2) ($snapT.header | ConvertTo-Json -Compress -Depth 4)
}
else { Check 'two windows asking at once (no second process with a start time readable here - skipped)' $true '' }
$ctxR.ReloadAnswered["${PID}:$PID-2-b"] = Get-Date
$snapR2 = Invoke-ChatOverlayCycle $ctxR -Peek
$ctxR.ReloadAnswered["${PID}:$PID-2-b"] = (Get-Date).AddSeconds(-31)
$snapR3 = Invoke-ChatOverlayCycle $ctxR -Peek
Check 'answered here, it is left out for 30 s - then shown again, the window never having taken it' (@($snapR2.header.reload).Count -eq 0 -and
    @($snapR3.header.reload).Count -eq 1 -and -not $ctxR.ReloadAnswered.Count) "$(@($snapR2.header.reload).Count) $(@($snapR3.header.reload).Count)"
Check 'the reload file is read every 2 s, not every pass' ((Get-Command Invoke-ChatOverlayCycle).Definition.Contains('($now - $Ctx.ReloadsAt).TotalSeconds -ge 2')) ''
Check 'Format-ChatOverlayReloadText: a window with no name, and no why' ((Format-ChatOverlayReloadText ([pscustomobject]@{ window = ''; say = '' })) -eq 'a VS Code window needs a reload') ''

# the banner's chips, and where their release goes
$rlRow = { param($st) [pscustomobject]@{ key = "reload:$PID"; kind = 'reload'; provider = ''; sessionId = ''; cwd = ''; pid = $PID; id = "$PID-2-b"; state = $st; window = 'Hospital beds' } }
$caR1 = @(Get-ChatOverlayChipActions (& $rlRow 'offered'))
$caR2 = @(Get-ChatOverlayChipActions (& $rlRow 'anyway'))
Check 'a reload banner''s chips: reload - reload anyway where it would stop a chat - and later; no open, no delete' (
    (($caR1 | ForEach-Object Id) -join ',') -eq 'reload-go,reload-later' -and $caR1[0].Label -eq 'reload' -and $caR2[0].Label -eq 'reload anyway' -and
    $caR1[1].Label -eq 'later' -and $caR2[0].Tip -like '*Hospital beds*working there stops*') "$(($caR1 | ForEach-Object Label) -join ',') $(($caR2 | ForEach-Object Label) -join ',')"
Check 'no row count takes the banner for a row' (-not (Test-ChatOverlayOpenRowElement ([pscustomobject]@{ Tag = (& $rlRow 'offered') }))) ''
$script:RlAns = @()
$fnRl = ${function:Invoke-ChatOverlayReloadAnswer}
${function:Invoke-ChatOverlayReloadAnswer} = { param($H, $Row, $Answer) $script:RlAns += "$($Row.id)=$Answer" }
try {
    $Hr = @{ ChipRow = (& $rlRow 'offered') }
    Invoke-ChatOverlayChipRelease $Hr 'reload-go' 'reload-later'
    Invoke-ChatOverlayChipRelease $Hr 'reload-go' 'reload-go'
    Invoke-ChatOverlayChipRelease $Hr 'reload-later' 'reload-later'
}
finally { ${function:Invoke-ChatOverlayReloadAnswer} = $fnRl }
Check 'reload and later go to the answer, a press dragged from one to the other to neither' (($script:RlAns -join '|') -eq "$PID-2-b=reload|$PID-2-b=later") ($script:RlAns -join '|')

# the answer from the chip: written, marked answered, said on the panel's line
$fnHide = ${function:Hide-ChatOverlayChip}; $fnView = ${function:Update-ChatOverlayView}; $fnTray = ${function:Update-ChatOverlayTray}
$script:RlViews = 0
${function:Hide-ChatOverlayChip} = { param($H) }
${function:Update-ChatOverlayView} = { param($H, $Snap) $script:RlViews++; $H.Snap = $Snap }
${function:Update-ChatOverlayTray} = { param($H, $Snap) }
try {
    $Hq = @{ Ctx = $ctxR; ViewKey = 'x'; OpenSay = $null }
    Invoke-ChatOverlayReloadAnswer $Hq (& $rlRow 'anyway') 'reload'
}
finally { ${function:Hide-ChatOverlayChip} = $fnHide; ${function:Update-ChatOverlayView} = $fnView; ${function:Update-ChatOverlayTray} = $fnTray }
$ansR = if (Test-Path -LiteralPath $ansFile) { [System.IO.File]::ReadAllText($ansFile) | ConvertFrom-Json } else { $null }
Check 'reload from the chip: the answer written for that window, the banner gone at once, the panel says it' ($ansR -and $ansR.answer -eq 'reload' -and
    $ansR.id -eq "$PID-2-b" -and $ctxR.ReloadAnswered.ContainsKey("${PID}:$PID-2-b") -and $script:RlViews -eq 1 -and
    @($Hq.Snap.header.reload).Count -eq 0 -and $Hq.OpenSay.Kind -eq 'reload' -and $Hq.OpenSay.Text -like 'Hospital beds reloads*') "$($ansR | ConvertTo-Json -Compress) $($Hq.OpenSay.Text)"
Remove-Item -LiteralPath $ansFile, (Join-Path $rpDir "$PID.json"), (Join-Path $rpDir 'notes.json') -Force -EA SilentlyContinue
