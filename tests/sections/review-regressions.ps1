# tests/sections/review-regressions.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'review regressions'
Check 'pwsh-7-style [datetime] input is not shifted' ((ConvertTo-ChatqDate ([datetime]::SpecifyKind([datetime]'2026-09-22 03:00', 'Utc'))) -eq ([datetime]::SpecifyKind([datetime]'2026-09-22 03:00', 'Utc')).ToLocalTime())
Check 'one model''s weekly limit blocks nothing' ($null -eq (Get-ChatqClaudeBlock $claude2))
$Wb = New-ChatqWatchState
$jb = [pscustomobject]@{ provider = 'claude'; home = $claudeHome; model = $null }
$Wb.lastAllowed[(Get-ChatqLane $jb)] = Get-Date
Update-ChatqBlock $Wb $jb -Force
Check 'a limit record older than an allowed probe is ignored' ($null -eq $Wb.blocked[(Get-ChatqLane $jb)])
$e1 = [pscustomobject]@{ id = 'a'; seq = 1; state = 'queued'; provider = 'claude'; home = $null; notBefore = (Get-Date).AddHours(3).ToUniversalTime().ToString('o'); deferUntil = $null }
$e2 = [pscustomobject]@{ id = 'b'; seq = 2; state = 'queued'; provider = 'claude'; home = $null; notBefore = $null; deferUntil = $null }
$eta = Get-ChatqEta @($e1, $e2) @{}
Check 'a free job is not shown "after" a waiting one' ($eta['b'] -eq 'next' -and $eta['a'] -notlike 'after*') "a=$($eta['a']) b=$($eta['b'])"
# the watcher runs one job at a time: of the jobs one reset frees, only the
# first sends then - a Codex job at the same minute too - and the rest each
# after the one before it, a wait's reason kept; a later time is its own
$tu = (Get-Date).AddMinutes(30)
$tb = @{ claude = [pscustomobject]@{ Until = $tu; Type = 'five_hour' }; codex = [pscustomobject]@{ Until = $tu; Type = 'five_hour' } }
$tj = { param([string]$Id, [int]$Seq, [string]$Prov = 'claude', $Nb = $null, $Du = $null) [pscustomobject]@{ id = $Id; seq = $Seq; state = 'queued'; provider = $Prov; home = $null
        notBefore = $(if ($Nb) { ([datetime]$Nb).ToUniversalTime().ToString('o') }); deferUntil = $(if ($Du) { ([datetime]$Du).ToUniversalTime().ToString('o') }); retryAt = $null } }
$te = Get-ChatqEta @((& $tj 't1' 9), (& $tj 't2' 10), (& $tj 't3' 11 'codex'), (& $tj 't4' 12 -Nb $tu.AddHours(2)), (& $tj 't5' 13 -Du $tu.AddMinutes(10)), (& $tj 't6' 14 -Du $tu.AddMinutes(10))) $tb
Check 'one reset''s jobs: the first sends then, each of the rest after the one before it - one at a time' (
    $te['t1'] -match '^(\w{3} )?\d\d:\d\d$' -and $te['t2'] -eq 'after #9' -and $te['t3'] -eq 'after #10' -and $te['t4'] -match '^(\w{3} )?\d\d:\d\d$' -and $te['t4'] -ne $te['t1'] -and
    $te['t5'] -match '^(\w{3} )?\d\d:\d\d \(chat busy\)$' -and $te['t6'] -eq 'after #13 (chat busy)') (@('t1', 't2', 't3', 't4', 't5', 't6' | ForEach-Object { "$_=$($te[$_])" }) -join ' ')
Check 'Continue says it queued them to go one at a time' ((Format-ChatqContinueSay 3 0) -eq 'queued 3 continues - one at a time, each when its limit is over' -and
    (Format-ChatqContinueSay 1 2) -eq 'queued 1 continue - it goes when its limit is over; 2 had one already' -and (Format-ChatqContinueSay 0 1) -eq 'queued 0 continues; 1 had one already') (Format-ChatqContinueSay 3 0)
Set-Location -LiteralPath $sb
$r = Resolve-ChatqTarget 'zzqx nothing like it'
Check 'no project here and no match: refuse to guess' ($r.Error -like '*not a project*') $r.Error
Set-Location -LiteralPath $projA
$hdr = "<!-- chatq: prompt for '$('A ---> B' -replace '-{2,}', '-')' (claude). tail -->`n`nreal prompt"
Check 'a title full of dashes cannot close the header early' ((Remove-ChatqPromptHeader $hdr) -eq 'real prompt') (Remove-ChatqPromptHeader $hdr)
$smart = "Don$([char]0x2019)t break"
$esc = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($smart)
Check 'completion quotes a typographic apostrophe' ($null -ne [scriptblock]::Create("'$esc'"))
# a profile with StrictMode on: dot-source there, then only what a user types
$exe = (Get-Process -Id $PID).Path
$probe = "Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; try { . '$(Join-Path $sb 'tool\VS-code-chat-manager.ps1')'; Set-Location -LiteralPath '$projA'; chatq plugin -WhatIf *> `$null; chatqlist *> `$null; chatqlog 1 *> `$null; `$r = & `$script:ChatTitleCompleter 'chatq' 'Target' 'Pars' `$null @{}; 'ok' } catch { 'threw: ' + `$_.Exception.Message }"
$strict = (& $exe -NoProfile -NonInteractive -Command $probe | Select-Object -Last 1)
Check 'works from a StrictMode Latest session' ($strict -eq 'ok') $strict
