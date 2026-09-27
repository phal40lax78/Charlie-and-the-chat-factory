# tests/sections/resolver.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'resolver'
$r = Resolve-ChatqTarget 'Parser rewrite and plugin unification'
Check 'exact title' ($r.Row.Id -eq $idFw -and $r.Rule -eq 'exact') "$($r.Rule) $($r.Row.Id)"
$r = Resolve-ChatqTarget 'plugin'
Check 'contains' ($r.Row.Id -eq $idFw -and $r.Tier -eq 'contains') "$($r.Rule)"
$r = Resolve-ChatqTarget 'card redesign'
Check 'every word, any order' ($r.Row.Id -eq $idCard -and $r.Tier -eq 'words') "$($r.Rule) $($r.Row.Title)"
$r = Resolve-ChatqTarget $titleCard
Check 'exact Hangul title' ($r.Row.Id -eq $idCard -and $r.Rule -eq 'exact') "$($r.Rule)"
$r = Resolve-ChatqTarget ($titleCard.Normalize([System.Text.NormalizationForm]::FormD))
Check 'NFD-typed Hangul still exact' ($r.Row.Id -eq $idCard -and $r.Rule -eq 'exact') "$($r.Rule)"
$r = Resolve-ChatqTarget 'card UI'
Check 'two within 5h -> relevance' ($r.Rule -eq 'contains/relevance' -and $r.Cluster -eq 2) "$($r.Rule) cluster=$($r.Cluster)"
$r = Resolve-ChatqTarget 'card UI' "$tTong $tTong UI merge"
Check 'the prompt decides between look-alikes' ($r.Row.Id -eq $idTong) "$($r.Row.Title) $($r.Score) vs $($r.RunnerUpScore)"
Check 'runner-up is reported' ($null -ne $r.RunnerUp -and $r.RunnerUp.Id -eq $idCard) "$($r.RunnerUp.Title)"
$r = Resolve-ChatqTarget 'zzqx nothing like it'
Check 'no match: a guess from this project only' ($r.Tier -eq 'nomatch' -and (Test-ChatInProject $r.Row (Get-ChatProjectScope $projA))) "$($r.Rule) $($r.Row.Group)"
Check 'no match never reaches the nested sibling slug' ($r.Row.Id -ne $idMob)
# a prompt typed after the title joins the title, and only ever guesses a chat
$said = (Write-ChatqPromptHint 'zzqx nothing like it read the notes at C:\tmp\p.txt and improve' $r 6>&1 | Out-String -Width 400)
Check 'a sentence typed as a title points at -Prompt' ($said -match "-Prompt '<the rest>'") $said
$said = (Write-ChatqPromptHint 'zzqx nothing like it and a few more words' $r -HasPrompt 6>&1 | Out-String -Width 400)
Check 'no hint when the prompt was given' (-not $said.Trim()) $said
$said = (Write-ChatqPromptHint 'zzqx nothing' $r 6>&1 | Out-String -Width 400)
Check 'no hint for a short target' (-not $said.Trim()) $said
$r2 = Resolve-ChatqTarget 'card redesign'
$said = (Write-ChatqPromptHint 'card redesign and a few more words here' $r2 6>&1 | Out-String -Width 400)
Check 'no hint when a title really matched' (-not $said.Trim()) $said
# and through chatq itself, the way it was typed - -WhatIf queues nothing
$said = (chatq zzqx nothing like it read the notes at C:\tmp\p.txt and improve -WhatIf 6>&1 | Out-String -Width 400)
Check 'chatq itself says it for a prompt typed where the title goes' ($said -like "*-Prompt '<the rest>'*") $said
$r = Resolve-ChatqTarget 'Mobile only chat'
Check 'a title only in another project is found there' ($r.Row.Id -eq $idMob -and $r.Wide) "$($r.Rule) wide=$($r.Wide)"
$r = Resolve-ChatqTarget '2222222'
Check 'hex prefix is an id' ($r.Row.Id -eq $idCard -and $r.Rule -eq 'id') "$($r.Rule)"
$r = Resolve-ChatqTarget $longTitle
Check 'a title past the 60-char clip still exact' ($r.Row.Id -eq $idLong -and $r.Rule -eq 'exact') "$($r.Rule)"
Set-Location -LiteralPath $projE
$r = Resolve-ChatqTarget 'tool'
Check '4h59 apart: relevance decides' ($r.Rule -eq 'contains/relevance') "$($r.Rule)"
$null = New-FakeChat $projE $idB 'Edge beta tool' (1 + 5.05) @('beta')
$r = Resolve-ChatqTarget 'tool'
Check '5h03 apart: newest wins' ($r.Rule -eq 'contains/newest' -and $r.Row.Id -eq $idA) "$($r.Rule)"
Set-Location -LiteralPath $projA
$r = Resolve-ChatqTarget 'Codex gitignore thread'
Check 'codex thread name resolves' ($r.Row.Provider -eq 'codex' -and $r.Row.Id -eq $cxId) "$($r.Row.Provider) $($r.Row.Id)"
