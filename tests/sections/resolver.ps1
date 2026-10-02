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

# Codex sibling repos: sibA\app and sibB\app share a leaf name, and only the
# rollout's whole cwd tells them apart. The rollouts sit outside the
# sandbox's codex home, so no other section's index sees them. A's cwd is
# written with a lower-case drive, the way the VS Code extension writes it.
$sibA = Join-Path $work 'sibA\app'
$sibB = Join-Path $work 'sibB\app'
$sibDir = Join-Path $sb 'codex-siblings'
$null = New-Item -ItemType Directory -Path $sibDir -Force
$sibRec = @{}
foreach ($s in @(@{ K = 'A'; Cwd = ($sibA.Substring(0, 1).ToLowerInvariant() + $sibA.Substring(1)); Id = '01900000-0000-7000-8000-0000000000c1' },
        @{ K = 'B'; Cwd = $sibB; Id = '01900000-0000-7000-8000-0000000000c2' })) {
    $f = Join-Path $sibDir "rollout-2026-10-01T10-00-00-$($s.Id).jsonl"
    $lines = @(
        ([ordered]@{ timestamp = $now.ToString('o'); type = 'session_meta'; payload = [ordered]@{ session_id = $s.Id; id = $s.Id; cwd = $s.Cwd; originator = 'codex_vscode' } } | ConvertTo-Json -Compress -Depth 6)
        ([ordered]@{ timestamp = $now.ToString('o'); type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'user'; content = @([ordered]@{ type = 'input_text'; text = "sibling $($s.K)" }) } } | ConvertTo-Json -Compress -Depth 6)
    )
    [System.IO.File]::WriteAllText($f, ($lines -join "`n") + "`n", $utf8)
    $sibRec[$s.K] = & $script:ChatProviders['codex'].Describe (Get-Item -LiteralPath $f)
}
Check 'a Codex row keeps the whole cwd, and the leaf as its group' ($sibRec.B.Cwd -eq $sibB -and $sibRec.B.Group -eq 'app' -and $sibRec.A.Group -eq 'app') "$($sibRec.B.Cwd) / $($sibRec.B.Group)"
$rowA = [pscustomobject]@{ Provider = 'codex'; Group = $sibRec.A.Group; Cwd = $sibRec.A.Cwd }
$rowB = [pscustomobject]@{ Provider = 'codex'; Group = $sibRec.B.Group; Cwd = $sibRec.B.Cwd }
$scA = Get-ChatProjectScope $sibA
Check 'standing in sibA\app: its own Codex chat is in scope' (Test-ChatInProject $rowA $scA)
Check 'standing in sibA\app: sibB\app''s Codex chat is not' (-not (Test-ChatInProject $rowB $scA))
Check 'the same folder written another way still matches' ((Test-ChatInProject $rowA (Get-ChatProjectScope (($sibA.ToUpperInvariant() -replace '\\', '/') + '/'))) -and (Test-ChatInProject $rowB (Get-ChatProjectScope $sibB)))
# in a share, $PWD.Path carries the provider: the folder is the one under it
$rowUnc = [pscustomobject]@{ Provider = 'codex'; Group = 'app'; Cwd = '\\host\share\app' }
$scUnc = Get-ChatProjectScope 'Microsoft.PowerShell.Core\FileSystem::\\host\share\app'
Check 'standing in a share: a Codex chat of that share''s folder is in scope' ((Test-ChatInProject $rowUnc $scUnc) -and -not (Test-ChatInProject $rowA $scUnc)) "$($scUnc.Folder)"
$sel = @(Select-ChatInProject @($rowA, $rowB) -Cwd $sibB)
Check 'Select-ChatInProject keeps only the sibling stood in' ($sel.Count -eq 1 -and $sel[0].Cwd -eq $sibB) "$($sel.Count)"
# a row indexed before the index kept the cwd has only the leaf: it falls
# back to it, so both siblings still see it, as before
$rowOld = [pscustomobject]@{ Provider = 'codex'; Group = 'app' }
Check 'an old Codex row with no Cwd falls back to the leaf' ((Test-ChatInProject $rowOld $scA) -and (Test-ChatInProject $rowOld (Get-ChatProjectScope $sibB)))
# an old row of a repo named codex has the group a rollout with no cwd gets:
# only NoCwd, which the read that found none sets, keeps a row as it is
Check 'an old Codex row is read again once - a repo named codex too; one read with no cwd, or a Claude row, is kept' (
    -not (Test-ChatIndexRowCurrent $rowOld) -and
    -not (Test-ChatIndexRowCurrent ([pscustomobject]@{ Provider = 'codex'; Group = 'app'; Cwd = '' })) -and
    -not (Test-ChatIndexRowCurrent ([pscustomobject]@{ Provider = 'codex'; Group = 'codex'; Cwd = $null })) -and
    -not (Test-ChatIndexRowCurrent ([pscustomobject]@{ Provider = 'codex'; Group = 'codex'; Cwd = ''; NoCwd = $false })) -and
    (Test-ChatIndexRowCurrent $rowA) -and
    (Test-ChatIndexRowCurrent ([pscustomobject]@{ Provider = 'codex'; Group = 'codex'; Cwd = ''; NoCwd = $true })) -and
    (Test-ChatIndexRowCurrent ([pscustomobject]@{ Provider = 'claude'; Group = 'D--x' })))
