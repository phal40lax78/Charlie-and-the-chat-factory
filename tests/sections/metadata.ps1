# tests/sections/metadata.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'metadata'
$m = Get-ChatqClaudeMeta $pCard (Get-Slug $projA)
Check 'cwd is the project folder' ($m.Cwd -eq $projA) $m.Cwd
Check 'last permission mode' ($m.Mode -eq 'acceptEdits') $m.Mode
Check 'last real model' ($m.Model -eq 'claude-opus-5') $m.Model
$m = Get-ChatqClaudeMeta $pFar (Get-Slug $projA)
Check 'mode 1.3 MB from the end is still found' ($m.Mode -eq 'plan') $m.Mode
$m = Get-ChatqClaudeMeta $pFw (Get-Slug $projA)
Check 'cut off by the limit' ($m.LastTurn.Limit) $m.LastTurn
Check 'reset time read from the record' ($m.LastTurn.ResetsAt -and [Math]::Abs(($m.LastTurn.ResetsAt - [DateTimeOffset]::FromUnixTimeSeconds($future).LocalDateTime).TotalSeconds) -lt 2)
Check 'a finished chat is not cut off' (-not (Get-ChatqClaudeMeta $pCard (Get-Slug $projA)).LastTurn.Limit)
$c = Get-ChatqCodexMeta $cxPath
Check 'codex cwd and sandbox' ($c.Cwd -eq $projA -and $c.Sandbox -eq 'workspace-write' -and $c.Network) "$($c.Cwd) $($c.Sandbox) $($c.Network)"

# Codex sandbox words and effort. Rollouts of their own, outside the Codex
# home so no index lists them: a turn_context with its effort; one with
# only its collaboration mode's; one in the 'managed' shape newer threads
# keep in Codex's DB, which sandbox_mode refuses; one in the app-server's
# camelCase.
$cmDir = Join-Path $sb 'codex-meta'
$null = New-Item -ItemType Directory -Path $cmDir -Force
$cmRollout = {
    param([string]$Name, $Ctx)
    $p = Join-Path $cmDir "$Name.jsonl"
    $ls = @(
        ([ordered]@{ timestamp = $now.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = $Name; cwd = $projA } } | ConvertTo-Json -Compress -Depth 8)
        ([ordered]@{ timestamp = $now.ToString('o'); type = 'turn_context'; payload = $Ctx } | ConvertTo-Json -Compress -Depth 8)
    )
    [System.IO.File]::WriteAllText($p, ($ls -join "`n") + "`n", $utf8)
    $p
}
$cmEff = & $cmRollout 'effort' ([ordered]@{ cwd = $projA; sandbox_policy = [ordered]@{ type = 'read-only' }; model = 'gpt-5.6-terra'; effort = 'medium' })
$cmCollab = & $cmRollout 'collab' ([ordered]@{ cwd = $projA; sandbox_policy = [ordered]@{ type = 'workspace-write'; network_access = $false }; model = 'gpt-5.2-codex'; collaboration_mode = [ordered]@{ mode = 'default'; settings = [ordered]@{ model = 'gpt-5.2-codex'; reasoning_effort = 'high' } } })
$cmManaged = & $cmRollout 'managed' ([ordered]@{ cwd = $projA; model = 'gpt-5.6-terra'; sandbox_policy = [ordered]@{ type = 'managed'; file_system = [ordered]@{ type = 'restricted'; entries = @([ordered]@{ path = [ordered]@{ type = 'special'; value = 'root' }; access = 'read' }) }; network = 'restricted' } })
$cmCamel = & $cmRollout 'camel' ([ordered]@{ cwd = $projA; model = 'gpt-5.6-terra'; sandbox_policy = [ordered]@{ type = 'dangerFullAccess' } })
$cmE = Get-ChatqCodexMeta $cmEff
$cmC = Get-ChatqCodexMeta $cmCollab
Check 'codex effort: the turn''s own, else its collaboration mode''s; none in a rollout without either' ($cmE.Effort -eq 'medium' -and $cmC.Effort -eq 'high' -and -not $c.Effort) "$($cmE.Effort) / $($cmC.Effort) / $($c.Effort)"
$cmCx = { param($p) Get-ChatqJobInfo ([pscustomobject]@{ Provider = 'codex'; Path = $p }) }
$cmIM = & $cmCx $cmManaged
$cmIC = & $cmCx $cmCamel
$cmIE = & $cmCx $cmEff
Check 'a Codex chat in the managed shape: workspace-write for the run, the word kept to say so; camelCase read as the kebab word' (
    (Get-ChatqCodexMeta $cmManaged).Sandbox -eq 'managed' -and $cmIM.Sandbox -eq 'workspace-write' -and $cmIM.Mode -eq 'workspace-write' -and $cmIM.SandboxUnknown -eq 'managed' -and
    $cmIC.Sandbox -eq 'danger-full-access' -and -not $cmIC.SandboxUnknown -and $cmIE.Sandbox -eq 'read-only' -and $cmIE.Effort -eq 'medium' -and $cmIE.Model -eq 'gpt-5.6-terra') (
    "$($cmIM.Sandbox) $($cmIM.SandboxUnknown) / $($cmIC.Sandbox) / $($cmIE.Sandbox) $($cmIE.Effort)")
