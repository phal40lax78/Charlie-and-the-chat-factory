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
$probe = "Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; try { . '$(Join-Path $sb 'tool\claude-codex-chat-manager.ps1')'; Set-Location -LiteralPath '$projA'; chatq plugin -WhatIf *> `$null; chatqlist *> `$null; chatqlog 1 *> `$null; `$r = & `$script:ChatTitleCompleter 'chatq' 'Target' 'Pars' `$null @{}; 'ok' } catch { 'threw: ' + `$_.Exception.Message }"
$strict = (& $exe -NoProfile -NonInteractive -Command $probe | Select-Object -Last 1)
Check 'works from a StrictMode Latest session' ($strict -eq 'ok') $strict