# an index CSV an older build wrote has no Cwd column: it still reads, under
# StrictMode, with Cwd $null
$oldCsv = Join-Path $sibDir 'old-index.csv'
[System.IO.File]::WriteAllText($oldCsv, ("`"Provider`",`"Path`",`"Size`",`"Mtime`",`"Id`",`"Title`",`"Titled`",`"Group`",`"Hidden`",`"When`",`"First`",`"Last`"`n" +
        "`"codex`",`"X:\r.jsonl`",`"1`",`"1`",`"old-id`",`"old`",`"first message`",`"app`",`"False`",`"$($now.ToString('o'))`",`"a`",`"b`"`n"), $utf8)
$oldRows = @(& { Set-StrictMode -Version Latest; & $script:ChatIndexRead $oldCsv $script:ChatIndexSep })
Check 'an index with no Cwd column reads, with Cwd empty and NoCwd false' ($oldRows.Count -eq 1 -and $null -eq $oldRows[0].Cwd -and $oldRows[0].NoCwd -eq $false -and $oldRows[0].Group -eq 'app') "$($oldRows.Count)"
# and through the real index: a sync keeps the cwd, and a row blanked to look
# old is read again by the next sync even though its rollout did not move
$null = Sync-ChatIndex -Provider codex
$ixCx = @(Get-ChatIndex | Where-Object { $_.Id -eq $cxId })
Check 'the index keeps a Codex chat''s whole folder' ($ixCx.Count -eq 1 -and $ixCx[0].Cwd -eq $projA) "$(@($ixCx | ForEach-Object { $_.Cwd }) -join ', ')"
Save-ChatIndex @(Get-ChatIndex | ForEach-Object {
        if ($_.Provider -ne 'codex') { return $_ }
        $c = $_.PSObject.Copy(); $c.Cwd = $null; $c
    })
$ixBlank = @(Get-ChatIndex | Where-Object { $_.Id -eq $cxId })
$null = Sync-ChatIndex -Provider codex
$ixCx = @(Get-ChatIndex | Where-Object { $_.Id -eq $cxId })
Check 'an old Codex row gets its folder on the next sync' ($ixBlank.Count -eq 1 -and -not $ixBlank[0].Cwd -and $ixCx.Count -eq 1 -and $ixCx[0].Cwd -eq $projA) "$(@($ixCx | ForEach-Object { $_.Cwd }) -join ', ')"