$cvs = { param($v) $x = ConvertTo-ChatqCodexSandbox $v; "$($x.Sandbox)|$($x.Unknown)" }
Check 'ConvertTo-ChatqCodexSandbox: the three words as they are, camelCase and any case to them; nothing is workspace-write; anything else workspace-write and named' (
    (& $cvs 'read-only') -ceq 'read-only|' -and (& $cvs 'readOnly') -ceq 'read-only|' -and (& $cvs 'workspaceWrite') -ceq 'workspace-write|' -and
    (& $cvs 'Danger-Full-Access') -ceq 'danger-full-access|' -and (& $cvs '') -ceq 'workspace-write|' -and (& $cvs 'managed') -ceq 'workspace-write|managed' -and
    (& $cvs 'externalSandbox') -ceq 'workspace-write|externalSandbox') "$(& $cvs 'managed') $(& $cvs 'readOnly')"
$rs = { param($m, $s) $x = Get-ChatqCodexRunSandbox ([pscustomobject]@{ mode = $m; sandbox = $s }); "$($x.Sandbox)|$($x.Picked)|$($x.Unknown)" }
Check 'a Codex job runs in its own pick, else its chat''s made a word codex takes; a Claude mode left in mode by an older chatq is no pick' (
    (& $rs 'read-only' 'danger-full-access') -eq 'read-only|True|' -and (& $rs $null 'danger-full-access') -eq 'danger-full-access|False|' -and
    (& $rs 'auto' 'read-only') -eq 'read-only|False|' -and (& $rs $null 'managed') -eq 'workspace-write|False|managed') "$(& $rs 'auto' 'read-only') / $(& $rs $null 'managed')"
# queued the way chatq, the console and the phone queue it, not a job
# edited by hand: the job runs workspace-write and still knows the word,
# so its run says so in jobs.log; a sandbox picked for it says nothing
$cmRow = [pscustomobject]@{ Provider = 'codex'; Id = 'c0dexa11-0000-4000-8000-00000000man0'; Title = 'managed shape'; Group = (Split-Path $projA -Leaf); Path = $cmManaged; When = $now }
$cmJ = New-ChatqJob -Row $cmRow -Prompt 'managed'
$cmJP = New-ChatqJob -Row $cmRow -Prompt 'managed, picked' -Mode 'read-only'
$cmRS = if ($cmJ.Job) { Get-ChatqCodexRunSandbox (Read-ChatqJson (Join-Path $script:ChatqQueueDir "$($cmJ.Job.id).json")) }
$cmRP = if ($cmJP.Job) { Get-ChatqCodexRunSandbox $cmJP.Job }
Check 'a job queued for a managed Codex chat keeps the word: it runs workspace-write and its run can say why; one given -Sandbox runs that, and says nothing' (
    $cmJ.Job -and $cmJ.Job.sandbox -eq 'workspace-write' -and $cmJ.Job.sandboxUnknown -eq 'managed' -and $cmRS.Sandbox -eq 'workspace-write' -and $cmRS.Unknown -eq 'managed' -and
    $cmRP.Sandbox -eq 'read-only' -and $cmRP.Picked -and -not $cmRP.Unknown) "$($cmJ.Error) $($cmJP.Error) / $($cmRS.Sandbox) $($cmRS.Unknown) / $($cmRP.Sandbox) $($cmRP.Unknown)"
foreach ($x in @($cmJ.Job, $cmJP.Job)) { if ($x) { $null = Remove-ChatqJob $x 'test' } }
# exec resume writes the run's sandbox into the chat whatever its rank
# (spike S11): a narrower pick - read-only, the phone's cap - sticks as a
# wider one does; the chat's own, a chat not known yet, or a word that is
# no sandbox says nothing
$sk = { param($c, $r) [bool](Get-ChatqCodexStickSay $c $r) }
Check 'a Codex sandbox picked sticks, wider or narrower, and is said; the chat''s own, an unknown chat''s or no sandbox word is not' (
    (& $sk 'workspace-write' 'danger-full-access') -and (& $sk 'workspace-write' 'read-only') -and (& $sk 'danger-full-access' 'workspace-write') -and
    -not (& $sk 'read-only' 'read-only') -and -not (& $sk '' 'read-only') -and -not (& $sk 'workspace-write' '') -and -not (& $sk 'workspace-write' 'gpt-5.6')) (
    "$(Get-ChatqCodexStickSay 'danger-full-access' 'workspace-write') / $(Get-ChatqCodexStickSay '' 'read-only')")
$fcj = [pscustomobject]@{ provider = 'codex'; model = 'gpt-5.6-terra'; effortAtQueue = 'medium'; runModel = $null }
$fcm = [pscustomobject]@{ provider = 'codex'; model = 'gpt-5.6-terra'; effortAtQueue = 'medium'; runModel = 'gpt-9' }
Check 'a Codex run''s words: the model and effort its chat last ran on, none on a -Model of its own' (
    (Format-ChatqRunCarry $fcj) -eq 'gpt-5.6-terra at effort medium' -and (Format-ChatqRunCarry $fcm) -eq '') "$(Format-ChatqRunCarry $fcj)"
Remove-Item -LiteralPath $cmDir -Recurse -Force -EA SilentlyContinue
