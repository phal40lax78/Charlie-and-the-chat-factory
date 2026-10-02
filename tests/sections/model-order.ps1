# tests/sections/model-order.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'per-job model and order'
Lock-Queue { chatq 'Deadline notes' -Prompt 'on another model' -Model 'claude-sonnet-9' *> $null }
$jm = @(Get-ChatqJobs | Where-Object { $_.runModel -eq 'claude-sonnet-9' })[0]
Check '-Model is kept apart from the chat''s own model' ($jm -and $jm.model -eq 'claude-opus-5') "$($jm.runModel) $($jm.model)"
$null = Invoke-ChatqProbe 'claude' $jm
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'the probe asks with it' ($argv -match '--no-session-persistence' -and $argv -match '--model\s+claude-sonnet-9') ($argv -replace "`n", ' ')
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jm.id)
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'and the run uses it' ($argv -match '--resume' -and $argv -match '--model\s+claude-sonnet-9') ($argv -replace "`n", ' ')
Lock-Queue { chatq 'Codex gitignore thread' -Prompt 'on gpt-9' -Model 'gpt-9' *> $null }
$jx = @(Get-ChatqJobs | Where-Object { $_.runModel -eq 'gpt-9' })[0]
$null = Invoke-ChatqRun $jx 'x' $null $null
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'a Codex run gets -m before the thread id' ($argv -match "-m\s+gpt-9\s+$cxId") ($argv -replace "`n", ' ')
# the Codex probe: low effort and the run's model, never config.toml's
# xhigh on its own model; a -Model kept even when the probe fails, as the
# run will use exactly that
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\codex-done.jsonl'
$pbX = Invoke-ChatqProbe 'codex' $jx
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Remove-Item env:FAKE_SCENARIO
$pbX2 = Invoke-ChatqProbe 'codex' $jx
$argv2 = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'the Codex probe asks a -Model at low effort, and keeps it when the probe fails' (
    $pbX.Allowed -and $argv -match '--ephemeral' -and $argv -match '-m\s+gpt-9' -and $argv -match '-c\s+model_reasoning_effort=low' -and
    -not $pbX2.Allowed -and $argv2 -match '-m\s+gpt-9' -and $argv2 -match 'model_reasoning_effort=low') "$($pbX.Allowed) $($argv -replace "`n", ' ') / $($pbX2.Allowed) $($argv2 -replace "`n", ' ')"
