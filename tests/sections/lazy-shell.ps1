# tests/sections/lazy-shell.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'a profile''s lazy load'
# A profile's load takes shell.ps1 alone and the tool on first use
# (Enter-ChatShell, Import-ChatTool). Each check runs in a fresh process of
# its own - the load it proves is that process's first - with the
# sandbox's environment but for the five names that keep a load whole, a
# $PROFILE naming a profile beside a copy of the tool, and that copy's own
# data/, the overlay's start off unless a check says otherwise.
$lzExe = (Get-Process -Id $PID).Path
$lzOff = '{"overlay":{"autoStart":false}}'
function New-LzCopy([string]$Name, $Config = $lzOff) {
    $d = Join-Path $sb "lazy-$Name"
    $null = New-Item -ItemType Directory -Path (Join-Path $d 'data') -Force
    Copy-Item -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1') -Destination $d -Force
    Copy-Item -LiteralPath (Join-Path $sb 'tool\src') -Destination $d -Recurse -Force
    if ($null -ne $Config) { [System.IO.File]::WriteAllText((Join-Path $d 'data\config.json'), $Config, $utf8) }
    [System.IO.File]::WriteAllText((Join-Path $d 'profile.ps1'), ". '$(Join-Path $d 'Charlie-and-the-chat-factory.ps1')'", $utf8)
    $d
}
# The child's script in a file it dot-sources, so it runs in the global
# scope a profile runs in; what it reports comes back as LZ<tab>key<tab>value
# lines, everything it printed in All.
function Invoke-Lz([string]$Dir, [string]$Body) {
    $ErrorActionPreference = 'Continue'
    $f = Join-Path $Dir 'child.ps1'
    $text = @"
`$ErrorActionPreference = 'Continue'
foreach (`$lzN in 'CHATQ_WATCHER', 'CHATQ_ALLPARTS', 'CHATQ_OVERLAY', 'CHATQ_ROLE', 'CLAUDECODE') { [Environment]::SetEnvironmentVariable(`$lzN, `$null) }
`$PROFILE = '$(Join-Path $Dir 'profile.ps1')'
`$lzTool = '$(Join-Path $Dir 'Charlie-and-the-chat-factory.ps1')'
function Out-Lz([string]`$K, `$V) { Write-Output ('LZ' + [char]9 + `$K + [char]9 + `$V) }
`$lzHas = { param(`$n) `$ExecutionContext.InvokeProvider.Item.Exists("function:\`$n") }
`$lzState = { '{0}|{1}|{2}' -f [bool]`$ExecutionContext.SessionState.PSVariable.GetValue('global:ChatShellLazy'), (& `$lzHas Get-ChatqJobs), (& `$lzHas Invoke-ChatTabKey) }
`$lzErrors = { (@(`$Error | ForEach-Object { "`$_" }) | Sort-Object -Unique) -join ' // ' }
`$lzKeys = { (@(Get-PSReadLineKeyHandler -Bound | Where-Object { `$_.Key -in 'Tab', 'Shift+Tab', 'UpArrow', 'DownArrow', 'Enter' } | ForEach-Object { "`$(`$_.Key)=`$(`$_.Function)" }) | Sort-Object) -join ',' }
`$lzTab = { param(`$s) (@((TabExpansion2 -inputScript `$s -cursorColumn `$s.Length).CompletionMatches | ForEach-Object { `$_.CompletionText })) -join '|' }
$Body
"@
    [System.IO.File]::WriteAllText($f, $text, [System.Text.UTF8Encoding]::new($true))
    $all = @(& $lzExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$f'" 2>&1 | ForEach-Object { "$_" })
    $r = @{ All = $all }
    foreach ($l in $all) { if ($l.StartsWith("LZ`t")) { $k, $v = $l.Substring(3) -split "`t", 2; $r[$k] = $v } }
    $r
}
function Get-LzDetail($R) { ($R.All | Where-Object { $_ }) -join ' / ' }

# the list the stand-ins are made from is every command a person types
$lzTyped = @(foreach ($lzF in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1') + @(Get-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1'))) {
        [regex]::Matches([System.IO.File]::ReadAllText($lzF.FullName, $utf8), '(?m)^function (chat[a-z]*|charlie)\b') | ForEach-Object { $_.Groups[1].Value }
    }) | Sort-Object -Unique
$lzListed = @($script:ChatShellCommands) | Sort-Object -Unique
Check 'a lazy shell has a stand-in for every chat* command and charlie in src/, and for nothing else' (
    ($lzTyped -join ',') -eq ($lzListed -join ',')) "src: $($lzTyped -join ',') / listed: $($lzListed -join ',')"

if (-not [Environment]::UserInteractive) {
    # no lazy load where nobody types: the profile's load is the whole tool
    $lzNi = Invoke-Lz (New-LzCopy 'ni') '. $PROFILE; Out-Lz state (& $lzState)'
    Check 'not interactive here: a profile''s load is the whole tool, as before' ($lzNi.state -eq 'False|True|True') (Get-LzDetail $lzNi)
}
else {
    $lzMain = Invoke-Lz (New-LzCopy 'main') (@'
Set-Location -LiteralPath '@PROJA@'
$lzW = [Diagnostics.Stopwatch]::StartNew()
. $PROFILE
Out-Lz loadMs $lzW.ElapsedMilliseconds
Out-Lz state (& $lzState)
Out-Lz stubs (@($ChatShellCommands | Where-Object { (Get-Command $_ -CommandType Function -EA SilentlyContinue).Definition -match ("Invoke-ChatShellStub '" + $_ + "' ") }).Count)
$lzAl = @([regex]::Matches(${function:Set-ChatShellAliases}.ToString(), '(?m)^\s*Set-Alias -Name (\S+) -Value (\S+)') | ForEach-Object { $_.Groups[1].Value + '=' + $_.Groups[2].Value })
Out-Lz aliasLines ($lzAl -join ',')
Out-Lz aliases (@(foreach ($a in $lzAl) { $n = ($a -split '=')[0]; $n + '=' + (Get-Alias -Name $n -Scope Global -EA SilentlyContinue).Definition }) -join ',')
Out-Lz getCommand ('{0}|{1}' -f (Get-Command chatrm).CommandType, (Get-Command Remove-Chat).ResolvedCommand.Name)
Out-Lz helpBefore (Get-Help chatrm).Synopsis
Out-Lz keysBefore (& $lzKeys)
Out-Lz arrowsBefore ((@($ChatArrowWas.Keys | ForEach-Object { "$_=$($ChatArrowWas[$_])" }) | Sort-Object) -join ',')
$lzCases = @('Tab', 'chatrm Par'), @('Tab', '  chatq -New .'), @('Tab', 'Remove-Chat x'), @('Tab', 'chatqnotify -Test'), @('Tab', 'chatrmx'), @('Tab', 'git status'), @('Tab', 'chatrm'),
    @('Enter', 'chatfind x'), @('Enter', 'chatfind'), @('Enter', 'git status'), @('ShiftTab', 'chatrm x'), @('UpArrow', 'chatrm x'), @('DownArrow', 'chatrm x')
Out-Lz keyActions (@($lzCases | ForEach-Object { Get-ChatShellKeyAction $_[0] $_[1] }) -join ',')
$lzHome = $ChatClaudeHome
$lzPaths = Get-ChatShellPaths
Out-Lz paramBefore (& $lzTab 'chatrm -Pro')
Out-Lz stillLazy (& $lzState)
$lzW.Restart()
Out-Lz tabBefore (& $lzTab 'chatrm Par')
Out-Lz firstLoadMs $lzW.ElapsedMilliseconds
Out-Lz afterTab ('{0}|{1}' -f (& $lzState), (Test-ChatShellStub))
Out-Lz tabAfter (& $lzTab 'chatrm Par')
Out-Lz paramAfter (& $lzTab 'chatrm -Pro')
Out-Lz paths (@(($lzPaths.Queue -eq $ChatqQueueDir), ($lzPaths.WatcherLock -eq $ChatqLockPath), ($lzPaths.Config -eq $ChatqConfigPath), ($lzPaths.Replies -eq $ChatqReplyPath),
    ($lzPaths.OverlayLock -eq $ChatOverlayLockPath), ($lzPaths.OverlayState -eq $ChatOverlayStatePath), ($lzPaths.Tomb -eq $ChatTombPath), ($lzHome -eq $ChatClaudeHome),
    ($ChatRoot -eq (Split-Path -Parent $lzTool))) -join ',')
Out-Lz helpAfter (Get-Help chatrm).Synopsis
Out-Lz keysAfter (& $lzKeys)
Out-Lz arrowsAfter ((@($ChatArrowWas.Keys | ForEach-Object { "$_=$($ChatArrowWas[$_])" }) | Sort-Object) -join ',')
Out-Lz handlers (@(Get-Command Invoke-ChatTabKey, Invoke-ChatShiftTabKey, Invoke-ChatUpArrowKey, Invoke-ChatDownArrowKey, Invoke-ChatEnterKey -EA SilentlyContinue).Count)
$ChatCycle = 'kept'
$lzR = Import-ChatTool
$null = chatqlist *>&1
Out-Lz once ('{0}|{1}' -f $lzR, $ChatCycle)
Out-Lz errors (& $lzErrors)
'@).Replace('@PROJA@', $projA)

    # the same copy loaded whole, the way a dot-source at the prompt loads it
    $lzEagerDir = New-LzCopy 'eager'
    $lzEager = Invoke-Lz $lzEagerDir (@'
Set-Location -LiteralPath '@PROJA@'
$lzW = [Diagnostics.Stopwatch]::StartNew()
. $lzTool
Out-Lz loadMs $lzW.ElapsedMilliseconds
Out-Lz state (& $lzState)
Out-Lz helpAfter (Get-Help chatrm).Synopsis
Out-Lz keysAfter (& $lzKeys)
Out-Lz tabAfter (& $lzTab 'chatrm Par')
Out-Lz paramAfter (& $lzTab 'chatrm -Pro')
Out-Lz whatIf (@(chatq -New . -Prompt 'lazy check' -WhatIf *>&1 | ForEach-Object { "$_" }) -join ' / ')
Out-Lz find ((@(chatfind card | ForEach-Object { $_.Id }) | Sort-Object) -join ',')
Out-Lz errors (& $lzErrors)
'@).Replace('@PROJA@', $projA)

    Check 'a profile''s load defines the stand-ins, the aliases and the key handlers, and not the tool' (
        $lzMain.state -eq 'True|False|False' -and $lzMain.stubs -eq "$(@($script:ChatShellCommands).Count)" -and
        $lzMain.aliasLines -and ($lzMain.aliasLines -split ',').Count -eq 6 -and $lzMain.aliases -eq $lzMain.aliasLines -and $lzMain.aliases -like '*Find-Chat=chatfind*' -and
        $lzMain.keysBefore -eq $lzEager.keysAfter -and $lzMain.keysBefore -like '*Tab=ChatCycleNext*') (Get-LzDetail $lzMain)
    Check 'before the load Get-Command finds each stand-in and its alias, and Get-Help says the tool loads on first use; after it, the help is the tool''s own' (
        $lzMain.getCommand -eq 'Function|chatrm' -and $lzMain.helpBefore -like '*loads the first time*' -and
        $lzMain.helpAfter -eq $lzEager.helpAfter -and $lzMain.helpAfter -notlike '*loads the first time*') "$($lzMain.getCommand) / $($lzMain.helpBefore) / $($lzMain.helpAfter) / $($lzEager.helpAfter)"
    Check 'before the load Tab or Enter on a chat command''s line loads it; every other key and line does what it would with nothing cycling' (
        $lzMain.keyActions -eq 'load,load,load,load,TabCompleteNext,TabCompleteNext,TabCompleteNext,load,AcceptLine,AcceptLine,TabCompletePrevious,PreviousHistory,NextHistory') $lzMain.keyActions
    Check 'Tab on an argument loads the tool and completes as the whole tool does, before the load and after it' (
        $lzMain.stillLazy -eq 'True|False|False' -and $lzMain.tabBefore -and $lzMain.tabBefore -eq $lzEager.tabAfter -and $lzMain.tabAfter -eq $lzEager.tabAfter -and
        $lzMain.afterTab -eq 'False|True|True|False') "$($lzMain.tabBefore) / $($lzMain.tabAfter) / $($lzEager.tabAfter) / $($lzMain.afterTab)"
    # a parameter's name is PowerShell's to complete, never a completer's:
    # before the load only Tab's own key handler loads the tool for it
    Check 'after the load a parameter''s name completes as the whole tool''s does' (
        $lzMain.paramAfter -and $lzMain.paramAfter -eq $lzEager.paramAfter) "$($lzMain.paramBefore) / $($lzMain.paramAfter) / $($lzEager.paramAfter)"
    Check 'the files a lazy shell reads before the load are the tool''s own, and the ghost watch''s home and tombstones too' (
        $lzMain.paths -eq 'True,True,True,True,True,True,True,True,True') $lzMain.paths
    Check 'the load keeps the key handlers bound, and the arrows'' old bindings, and the tool''s own handlers take the keys' (
        $lzMain.keysAfter -eq $lzMain.keysBefore -and $lzMain.arrowsAfter -eq $lzMain.arrowsBefore -and $lzMain.arrowsBefore -like '*UpArrow=*' -and $lzMain.handlers -eq '5') "$($lzMain.keysAfter) / $($lzMain.arrowsBefore) / $($lzMain.arrowsAfter) / $($lzMain.handlers)"
    Check 'the tool loads once: a command after the load, or a second ask, loads nothing again' ($lzMain.once -eq 'True|kept') $lzMain.once

    # chatq resolves . against where the shell is, and chatfind looks in the
    # project the shell is in: run first, each loading the tool, both see
    # what they would loaded whole
    $lzCwd = Invoke-Lz (New-LzCopy 'cwd') (@'
Set-Location -LiteralPath '@PROJA@'
. $PROFILE
Out-Lz before (& $lzState)
Out-Lz whatIf (@(chatq -New . -Prompt 'lazy check' -WhatIf *>&1 | ForEach-Object { "$_" }) -join ' / ')
Out-Lz after (& $lzState)
Out-Lz loc (Get-Location).Path
Out-Lz find ((@(chatfind card | ForEach-Object { $_.Id }) | Sort-Object) -join ',')
Out-Lz errors (& $lzErrors)
'@).Replace('@PROJA@', $projA)
    Check 'a stand-in run first loads the tool where the shell is: chatq -New . and chatfind see what they would loaded whole' (
        $lzCwd.before -eq 'True|False|False' -and $lzCwd.after -eq 'False|True|True' -and $lzCwd.loc -eq $projA -and
        $lzCwd.whatIf -and $lzCwd.whatIf -eq $lzEager.whatIf -and $lzCwd.find -and $lzCwd.find -eq $lzEager.find) (Get-LzDetail $lzCwd)

    # a stand-in's own text, made to stand in for an echo: positional,
    # switch, named and piped input reach the command as typed
    $lzFwd = Invoke-Lz (New-LzCopy 'fwd') @'
. $PROFILE
$lzArrows = $ChatArrowWas
. $PROFILE
Out-Lz again ('{0}|{1}|{2}' -f (& $lzState), (Test-ChatShellStub), [object]::ReferenceEquals($lzArrows, $ChatArrowWas))
Out-Lz keysAgain (& $lzKeys)
function global:lzTarget {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$A, [switch]$S, [string]$Name, [Parameter(ValueFromPipeline)]$In)
    begin { $got = @() }
    process { if ($null -ne $In) { $got += $In } }
    end { "A=$A S=$S Name=$Name In=$($got -join '+') Bound=$((@($PSBoundParameters.Keys) | Sort-Object) -join '+')" }
}
$lzText = ${function:chatq}.ToString().Replace("'chatq'", "'lzTarget'")
Set-Item -Path function:global:lzStub -Value ([scriptblock]::Create($lzText))
Out-Lz piped (1, 2 | lzStub pos -S -Name nm)
Out-Lz loaded (& $lzState)
Out-Lz plain (lzStub -Name 'a b' second)
Out-Lz none (lzStub)
Out-Lz colon (lzStub -S:$false x)
# before the reload: a second whole load is today's, $Error and all
Out-Lz errors (& $lzErrors)
# a -Name: beside a plain switch, a common parameter or an array, and a
# quoted '-S:' that is a value: each as the command itself takes it
$lzMix = '-Name:nm -S', '-Name:nm -Verbose', '-Verbose -A:1,2', '-A:1,2', '-Name:nm -A:(1,2)', '-A:(1,2) -S', '-S:$true',
"-Name:'-S:' x", "'-S:'", '-Verbose:$false -Name:q x -S'
$lzDiff = @(foreach ($c in $lzMix) {
        $d = try { (& ([scriptblock]::Create("lzTarget $c"))) -join ' ' } catch { "ERR $($_.Exception.Message)" }
        $s = try { (& ([scriptblock]::Create("lzStub $c"))) -join ' ' } catch { "ERR $($_.Exception.Message)" }
        if ($d -ne $s) { "[$c] $d <> $s" }
    })
Out-Lz mix ('{0}|{1}' -f $lzMix.Count, ($lzDiff -join ' // '))
. $PROFILE
Out-Lz reload (& $lzState)
'@
    Check 'a second dot-source of the profile before the load puts the stand-ins back and leaves the keys and the arrows as they were' (
        $lzFwd.again -eq 'True|False|False|True|True' -and $lzFwd.keysAgain -eq $lzMain.keysBefore) "$($lzFwd.again) / $($lzFwd.keysAgain)"
    Check 'a stand-in loads the tool, then hands the command its positional, switch, named and piped input as typed' (
        $lzFwd.piped -eq 'A=pos S=True Name=nm In=1+2 Bound=A+In+Name+S' -and $lzFwd.loaded -eq 'False|True|True' -and
        $lzFwd.plain -eq 'A=second S=False Name=a b In= Bound=A+Name' -and $lzFwd.none -eq 'A= S=False Name= In= Bound=' -and
        $lzFwd.colon -eq 'A=x S=False Name= In= Bound=A+S') "$($lzFwd.piped) / $($lzFwd.plain) / $($lzFwd.none) / $($lzFwd.colon) / $($lzFwd.loaded)"
    Check 'a stand-in hands on a -Name:value beside a plain switch, a common parameter or an array, and a quoted ''-S:'', as the command itself takes them' (
        $lzFwd.mix -eq '10|') $lzFwd.mix

    # a load that stops part way - a part that throws, after chatq's but
    # before charlie's - leaves charlie a stand-in, which says so once
    $lzBrokenDir = New-LzCopy 'broken'
    $lzOv = Join-Path $lzBrokenDir 'src\overlay.ps1'
    [System.IO.File]::WriteAllText($lzOv, "throw 'lz broken part'`n" + [System.IO.File]::ReadAllText($lzOv, $utf8), $utf8)
    $lzBroken = Invoke-Lz $lzBrokenDir @'
. $PROFILE
Out-Lz first (@(chatqlist *>&1 | ForEach-Object { "$_" }) -join ' / ')
Out-Lz after (& $lzState)
Out-Lz charlie (@(try { charlie *>&1 | ForEach-Object { "$_" } } catch { "ERR $($_.Exception.Message)" }) -join ' / ')
'@
    Check 'a load that stops part way says so, and a command it did not reach says it did not load rather than calling itself' (
        $lzBroken.first -like '*did not load*lz broken part*' -and $lzBroken.after -eq 'False|True|True' -and
        $lzBroken.charlie -like '*did not load charlie*' -and $lzBroken.charlie -notlike '*ERR*') (Get-LzDetail $lzBroken)
    Check 'the profile dot-sourced again once the tool is loaded reloads it whole, as before' ($lzFwd.reload -eq 'False|True|True') $lzFwd.reload
    # Each lookup that misses files itself in $Error, even told to be
    # silent; a lazy shell files none a whole load does not
    $lzEagerErr = @($lzEager.errors -split ' // ')
    $lzExtra = @(@($lzMain.errors -split ' // ') + @($lzFwd.errors -split ' // ') + @($lzCwd.errors -split ' // ') | Where-Object { $_ -and $_ -notin $lzEagerErr } | Sort-Object -Unique)
    Check 'a lazy shell''s load and first use leave nothing in $Error that a whole load does not' (-not $lzExtra.Count) "$($lzExtra -join ' // ') / whole: $($lzEager.errors)"

    # a profile that turns StrictMode on before the dot-source
    $lzStrict = Invoke-Lz (New-LzCopy 'strict') @'
Set-StrictMode -Version Latest
. $PROFILE
Out-Lz before (& $lzState)
$null = chatqlist *>&1
Out-Lz after (& $lzState)
'@
    Check 'under StrictMode the profile''s load is lazy, and the first command loads the tool' (
        $lzStrict.before -eq 'True|False|False' -and $lzStrict.after -eq 'False|True|True') (Get-LzDetail $lzStrict)

    # every other load is the whole tool, as it was: the five names, and a
    # dot-source that is not a profile's (the eager child above, the same
    # way: $lzEager.state)
    $lzEnv = @(foreach ($lzSet in "`$env:CHATQ_WATCHER = '1'", "`$env:CHATQ_OVERLAY = '1'", "`$env:CHATQ_ALLPARTS = '1'", "`$env:CLAUDECODE = '1'", "`$env:CHATQ_ROLE = 'permit'") {
            $lzE = Invoke-Lz $lzEagerDir "$lzSet`n. `$PROFILE`nOut-Lz state (& `$lzState)"
            "$($lzSet -replace '^\$env:(\w+).*$', '$1')=$(($lzE.state -split '\|')[0..1] -join '|')"
        })
    Check 'a profile''s load with CHATQ_WATCHER, CHATQ_OVERLAY, CHATQ_ALLPARTS, CLAUDECODE or CHATQ_ROLE set, or a dot-source at the prompt, loads the whole tool' (
        ($lzEnv -join ',') -eq 'CHATQ_WATCHER=False|True,CHATQ_OVERLAY=False|True,CHATQ_ALLPARTS=False|True,CLAUDECODE=False|True,CHATQ_ROLE=False|True' -and
        $lzEager.state -eq 'False|True|True') "$($lzEnv -join ',') / $($lzEager.state)"

    # The duties a shell's start runs (Start-ChatShellDuties), each against
    # the cheap gate a lazy shell asks first (Test-ChatShellDuty): the tool
    # loaded whole, the watcher's and the overlay's launches caught in their
    # seams - the watcher's takes its lock, as a real one does - and each
    # case's files written fresh. The gate may say yes where nothing acts
    # (one load too many); never no where something does.
    $lzGateDir = New-LzCopy 'gate' $null
    $lzGate = Invoke-Lz $lzGateDir @'
$env:CHATQ_WATCHER = '1'
. $lzTool
[Environment]::SetEnvironmentVariable('CHATQ_WATCHER', $null)
Set-StrictMode -Off
$global:lzP = Get-ChatShellPaths
$global:lzHold = @()
$global:lzDid = @()
$script:ChatqSpawn = { $global:lzDid += 'watcher'; $global:lzHold += [System.IO.File]::Open($global:lzP.WatcherLock, 'OpenOrCreate', 'ReadWrite', 'None'); $true }
$script:ChatOverlaySpawn = { $global:lzDid += 'overlay'; $true }
$lzOff = '{"overlay":{"autoStart":false}'
$lzReply = { param($r) $lzOff + ',"reply":' + $r + '}' }
$lzSoon = [datetime]::UtcNow.AddHours(1).ToString('o')
$lzGone = [datetime]::UtcNow.AddHours(-1).ToString('o')
$lzAlways = '{"on":true,"topic":"lz-topic","key":"lz-key","listen":"always"}'
$lzAlerts = '{"on":true,"topic":"lz-topic","key":"lz-key","listen":"alerts"}'
# this sign-in, as a close by hand keeps it; none where it cannot be told
$lzSignIn = Get-ChatqSignInAt
Out-Lz signIn ([bool]$lzSignIn)
$lzCases = @(
    @{ N = 'nothing'; C = $lzOff + '}' }
    @{ N = 'queued'; C = $lzOff + '}'; J = 'queued' }
    @{ N = 'queued-watched'; C = $lzOff + '}'; J = 'queued'; W = 1 }
    @{ N = 'done'; C = $lzOff + '}'; J = 'done' }
    @{ N = 'always'; C = (& $lzReply $lzAlways) }
    @{ N = 'always-standing'; C = (& $lzReply $lzAlways); R = '{"standing":true}' }
    @{ N = 'always-standing-watched'; C = (& $lzReply $lzAlways); R = '{"standing":true}'; W = 1 }
    @{ N = 'reply-open'; C = (& $lzReply $lzAlerts); R = '{"openUntil":"' + $lzSoon + '"}' }
    @{ N = 'reply-open-watched'; C = (& $lzReply $lzAlerts); R = '{"openUntil":"' + $lzSoon + '"}'; W = 1 }
    @{ N = 'reply-closed'; C = (& $lzReply $lzAlerts); R = '{"openUntil":"' + $lzGone + '"}' }
    @{ N = 'reply-pairing'; C = (& $lzReply ('{"on":true,"topic":"lz-topic","pairing":{"expires":"' + $lzSoon + '"}}')); R = '{"openUntil":"' + $lzSoon + '"}' }
    @{ N = 'reply-unpaired'; C = (& $lzReply '{"on":true,"topic":"lz-topic"}'); R = '{"openUntil":"' + $lzSoon + '"}' }
    @{ N = 'reply-off'; C = (& $lzReply '{"on":false,"topic":"lz-topic","key":"lz-key","listen":"always"}') }
    @{ N = 'overlay-on'; C = '{"overlay":{"autoStart":true}}' }
    @{ N = 'overlay-unsaid'; C = '{}' }
    @{ N = 'no-config' }
    @{ N = 'overlay-running'; C = '{"overlay":{"autoStart":true}}'; O = 1 }
    @{ N = 'overlay-closed'; C = '{"overlay":{"autoStart":true}}'; S = '{"closedSignIn":' + $(if ($lzSignIn) { $lzSignIn } else { 'null' }) + '}' }
    @{ N = 'overlay-closed-before'; C = '{"overlay":{"autoStart":true}}'; S = '{"closedSignIn":1}' }
    @{ N = 'overlay-state-unreadable'; C = '{"overlay":{"autoStart":true}}'; S = 'not json {' }
    @{ N = 'config-unreadable'; C = 'not json {' }
)
foreach ($c in $lzCases) {
    foreach ($h in $global:lzHold) { $h.Dispose() }
    $global:lzHold = @()
    foreach ($f in $lzP.Config, $lzP.Replies, $lzP.WatcherLock, $lzP.OverlayLock, $lzP.OverlayState) { [System.IO.File]::Delete($f) }
    if ([System.IO.Directory]::Exists($lzP.Queue)) { [System.IO.Directory]::Delete($lzP.Queue, $true) }
    if ($c.C) { [System.IO.File]::WriteAllText($lzP.Config, $c.C) }
    if ($c.R) { [System.IO.File]::WriteAllText($lzP.Replies, $c.R) }
    if ($c.S) { [System.IO.File]::WriteAllText($lzP.OverlayState, $c.S) }
    if ($c.J) {
        [void][System.IO.Directory]::CreateDirectory($lzP.Queue)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($lzP.Queue, 'lz1.json'), '{"id":"lz1","seq":1,"state":"' + $c.J + '","title":"lz","createdAt":"' + [datetime]::UtcNow.ToString('o') + '"}')
    }
    if ($c.W) { $global:lzHold += [System.IO.File]::Open($lzP.WatcherLock, 'OpenOrCreate', 'ReadWrite', 'None') }
    if ($c.O) { $global:lzHold += [System.IO.File]::Open($lzP.OverlayLock, 'OpenOrCreate', 'ReadWrite', 'None') }
    $gate = Test-ChatShellDuty
    $was = if ([System.IO.File]::Exists($lzP.Replies)) { [System.IO.File]::ReadAllText($lzP.Replies) } else { $null }
    $global:lzDid = @()
    $null = Start-ChatShellDuties *>&1
    $now = if ([System.IO.File]::Exists($lzP.Replies)) { [System.IO.File]::ReadAllText($lzP.Replies) } else { $null }
    if ($now -ne $was) { $global:lzDid += 'standing' }
    Out-Lz $c.N ('{0}|{1}' -f $gate, ((@($global:lzDid) | Sort-Object -Unique) -join '+'))
}
foreach ($h in $global:lzHold) { $h.Dispose() }
'@
    # what each case is expected to start, and so the gate's answer: yes
    # wherever something starts, and where the files cannot say - an
    # unpaired phone with an alert out, a config that will not read - yes
    # with nothing started. A close by hand this sign-in holds the overlay
    # back, one from a sign-in before does not, and neither where this
    # sign-in cannot be told.
    $lzWant = [ordered]@{
        'nothing' = 'False|'; 'queued' = 'True|watcher'; 'queued-watched' = 'False|'; 'done' = 'False|'
        'always' = 'True|standing+watcher'; 'always-standing' = 'True|watcher'; 'always-standing-watched' = 'False|'
        'reply-open' = 'True|watcher'; 'reply-open-watched' = 'False|'; 'reply-closed' = 'False|'; 'reply-pairing' = 'True|watcher'
        'reply-unpaired' = 'True|'; 'reply-off' = 'False|'
        'overlay-on' = 'True|overlay'; 'overlay-unsaid' = 'True|overlay'; 'no-config' = 'True|overlay'; 'overlay-running' = 'False|'
        'overlay-closed' = $(if ($lzGate.signIn -eq 'True') { 'False|' } else { 'True|overlay' }); 'overlay-closed-before' = 'True|overlay'
        'overlay-state-unreadable' = 'True|overlay'; 'config-unreadable' = 'True|'
    }
    $lzGot = @($lzWant.Keys | ForEach-Object { "$_=$($lzGate[$_])" })
    $lzLost = @($lzWant.Keys | Where-Object { $lzGate[$_] -like 'False|?*' })
    Check 'a shell''s start: the gate a lazy shell asks says yes wherever the duties start the watcher, mark the phone''s listening or start the overlay, and no where none would' (
        -not $lzLost.Count -and ($lzGot -join ',') -eq (@($lzWant.Keys | ForEach-Object { "$_=$($lzWant[$_])" }) -join ',')) "lost $($lzLost -join ',') / $($lzGot -join ', ') / $(Get-LzDetail $lzGate)"

    # and in a real profile load: a gate that says yes loads the tool and
    # runs the duties - here marking the phone's listening, the watcher's
    # lock held so none starts - and one that says no leaves it to first use
    $lzDutyDir = New-LzCopy 'duty' '{"overlay":{"autoStart":false},"reply":{"on":true,"topic":"lz-topic","key":"lz-key","listen":"always"}}'
    $lzHeld = [System.IO.File]::Open((Join-Path $lzDutyDir 'data\watcher.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $lzDuty = Invoke-Lz $lzDutyDir '. $PROFILE; Out-Lz state (& $lzState)'
        $lzStanding = Read-TestFile (Join-Path $lzDutyDir 'data\replies.json')
        $lzQuiet = Invoke-Lz $lzDutyDir '. $PROFILE; Out-Lz state (& $lzState)'
        $lzStanding2 = Read-TestFile (Join-Path $lzDutyDir 'data\replies.json')
    }
    finally { $lzHeld.Dispose() }
    Check 'a profile''s load whose gate says yes loads the tool and runs the duties; once they are done, the next shell''s load stays lazy' (
        $lzDuty.state -eq 'False|True|True' -and $lzStanding -match '"standing"\s*:\s*true' -and $lzQuiet.state -eq 'True|False|False' -and $lzStanding2 -eq $lzStanding) "$($lzDuty.state) / $lzStanding / $($lzQuiet.state) / $(Get-LzDetail $lzDuty)"
}