# the console's chips change a waiting Codex job's sandbox and model too:
# the three words or '' for the chat's own, never a Claude mode
$raCx1 = Set-ChatqJobRunAs $jx 'mode' 'danger-full-access'
$raCxM = [string](Find-ChatqJob $jx.id -Exact).mode
$raCx2 = Set-ChatqJobRunAs $jx 'mode' ''
$raCxB = (Find-ChatqJob $jx.id -Exact).mode
$raCx3 = Set-ChatqJobRunAs $jx 'mode' 'auto'
$raCx4 = Set-ChatqJobRunAs $jx 'model' 'gpt-9.1'
Check 'a waiting Codex job takes a sandbox word or '''' as its mode and a model, and refuses a Claude mode' (
    -not $raCx1 -and $raCxM -eq 'danger-full-access' -and -not $raCx2 -and -not $raCxB -and $raCx3 -like '*Codex chat''s*sandbox*' -and -not $raCx4 -and
    (Find-ChatqJob $jx.id -Exact).runModel -eq 'gpt-9.1' -and (Get-ChatqModeRefusal 'claude' 'read-only') -like '*Codex sandbox*') "$raCx1 / $raCxM / $raCx3 / $raCx4"
chatqrm $jx.seq -Force *> $null

# -Sandbox for one Codex job: its mode, the chat's own kept as its sandbox,
# sent as sandbox_mode - the chat's network flag only under workspace-write
$sbSaid = Lock-Queue { chatq 'Codex gitignore thread' -Prompt 'only read, please' -Sandbox read-only 6>&1 | Out-String -Width 400 }
$jro = @(Get-ChatqJobs | Where-Object { $_.provider -eq 'codex' -and (Read-ChatqPrompt $_) -eq 'only read, please' })[0]
$null = Invoke-ChatqRun $jro 'x' $null $null
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check '-Sandbox read-only on a Codex chat: its mode, the chat''s own sandbox kept, sent as sandbox_mode with no network flag' (
    $jro -and $jro.mode -eq 'read-only' -and $jro.sandbox -eq 'workspace-write' -and $jro.network -and $argv -match 'sandbox_mode=read-only' -and
    $argv -notmatch 'network_access' -and $sbSaid -like '*read-only (given)*' -and $sbSaid -like '*gpt-5.6 (as the chat last ran)*') "$($jro.mode) $($jro.sandbox) / $($argv -replace "`n", ' ') / $sbSaid"
# no -Model: the probe names the chat's own, at low effort; when that fails -
# a model the account has since lost - it asks again without one, as the
# resume names none
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\codex-done.jsonl'
$pbO = Invoke-ChatqProbe 'codex' $jro
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Remove-Item env:FAKE_SCENARIO
$pbO2 = Invoke-ChatqProbe 'codex' $jro
$argv2 = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'the Codex probe asks the chat''s own model at low effort, and without it when that fails' (
    $pbO.Allowed -and $argv -match '-m\s+gpt-5\.6' -and $argv -match '-c\s+model_reasoning_effort=low' -and
    -not $pbO2.Allowed -and $argv2 -notmatch '(^|\n)-m(\n|$)' -and $argv2 -match 'model_reasoning_effort=low') "$($pbO.Allowed) $($argv -replace "`n", ' ') / $($pbO2.Allowed) $($argv2 -replace "`n", ' ')"
# A job saved with 'managed' - the word newer threads keep in Codex's DB,
# which sandbox_mode refuses at config load - runs workspace-write, and the
# diary says why
Set-ChatqProp $jro 'mode' $null
Set-ChatqProp $jro 'sandbox' 'managed'
Save-ChatqJob $jro
$null = Invoke-ChatqRun (Find-ChatqJob $jro.id -Exact) 'x' $null $null
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
$diary = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'jobs.log'), $utf8)
Check 'a Codex job saved with sandbox managed runs workspace-write with its network, never managed, and the diary says why' (
    $argv -match 'sandbox_mode=workspace-write' -and $argv -notmatch 'sandbox_mode=managed' -and $argv -match 'network_access=true' -and
    $diary -match "#$($jro.seq) its chat's sandbox 'managed' is no word codex takes - runs in workspace-write") ($argv -replace "`n", ' ')
# requeued wider: chatqrun -Sandbox, with the warning that it sticks;
# -Mode on it, and a Claude mode handed to Reset-ChatqJob, refused
Complete-ChatqJob (Find-ChatqJob $jro.id -Exact) 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'test' }) 'test'
$rqNo = Lock-Queue { chatqrun $jro.seq -Mode auto 6>&1 | Out-String -Width 400 }
$rqReset = Reset-ChatqJob (Find-ChatqJob $jro.id -Exact) 'plan'
$rqSaid = Lock-Queue { chatqrun $jro.seq -Sandbox danger-full-access 6>&1 | Out-String -Width 400 }
$jrq = Find-ChatqJob $jro.id -Exact
Check 'chatqrun -Sandbox requeues a Codex job wider and says it sticks; -Mode on it, and a Claude mode, are refused' (
    $rqNo -like '*is a Codex chat''s - it runs in a sandbox*' -and $rqReset.Error -like '*a Codex chat runs in a sandbox*' -and
    $jrq.state -eq 'queued' -and $jrq.mode -eq 'danger-full-access' -and $rqSaid -like '*a sandbox picked sticks*') "$rqNo / $($rqReset.Error) / $($jrq.state) $($jrq.mode) / $rqSaid"
chatqrm $jro.seq -Force *> $null
# -Mode on a Codex chat and -Sandbox on a Claude one: refused as given,
# never stored and then ignored as -Mode on Codex used to be
$mrBefore = @(Get-ChatqJobs).Count
$mrCx = Lock-Queue { chatq 'Codex gitignore thread' -Prompt 'x' -Mode auto 6>&1 | Out-String -Width 400 }
$mrCl = Lock-Queue { chatq 'Deadline notes' -Prompt 'x' -Sandbox read-only 6>&1 | Out-String -Width 400 }
$mrNew = New-ChatqJob -Row (Get-ChatqRowById -Id $cxId -Provider codex) -Prompt 'x' -Mode 'acceptEdits'
Check '-Mode on a Codex chat and -Sandbox on a Claude one are refused and queue nothing; New-ChatqJob refuses a Claude mode for Codex' (
    @(Get-ChatqJobs).Count -eq $mrBefore -and $mrCx -like '*a Codex chat runs in a sandbox, not a mode*nothing queued*' -and
    $mrCl -like '*-Sandbox is for a Codex chat*nothing queued*' -and $mrNew.Code -eq 'mode') "$mrCx / $mrCl / $($mrNew.Error)"

Lock-Queue {
    chatq 'Old chat about gitignore rules' -Prompt 'back of the line' *> $null
    chatq 'Old chat about gitignore rules' -Prompt 'front of the line' -First *> $null
}
$q = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })
Check '-First puts a job ahead of older ones' ((Read-ChatqPrompt $q[0]) -eq 'front of the line') (Read-ChatqPrompt $q[0])
$eta = Get-ChatqEta $q @{}
Check 'and the "sends" column agrees' ($eta[$q[0].id] -eq 'next') $eta[$q[0].id]
$back = @($q | Where-Object { (Read-ChatqPrompt $_) -eq 'back of the line' })[0]
chatqrun $back.seq -First *> $null
$q = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })
Check 'chatqrun <n> -First moves a queued job up' ($q[0].id -eq $back.id) (Read-ChatqPrompt $q[0])
foreach ($x in @($q | Where-Object { (Read-ChatqPrompt $_) -like '*of the line' })) { chatqrm $x.seq -Force *> $null }
# a job's own history goes with its file, so the diary is the only account left
# of one that was removed rather than run
$diary = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'jobs.log'), $utf8)
Check 'every job event is logged, removals included' ($diary -match "#$($back.seq) queued \(prompt\)" -and $diary -match "#$($back.seq) removed by chatqrm \(was queued\)") (@($diary -split "`n" | Where-Object { $_ -match "#$($back.seq) " }) -join ' / ')
Remove-Item env:FAKE_RECORD

Section 'which codex runs, and its version'
# A codex on PATH - a .cmd that is the fake, saying FAKE_VERSION - and the
# VS Code extension's copy under a home of the sandbox's own. The extension's
# is an empty file: its version is put in Get-ChatqCliVersion's cache, which
# is read before anything is run. PATH is cut to Windows' own folders, so a
# real codex on this PC can never be the one found. The cache is put back
# whole after: CHATQ_CLAUDE is the same fake, and a codex version cached for
# it would fail every later Claude run as too old.
$cvCache = $script:ChatqCliVersions.Clone()
$cvWasPath = $env:PATH
$cvWasCodex = $env:CHATQ_CODEX
$cvWasClaude = $env:CHATQ_CLAUDE
$cvWasClHome = $script:ChatClaudeHome
$cvFake = Join-Path $here 'fake-claude.cmd'
$cvBin = Join-Path $sb 'cli-path'
$null = New-Item -ItemType Directory -Path $cvBin -Force
$cvPathExe = Join-Path $cvBin 'codex.cmd'
[System.IO.File]::WriteAllText($cvPathExe, "@echo off`r`nset `"FAKE_ARGV=%*`"`r`npowershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $here 'fake-agent.ps1')`"`r`n", [System.Text.Encoding]::ASCII)
$cvHome = Join-Path $sb 'ext-home'
$cvExtBin = Join-Path $cvHome '.vscode\extensions\openai.chatgpt-26.928.40906-win32-x64\bin\windows-x86_64'
$null = New-Item -ItemType Directory -Path $cvExtBin -Force
$cvBundled = Join-Path $cvExtBin 'codex.exe'
[System.IO.File]::WriteAllText($cvBundled, '', $utf8)
# as the search will name it, so the cache below is the one it reads
$cvBundled = (Get-Item -LiteralPath $cvBundled).FullName
$script:ChatqExtHomeSeam = $cvHome
$script:ChatqCliVersions[$cvBundled] = '0.159.2'
$cvSys = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
try {
    Remove-Item env:CHATQ_CODEX
    $env:PATH = "$cvBin;$cvSys"
    $env:FAKE_VERSION = 'codex-cli 0.150.0'
    $cvOld = Get-ChatqCliReport codex
    $cvSaid = Write-ChatCliReport 6>&1 | Out-String -Width 400
    $cvRow = @(chatproviders | Where-Object { $_.Provider -eq 'codex' })[0]
    Check 'an older codex on PATH: picked, its version read from its own --version, and warned about beside the extension''s' (
        $cvOld.Path -eq $cvPathExe -and $cvOld.From -eq 'PATH' -and $cvOld.Version -eq '0.150.0' -and $cvOld.Bundled -eq $cvBundled -and
        $cvOld.BundledVersion -eq '0.159.2' -and $cvOld.Older -and $cvOld.Warn -like '*codex on PATH (0.150.0) is older than the VS Code extension''s (0.159.2)*' -and
        (Find-ChatqExe codex) -eq $cvPathExe) "$($cvOld | ConvertTo-Json -Compress)"
    Check 'chatinstall''s lines and chatproviders say it too: version, on PATH, the path, the warning' (
        $cvSaid -like '*codex 0.150.0 - on PATH*' -and $cvSaid -like "*$cvPathExe*" -and $cvSaid -like '*is older than*remove it to use the extension''s*' -and
        $cvRow.Cli -eq $cvPathExe -and $cvRow.CliVersion -eq '0.150.0' -and $cvRow.CliFrom -eq 'on PATH' -and $cvRow.Warning -like '*older than*') "$cvSaid / $($cvRow | ConvertTo-Json -Compress)"

    $null = $script:ChatqCliVersions.Remove($cvPathExe)
    $env:FAKE_VERSION = 'codex-cli 0.160.1'
    $cvNew = Get-ChatqCliReport codex
    Check 'a codex on PATH as new or newer: no warning' ($cvNew.Version -eq '0.160.1' -and -not $cvNew.Older -and -not $cvNew.Warn) "$($cvNew | ConvertTo-Json -Compress)"

    $env:PATH = $cvSys
    $cvExt = Get-ChatqCliReport codex
    Check 'none on PATH: the extension''s copy, said as that, compared with nothing' (
        $cvExt.Path -eq $cvBundled -and $cvExt.From -eq 'bundled' -and $cvExt.Version -eq '0.159.2' -and -not $cvExt.Bundled -and -not $cvExt.Warn -and
        $cvExt.Say -eq 'codex 0.159.2 - the VS Code extension''s copy') "$($cvExt | ConvertTo-Json -Compress)"

    # CHATQ_CODEX is a choice: said, never compared, however old
    $env:CHATQ_CODEX = $cvFake
    $null = $script:ChatqCliVersions.Remove($cvFake)
    $env:FAKE_VERSION = 'codex-cli 0.150.0'
    $cvOver = Get-ChatqCliReport codex
    Check 'CHATQ_CODEX: picked and said as the override, with no extension lookup and no warning' (
        $cvOver.Path -eq $cvFake -and $cvOver.From -eq 'CHATQ_CODEX' -and $cvOver.Version -eq '0.150.0' -and -not $cvOver.Bundled -and -not $cvOver.Warn -and
        $cvOver.Say -eq 'codex 0.150.0 - from CHATQ_CODEX') "$($cvOver | ConvertTo-Json -Compress)"
    Check 'the app-server floor parses, and the versions either side of it compare as such' (
        (Compare-ChatVersion '0.159.2' $script:ChatqCodexAppServerMin) -eq 1 -and (Compare-ChatVersion '0.150.0' $script:ChatqCodexAppServerMin) -eq -1) $script:ChatqCodexAppServerMin

    # Claude Code's own installer puts its folder on PATH: found there, it is
    # still its own install - off PATH it would be picked all the same, so
    # "remove it to use the extension's" would send nobody anywhere. Empty
    # files, their versions in the cache; a Claude home of the sandbox's own.
    $script:ChatClaudeHome = Join-Path $sb 'cl-home'
    $clLocalDir = Join-Path $script:ChatClaudeHome 'local'
    $null = New-Item -ItemType Directory -Path $clLocalDir -Force
    $clLocal = Join-Path $clLocalDir 'claude.exe'
    [System.IO.File]::WriteAllText($clLocal, '', $utf8)
    $clLocal = (Get-Item -LiteralPath $clLocal).FullName
    $clExtBin = Join-Path $cvHome '.vscode\extensions\anthropic.claude-code-2.1.300-win32-x64\resources\native-binary'
    $null = New-Item -ItemType Directory -Path $clExtBin -Force
    $clBundled = Join-Path $clExtBin 'claude.exe'
    [System.IO.File]::WriteAllText($clBundled, '', $utf8)
    $clBundled = (Get-Item -LiteralPath $clBundled).FullName
    $script:ChatqCliVersions[$clLocal] = '2.1.290'
    $script:ChatqCliVersions[$clBundled] = '2.1.300'
    Remove-Item env:CHATQ_CLAUDE
    $env:PATH = "$clLocalDir;$cvSys"
    $clRep = Get-ChatqCliReport claude
    Check 'Claude Code''s own install on PATH: said as its own install, never compared with the extension''s' (
        $clRep.Path -eq $clLocal -and $clRep.From -eq 'local' -and $clRep.Version -eq '2.1.290' -and -not $clRep.Bundled -and -not $clRep.Warn -and
        $clRep.Say -eq 'claude 2.1.290 - Claude Code''s own install') "$($clRep | ConvertTo-Json -Compress)"
}
finally {
    $env:PATH = $cvWasPath
    $env:CHATQ_CODEX = $cvWasCodex
    $env:CHATQ_CLAUDE = $cvWasClaude
    $script:ChatClaudeHome = $cvWasClHome
    Remove-Item env:FAKE_VERSION -EA SilentlyContinue
    $script:ChatqExtHomeSeam = $null
    $script:ChatqCliVersions = $cvCache
}
