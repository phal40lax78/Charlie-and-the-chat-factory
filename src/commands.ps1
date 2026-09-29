# claude-codex-chat-manager, src/commands.ps1: dot-sourced by claude-codex-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region commands --------------------------------------------------------------

function New-ChatqSeq {
    # -Jobs: a list already read, as the console has one every pass
    param([object[]]$Jobs)
    if (-not $Jobs) { $Jobs = @(Get-ChatqJobs) }
    $max = 0
    foreach ($j in $Jobs) { if ([int]$j.seq -gt $max) { $max = [int]$j.seq } }
    return $max + 1
}

function ConvertFrom-ChatqWhen {
    # -At 13:00 (today, or tomorrow once that has passed) / -In 90m, 2h, 1d
    param([string]$At, [string]$In)
    if ($In) {
        if ($In -match '^\s*(\d+(?:\.\d+)?)\s*(m|min|h|hr|d)?\s*$') {
            $n = [double]$Matches[1]
            switch -Wildcard ($Matches[2]) {
                'd' { return (Get-Date).AddDays($n) }
                'h*' { return (Get-Date).AddHours($n) }
                default { return (Get-Date).AddMinutes($n) }
            }
        }
        throw "-In '$In': use 90m, 2h or 1d"
    }
    if ($At) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse($At, [ref]$d)) { throw "-At '$At': use a time like 13:00" }
        if ($At -notmatch '\d{4}|/' -and $d -lt (Get-Date)) { $d = $d.AddDays(1) }
        return $d
    }
    return $null
}

function Invoke-ChatqEditor {
    # code --wait first: in VS Code's terminal it opens a tab in this window and
    # returns when the tab is closed. $CHATQ_EDITOR overrides the choice.
    param([string]$Path, [switch]$NoWait)
    $spec = if ($env:CHATQ_EDITOR) { $env:CHATQ_EDITOR }
    elseif (Get-Command code -EA SilentlyContinue) { 'code --wait' }
    elseif ($env:VISUAL) { $env:VISUAL }
    elseif ($env:EDITOR) { $env:EDITOR }
    elseif ($script:ChatqIsWindows) { 'notepad' }
    else { 'nano' }
    $parts = @($spec -split '\s+' | Where-Object { $_ })
    $exe = $parts[0]
    $rest = @($parts | Select-Object -Skip 1)
    if ($NoWait) { $rest = @($rest | Where-Object { $_ -notin '--wait', '-w' }) }
    if ($exe -match '^notepad(\.exe)?$') {
        $p = Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Path`"" -PassThru
        if (-not $NoWait) { $p.WaitForExit() }
        return
    }
    & $exe @rest $Path
}

function Get-ChatqJobInfo {
    # what the run needs to know about the chat: where it ran, in which mode
    param($Row)
    if ($Row.Provider -eq 'codex') {
        $m = Get-ChatqCodexMeta $Row.Path
        $sb = if ($m.Sandbox) { $m.Sandbox } else { 'workspace-write' }
        return @{
            Cwd = $m.Cwd; Mode = $sb; Sandbox = $sb; Network = $m.Network; Model = $m.Model; CutOff = $false
            Error = if (-not $m.Cwd) { "can't tell which folder this Codex chat ran in" } else { $null }
        }
    }
    $m = Get-ChatqClaudeMeta $Row.Path $Row.Group
    return @{
        Cwd = $m.Cwd; Mode = if ($m.Mode) { $m.Mode } else { 'default' }; Model = $m.Model
        CutOff = [bool]($m.LastTurn -and ($m.LastTurn.Limit -or $m.LastTurn.Overloaded)); Sandbox = $null; Network = $false
        Error = if (-not $m.Exists) { 'that chat''s transcript is gone' }
        elseif (-not $m.Cwd) { "can't tell which folder this chat ran in - its recorded folder no longer exists" }
        else { $null }
    }
}

function Write-ChatqJobInfo {
    param($Info, [string]$Mode, [switch]$Continue, [string]$Provider)
    $m = if ($Mode) { $Mode } else { $Info.Mode }
    $src = if ($Mode) { 'given' } else { 'as the chat last ran' }
    Write-Host "     $m ($src) $($script:ChatqDot) $($Info.Cwd)" -ForegroundColor DarkGray
    if ($Provider -eq 'claude') {
        switch ($m) {
            'plan' { Write-Host '     plan mode: it will stop at a plan - -Mode auto lets it act' -ForegroundColor Yellow }
            'bypassPermissions' { Write-Host '     bypassPermissions: it runs everything without asking' -ForegroundColor Yellow }
            { $_ -in 'default', 'manual' } {
                Write-Host '     anything that would ask is denied unattended - -Mode auto or acceptEdits lets it edit' -ForegroundColor DarkGray
            }
        }
    }
    if ($Continue -and -not $Info.CutOff) {
        Write-Host '     this chat was not cut off by the limit or a 529 - "continue" is sent anyway' -ForegroundColor Yellow
    }
    if ($env:ANTHROPIC_API_KEY -and $Provider -eq 'claude') {
        Write-Host '     ANTHROPIC_API_KEY is set here - chatq leaves it out, so runs use your subscription' -ForegroundColor DarkGray
    }
}

#region the job core ------------------------------------------------------------
# What chatq, chatqrm, chatqrun and chatqlog do to jobs, apart from what they
# print: the overlay's console does the same things from a window, where
# there is no console to print to and no editor to wait on. Nothing here
# writes to the host or starts the watcher.

function New-ChatqJobSlot {
    # A new job's number, id and file names. An id is the time to the second
    # and the chat's first four hex digits; one already taken - two jobs for
    # one chat inside a second, which the console can make - gets -2, -3.
    param($Row, [string]$Title, [object[]]$Jobs)
    New-ChatqDir $script:ChatqQueueDir
    $seq = New-ChatqSeq -Jobs $Jobs
    $name = if ($Title) { $Title } else { [string]$Row.Title }
    $hex = if ($Row.Id) { ([string]$Row.Id).Substring(0, [Math]::Min(4, ([string]$Row.Id).Length)) } else { [guid]::NewGuid().ToString('N').Substring(0, 4) }
    $base = '{0}-{1}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $hex
    $id = $base
    for ($n = 2; (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$id.json")) -or (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir $id)); $n++) { $id = "$base-$n" }
    # no run of dashes survives into the comment, so no title can close it early
    $safe = $name -replace '-{2,}', '-'
    $file = "#$seq $(Get-ChatqSafeName $name).md"
    [pscustomobject]@{
        Seq = $seq; Id = $id; File = $file; Path = (Join-Path $script:ChatqQueueDir $file); Dir = (Join-Path $script:ChatqQueueDir $id)
        Header = "<!-- chatq: prompt for '$safe' ($($Row.Provider)). Everything after this comment is sent as it is when the limit resets. Save and close the tab to queue it; leave it empty to cancel. -->`n`n"
    }
}

function New-ChatqJobRecord {
    # The job as data/queue/<id>.json holds it. Pure: nothing is written.
    # -Resolve: how Resolve-ChatqTarget picked the chat, when it did.
    # -JobHome: the config dir the chat lives under, when the caller knows it
    # better than this process's environment does - $null for the default
    # one. Left out, the environment's is taken.
    param($Slot, $Row, $Info, [string]$Kind = 'prompt', [string]$Mode, [string]$Model, $NotBefore,
        [switch]$First, [switch]$SendNow, [string]$Typed, $Resolve, [string]$Rule, [string]$Title, $JobHome)
    $jobHomeGiven = $PSBoundParameters.ContainsKey('JobHome')
    [pscustomobject][ordered]@{
        v = 1
        # set before the prompt, when the files went in - the chat a re-pick
        # lands on does not rename the folder they are in
        id = $Slot.Id
        seq = $Slot.Seq
        provider = $Row.Provider
        sessionId = $(if ($Row.Id) { $Row.Id } else { $null })
        title = $(if ($Title) { $Title } else { $Row.Title })
        group = $Row.Group
        path = $(if ($Row.Path) { $Row.Path } else { $null })
        cwd = $Info.Cwd
        # only when the user set one: pointing CLAUDE_CONFIG_DIR at the default
        # makes Claude look for .claude.json inside it, where it never lives
        home = if ($jobHomeGiven) { if ($JobHome) { [string]$JobHome } else { $null } }
        elseif ($Row.Provider -eq 'codex') { $env:CODEX_HOME } else { $env:CLAUDE_CONFIG_DIR }
        chatWhen = $Row.When
        typed = $(if ($Typed) { $Typed } else { $null })
        rule = $(if ($Resolve) { $Resolve.Rule } elseif ($Rule) { $Rule } else { $null })
        score = $(if ($Resolve) { $Resolve.Score } else { $null })
        runnerUp = if ($Resolve -and $Resolve.RunnerUp) { $Resolve.RunnerUp.Title } else { $null }
        kind = $Kind
        promptFile = $Slot.File
        mode = if ($Mode) { $Mode } else { $null }
        modeAtQueue = $Info.Mode
        # the chat's own model - what the probe asks with - and, apart from it,
        # the one -Model asked this run to use
        model = $Info.Model
        runModel = if ($Model) { $Model.Trim() } else { $null }
        first = if ($First) { Get-ChatqStamp } else { $null }
        sandbox = $Info.Sandbox
        network = $Info.Network
        notBefore = if ($NotBefore) { ([datetime]$NotBefore).ToUniversalTime().ToString('o') } else { $null }
        state = 'queued'
        attempts = 0
        retryAs = 'full'
        # set when the watcher itself turned the job into a "continue" (limit or
        # 529 mid-run); only then is it dropped if the chat moved on meanwhile.
        # Not the auto-continue setting, and not what auto means below.
        autoContinue = $false
        # true for the continue auto-continue queued for a chat the limit cut
        # off (src/auto-continue.ps1), with that cut-off's id past its chat -
        # its limit record's uuid (Get-ChatqCutId)
        auto = $false
        cutUuid = $null
        deferUntil = $null
        # why it waits till deferUntil: vscode, auto-continue's hold for a
        # chat open in a VS Code panel; background, a command the chat's own
        # process started (the watcher adds deferSince and deferNote); in-use,
        # its tab in front of you at the handover; unset, a chat that was busy
        deferWhy = $null
        deferredSince = $null
        busyAlerted = $false
        createdAt = Get-ChatqStamp
        startedAt = $null
        endedAt = $null
        runnerPid = $null
        result = $null
        history = @([pscustomobject]@{ at = (Get-ChatqStamp); state = 'queued'; why = 'added' })
        # "send now" from the console: a chat busy in VS Code is looked at
        # again every 30 s rather than every 5 minutes
        sendNow = [bool]$SendNow
    }
}

function Register-ChatqJob {
    # Saved, with what the prompt links to in data/queue - an image pasted in
    # the editor tab - brought into its folder, and a line in jobs.log.
    # Returns the files it has and those it could not take in. -NoLinks: the
    # prompt's links are left as text and bring nothing in - a prompt typed
    # on the phone, where nobody at the PC chose a file.
    # -LogNote: more for the jobs.log line - auto-continue's "auto - limit
    # 12:40, resets 13:00"
    param($Job, [switch]$NoLinks, [string]$LogNote)
    Save-ChatqJob $Job
    $missed = if ($NoLinks) { @() } else { @(Sync-ChatqAttachments $Job) }
    $files = @(Get-ChatqAttachments $Job)
    Write-ChatqJobLog "#$($Job.seq) queued ($($Job.kind)$(if ($LogNote) { ", $LogNote" })$(if ($files) { ", $($files.Count) file$(if ($files.Count -ne 1) { 's' })" })) $($script:ChatqDot) $($Job.title)"
    return [pscustomobject]@{ Files = $files; Missed = $missed }
}

function New-ChatqJob {
    <#
    A job from a chat already picked, a prompt and files, in one call and
    without a word to the host - what chatq does once it knows the chat,
    and what the console does on Send. Returns @{ Error; Code; Job; Files;
    Missed }: Error is the line chatq prints, and nothing is left behind.
    Code: provider, kind, empty, info, copy. The watcher is not started.
    -Sources: what Read-ChatqAttachSources gives, or @{ Files; Images }.
    -MoveSources: those files are the console's staged copies; they move in.
    -Kind new, with -Cwd and no -Row: a brand-new Claude chat in that
    folder. Its session id is chosen now and handed to claude --session-id
    on the first run (spike S25), so its transcript's path is known from the
    start; -Title names it, or the prompt's first line does.
    -JobHome: the chat's config dir, $null for the default one (see
    New-ChatqJobRecord). -NoLinks: the prompt's links pull no files in -
    text from the phone, where nobody at the PC chose a file: every "]("
    in it is written "]\(", which no markdown link reads, so neither the
    first sync nor the watcher's before it sends finds one. A link added
    later at the PC (chatq <n>) works as in any job.
    -Set: fields put on the job before it is saved - auto-continue's auto,
    cutUuid, deferUntil and deferWhy - so no watcher ever reads it without
    them. -LogNote goes on its jobs.log line.
    #>
    param($Row, [string]$Prompt, [ValidateSet('prompt', 'continue', 'new')][string]$Kind = 'prompt', $Info,
        [string]$Mode, [string]$Model, $NotBefore, [switch]$First, [switch]$SendNow, $Sources, [switch]$MoveSources,
        [string]$Typed, $Resolve, [string]$Rule, [string]$Title, [object[]]$Jobs, [string]$Cwd, $JobHome, [switch]$NoLinks,
        [hashtable]$Set, [string]$LogNote)
    $fail = { param($c, $t) [pscustomobject]@{ Error = $t; Code = $c; Job = $null; Files = @(); Missed = @() } }
    if ($Kind -eq 'new') {
        $dir = if ($Cwd) { try { [System.IO.Path]::GetFullPath($Cwd) } catch { $null } } else { $null }
        # C:\ stays C:\ - as a working folder C: is wherever that drive last was
        if ($dir -and $dir -ne [System.IO.Path]::GetPathRoot($dir)) { $dir = $dir.TrimEnd('\', '/') }
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return & $fail 'info' "no such folder: $Cwd" }
        if (-not ([string]$Prompt).Trim()) { return & $fail 'empty' 'empty prompt - nothing queued' }
        $sid = [guid]::NewGuid().ToString()
        $slug = Get-ChatSlug $dir
        if (-not $Title) { $Title = Format-ChatTitle ((Get-ChatqPromptStats $Prompt).First) 60 }
        $Row = [pscustomobject]@{
            Provider = 'claude'; Id = $sid; Title = $Title; Group = $slug; When = $null
            Path = (Join-Path (Join-Path (Join-Path $script:ChatClaudeHome 'projects') $slug) "$sid.jsonl")
        }
        $Info = @{ Cwd = $dir; Mode = 'default'; Model = $null; CutOff = $false; Sandbox = $null; Network = $false; Error = $null }
        if (-not $Rule) { $Rule = 'new' }
    }
    if (-not $Row -or $Row.Provider -notin 'claude', 'codex') {
        return & $fail 'provider' "only a Claude or Codex chat can take a prompt - nothing can resume a $(if ($Row) { $Row.Provider } else { 'missing' }) chat"
    }
    $hasFiles = $Sources -and (@($Sources.Files | Where-Object { $_ }).Count -or $Sources.Image -or ($Sources -is [hashtable] -and @($Sources['Images']).Count))
    if ($Kind -eq 'continue' -and $hasFiles) { return & $fail 'kind' '-Continue sends "continue" and nothing else - give the files with -Prompt instead' }
    if ($Kind -ne 'continue' -and -not ([string]$Prompt).Trim()) { return & $fail 'empty' 'empty prompt - nothing queued' }
    if (-not $Info) { $Info = Get-ChatqJobInfo $Row }
    if ($Info.Error) { return & $fail 'info' $Info.Error }
    $slot = New-ChatqJobSlot $Row $Title $Jobs
    # the files before the prompt: one that cannot be copied stops the job
    # before anything of it is written
    if ($hasFiles) {
        try { $null = Save-ChatqAttachSources $slot.Dir $Sources -Move:$MoveSources }
        catch { return & $fail 'copy' "a file could not be copied - nothing queued: $($_.Exception.Message)" }
    }
    if ($NoLinks -and $Kind -ne 'continue') { $Prompt = ([string]$Prompt).Replace('](', ']\(') }
    Save-ChatqText $slot.Path ($slot.Header + $(if ($Kind -eq 'continue') { $script:ChatqContinueText } else { $Prompt }))
    $homeArg = @{}
    if ($PSBoundParameters.ContainsKey('JobHome')) { $homeArg['JobHome'] = $JobHome }
    $job = New-ChatqJobRecord $slot $Row $Info -Kind $Kind -Mode $Mode -Model $Model -NotBefore $NotBefore -First:$First -SendNow:$SendNow -Typed $Typed -Resolve $Resolve -Rule $Rule -Title $Title @homeArg
    if ($Set) { foreach ($k in @($Set.Keys)) { Set-ChatqProp $job $k $Set[$k] } }
    $reg = Register-ChatqJob $job -NoLinks:$NoLinks -LogNote $LogNote
    return [pscustomobject]@{ Error = $null; Code = $null; Job = $job; Files = $reg.Files; Missed = $reg.Missed }
}

function Get-ChatqRowById {
    <#
    The index's row for a chat known by its id: the console picks chats from
    lists, so nothing fuzzy, and no Sync-ChatIndex on the window's thread.
    A Claude chat not in the index yet - one the limit has just cut off often
    is not - is described from its transcript: -Path, or found by -Cwd and
    id. Hidden (sidechain) chats are not rows.
    #>
    param([string]$Id, [string]$Provider, [string]$Path, [string]$Cwd)
    if (-not $Id) { return $null }
    foreach ($r in @(Get-ChatIndex)) {
        if ($r.Id -and $r.Id -eq $Id -and (-not $Provider -or $r.Provider -eq $Provider)) {
            if ($r.Hidden) { return $null }
            return $r
        }
    }
    if ($Provider -and $Provider -ne 'claude') { return $null }
    $p = if ($Path -and (Test-Path -LiteralPath $Path)) { $Path } else { Find-ChatOverlayTranscript $script:ChatClaudeHome $Cwd $Id }
    if (-not $p) { return $null }
    $f = Get-Item -LiteralPath $p -EA SilentlyContinue
    if (-not $f) { return $null }
    $rec = try { & $script:ChatProviders['claude'].Describe $f } catch { $null }
    if (-not $rec -or $rec.Hidden) { return $null }
    [pscustomobject]@{
        Provider = 'claude'; Path = $f.FullName; Size = $f.Length; Mtime = $f.LastWriteTimeUtc.Ticks
        Id = $rec.Id; Title = $rec.Title; Titled = $rec.TitleSource; Group = $rec.Group; Hidden = $false
        When = $(if ($rec.When) { $rec.When.ToString('o') } else { $null }); First = @($rec.First); Last = @($rec.Last)
    }
}

function Invoke-ChatqContinueChats {
    <#
    "Continue from where you left off." for each chat the limit or a 529
    stopped - one New-ChatqJob each - for the console's Continue all and the
    overlay's reset ask. A chat that already has a job waiting or running is
    left alone and named in Had: a list is redrawn only on the next pass,
    and a second click would queue it twice. -Items: objects with Id, Title,
    Path and Cwd. Returns @{ Queued = the job records; Had = session ids;
    Fails = "title: why" }. The watcher is not asked: a caller does that
    once, when Queued is not empty.
    #>
    param([object[]]$Items)
    $queued = [System.Collections.Generic.List[object]]::new()
    $had = [System.Collections.Generic.List[string]]::new()
    $fails = [System.Collections.Generic.List[string]]::new()
    $taken = @{}
    foreach ($j in @(Get-ChatqJobs)) { if ($j.state -in 'queued', 'running' -and $j.sessionId) { $taken[[string]$j.sessionId] = $true } }
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $id = [string](Get-ChatField $i 'Id')
        $title = [string](Get-ChatField $i 'Title')
        if ($id -and $taken[$id]) { $had.Add($id); continue }
        $row = Get-ChatqRowById $id 'claude' ([string](Get-ChatField $i 'Path')) ([string](Get-ChatField $i 'Cwd'))
        if (-not $row) { $fails.Add("${title}: not found"); continue }
        $made = New-ChatqJob -Row $row -Kind continue -Rule 'continue'
        if ($made.Error) { $fails.Add("${title}: $($made.Error)") }
        else { $queued.Add($made.Job); $taken[$id] = $true }
    }
    return [pscustomobject]@{ Queued = $queued.ToArray(); Had = $had.ToArray(); Fails = $fails.ToArray() }
}

function Remove-ChatqJob {
    # A job and everything it has: its file, prompt, log, and the copies of
    # its files - the originals were never touched - and a run's own
    # settings a watcher that died left (Invoke-ChatqRun). Not a running one.
    param($Job, [string]$By = 'chatqrm')
    if ($Job.state -eq 'running') { return $false }
    foreach ($p in @((Join-Path $script:ChatqQueueDir "$($Job.id).json"), (Get-ChatqPromptPath $Job), (Join-Path $script:ChatqLogDir "$($Job.id).jsonl"),
            (Join-Path $script:ChatqRunSettingsDir "$($Job.id).json"))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
    }
    $ad = Get-ChatqAttachDir $Job
    if (Test-Path -LiteralPath $ad) { Remove-Item -LiteralPath $ad -Recurse -Force -EA SilentlyContinue }
    Write-ChatqJobLog "#$($Job.seq) removed by $By (was $($Job.state)) $($script:ChatqDot) $($Job.title)"
    return $true
}

function Stop-ChatqJobRun {
    # A running job stopped: 'cancelling' - a cancel file its watcher reads
    # within seconds - or 'failed', when no watcher is alive to read one:
    # the job was left running by one that died, and there is nothing to stop.
    # 'not running': it ended before the click, and what it ended with stands.
    param($Job)
    if ($Job.state -ne 'running') { return 'not running' }
    if (Test-ChatqWatcherAlive) {
        Save-ChatqText (Join-Path $script:ChatqQueueDir "$($Job.id).cancel") 'cancel'
        return 'cancelling'
    }
    Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'cancelled - its watcher was already gone' }) 'cancelled'
    return 'failed'
}

function Set-ChatqJobFirst {
    # to the front of its lane: the latest one put first goes ahead
    param($Job)
    Set-ChatqProp $Job 'first' (Get-ChatqStamp)
    Save-ChatqJob $Job
}

function Reset-ChatqJob {
    # A finished job queued again, as chatqrun <n> does. One whose prompt
    # already reached the chat goes as "continue", never the prompt twice.
    # Returns @{ Error; Landed }.
    param($Job, [string]$Mode)
    if ($Job.state -notin 'failed', 'needs-input', 'done', 'skipped') { return [pscustomobject]@{ Error = "#$($Job.seq) is $($Job.state) - nothing to requeue"; Landed = $false } }
    if ($Mode) { Set-ChatqProp $Job 'mode' $Mode }
    $landed = $Job.state -in 'needs-input', 'done' -or $Job.retryAs -eq 'continue' -or
    (Test-ChatqPromptLanded $Job.path ([string](Read-ChatqPrompt $Job)) $Job.startedAt $Job.provider)
    Set-ChatqProp $Job 'retryAs' $(if ($landed) { 'continue' } else { 'full' })
    # asked for by you: sent even if the chat has moved on since
    Set-ChatqProp $Job 'autoContinue' $false
    Set-ChatqProp $Job 'deferUntil' $null
    Set-ChatqProp $Job 'deferredSince' $null
    # asked for by hand: the retry counts start over
    Set-ChatqProp $Job 'retryAt' $null
    Set-ChatqProp $Job 'noProgress' 0
    Set-ChatqProp $Job 'netRetries' 0
    Set-ChatqJobState $Job 'queued' 'requeued'
    return [pscustomobject]@{ Error = $null; Landed = [bool]$landed }
}

function Get-ChatqJobFilesRefusal {
    # why a job can take no more files, or $null
    param($Job)
    if ($Job.state -ne 'queued') { return "#$($Job.seq) is $($Job.state) - files added now would go nowhere" }
    if ($Job.kind -eq 'continue') { return "#$($Job.seq) sends ""continue"" and nothing else - files would go nowhere" }
    return $null
}

function Add-ChatqJobFiles {
    # more files for a job still waiting - the screenshot that was forgotten.
    # Returns @{ Error; Files }.
    param($Job, $Sources, [switch]$Move)
    $no = Get-ChatqJobFilesRefusal $Job
    if ($no) { return [pscustomobject]@{ Error = $no; Files = @() } }
    $new = try { @(Save-ChatqAttachSources (Get-ChatqAttachDir $Job) $Sources -Move:$Move) }
    catch { return [pscustomobject]@{ Error = "a file could not be copied - nothing added: $($_.Exception.Message)"; Files = @() } }
    Write-ChatqJobLog "#$($Job.seq) +$($new.Count) file$(if ($new.Count -ne 1) { 's' }) $($script:ChatqDot) $($Job.title)"
    return [pscustomobject]@{ Error = $null; Files = $new }
}

function Get-ChatqLogEntries {
    <#
    What a run did, from data/logs/<id>.jsonl, as @{ Type; Text } in order:
    init, denied, text (a reply), tool, result, error. -MaxBytes reads only
    the log's tail - a long run's stream runs to megabytes, and the console
    reads it on the window's thread. The user's own lines are skipped: they
    are the prompt, and tool output fed back.
    #>
    param($Job, [int]$MaxBytes = 0)
    $log = Join-Path $script:ChatqLogDir "$($Job.id).jsonl"
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    $lines = if ($MaxBytes -gt 0 -and (Get-Item -LiteralPath $log).Length -gt $MaxBytes) {
        # the first line of a tail is cut in two
        @((Read-ChatqTail $log $MaxBytes) -split "`n" | Select-Object -Skip 1)
    }
    # not File.ReadLines: it shares only Read, and a running job's log is held
    # open for writing
    else { try { @((Read-ChatAllText $log) -split '\r?\n') } catch { @() } }
    $d = $script:ChatqDot
    $out = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $x) $out.Add([pscustomobject]@{ Type = $t; Text = [string]$x }) }
    foreach ($line in $lines) {
        if (-not $line -or $line.Length -gt 1048576) { continue }
        if ($line.StartsWith('{"type":"user"')) { continue }
        $o = try { $line | ConvertFrom-Json } catch { continue }
        switch ($o.type) {
            'system' {
                if ($o.subtype -eq 'init') { & $add 'init' "session $($o.session_id) $d $($o.model) $d $($o.permissionMode) $d Claude Code $($o.claude_code_version)" }
                elseif ($o.subtype -eq 'permission_denied') { & $add 'denied' $o.tool_name }
            }
            'assistant' {
                foreach ($c in @($o.message.content)) {
                    if ($c.type -eq 'text' -and $c.text) { & $add 'text' $c.text }
                    elseif ($c.type -eq 'tool_use') {
                        $arg = if ($c.input.command) { $c.input.command } elseif ($c.input.file_path) { $c.input.file_path } elseif ($c.input.pattern) { $c.input.pattern } else { '' }
                        & $add 'tool' "$($c.name) $(([string]$arg -split "`n")[0])"
                    }
                }
            }
            'result' {
                $t = if ($o.duration_ms) { [TimeSpan]::FromMilliseconds($o.duration_ms).ToString('hh\:mm\:ss') } else { '' }
                & $add 'result' "$($o.subtype) $d $($o.num_turns) turns $d $t"
            }
            'item.completed' {
                if ($o.item.type -eq 'agent_message') { & $add 'text' $o.item.text }
                elseif ($o.item.type -eq 'command_execution') { & $add 'tool' $o.item.command }
            }
            'turn.failed' { & $add 'error' $o.error.message }
            'error' { & $add 'error' $o.message }
        }
    }
    return $out.ToArray()
}

function Request-ChatqWatcher {
    <#
    Start-ChatqWatcher for a window's thread, which it must never put to
    sleep. The wake goes first - 'poke' (look again) or 'now' (stop waiting),
    one write, as Start-ChatqWatcher does - and a process is started only
    when none holds the lock. Whether one came up is for
    Test-ChatqWatcherRequest to say, on a later tick.
    #>
    param([ValidateSet('poke', 'now')][string]$Wake = 'poke')
    $alive = [bool](Test-ChatqWatcherAlive)
    Send-ChatqWake $Wake
    $spawned = if ($alive) { $false } else { [bool](Start-ChatqWatcherProcess) }
    return [pscustomobject]@{ Alive = $alive; Spawned = $spawned; Respawned = $false; At = (Get-Date) }
}

function Test-ChatqWatcherRequest {
    <#
    What came of a Request-ChatqWatcher: 'up' once a watcher holds the lock,
    'waiting' for up to 10 s, then 'failed'. A watcher running when poked may
    have been on its way out - it had found the queue empty and not yet let
    go - so one gone with jobs still queued is started again, once. With
    nothing queued a watcher ends at once, so not seeing it is no failure.
    #>
    param($Request, [bool]$Queued)
    if (-not $Request) { return 'none' }
    if (Test-ChatqWatcherAlive) { return 'up' }
    if (-not $Queued) { return 'up' }
    if ($Request.Alive -and -not $Request.Respawned) {
        $Request.Respawned = $true
        $Request.Spawned = [bool](Start-ChatqWatcherProcess)
        $Request.At = Get-Date
        return 'waiting'
    }
    if (((Get-Date) - $Request.At).TotalSeconds -lt 10) { return 'waiting' }
    return 'failed'
}

#endregion

function chatq {
    <#
    .SYNOPSIS
    Queue a prompt for an existing chat. It is sent when the usage limit resets.
    .DESCRIPTION
    Picks the chat now, while you are here to see the pick, and hands the job to
    a background watcher that sends it once the limit has reset - into the chat
    itself, in the permission mode that chat last used. Without -Prompt an
    editor tab opens for the prompt; save and close it to queue.

    chatq <n> opens queued prompt n in the editor instead, and chatq alone shows
    the cheat sheet and the queue.
    .PARAMETER Target
    Part or all of a chat title, or a session id. Tab completes titles.
    .PARAMETER Prompt
    The prompt, instead of writing it in the editor.
    .PARAMETER Continue
    Send "Continue from where you left off." - for a chat the limit cut off.
    .PARAMETER Mode
    Run in this permission mode instead of the one the chat last used.
    .PARAMETER At
    Not before this time (13:00 - tomorrow if already past).
    .PARAMETER In
    Not before this long from now (90m, 2h, 1d).
    .PARAMETER WhatIf
    Show which chat would be picked, queue nothing.
    .PARAMETER Model
    Run this one job on another model (claude --model / codex -m). Without it
    the chat keeps its own, which is what a resume does anyway.
    .PARAMETER First
    Put the job at the front of the queue instead of the back.
    .PARAMETER Attach
    Files to send with the prompt - images, text, code, PDF - comma-separated.
    They are copied into the job now, so moving or editing the originals
    changes nothing. Codex gets images as real attachments (-i); everything
    else, and everything for Claude, is named in the prompt for it to open.
    .PARAMETER Paste
    Take what is on the clipboard now: a screenshot, files copied in Explorer,
    or text. Text becomes the prompt, or is added under the one given. In the
    editor tab, Ctrl+V pastes an image into the prompt too.
    .PARAMETER AutoContinue
    What becomes of a chat the usage limit cuts off. With no title, the
    switch for every chat: ask (the default) - once the limit is over, the
    overlay says how many chats it cut off, and continues them if you say
    so; on - "continue" is queued for each by itself, a minute after the
    reset; off - they are only marked. With a title or a job number, that
    chat's own: always (continued even with the switch on ask or off),
    never, or default (follow the switch). Run it on its own - it queues
    nothing.
    .EXAMPLE
    chatq 'Parser rewrite and plugin unification' -Prompt 'Also update the changelog'
    .EXAMPLE
    chatq card redesign -WhatIf
    .EXAMPLE
    chatq 'Card layout redesign' -Prompt 'Match these two mock-ups' -Attach .\a.png, .\b.png
    .EXAMPLE
    chatq 'Card layout redesign' -Prompt 'What is wrong in this screenshot?' -Paste
    .EXAMPLE
    chatq -AutoContinue off
    .EXAMPLE
    chatq 'Parser rewrite' -AutoContinue never
    #>
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Target,
        [string]$Prompt,
        [switch]$Continue,
        [ValidateSet('default', 'acceptEdits', 'auto', 'bypassPermissions', 'manual', 'dontAsk', 'plan')][string]$Mode,
        [string]$At,
        [string]$In,
        [ValidateSet('claude', 'codex')][string[]]$Provider,
        [switch]$AllProjects,
        [switch]$WhatIf,
        [string]$Model,
        [switch]$First,
        [string[]]$Attach,
        [switch]$Paste,
        [ValidateSet('on', 'ask', 'off', 'always', 'never', 'default')][string]$AutoContinue
    )
    Set-StrictMode -Off
    # chatq -AutoContinue: a setting, not a job (src/auto-continue.ps1).
    # Refused beside anything that would queue, so a prompt typed with it is
    # never taken as queued.
    if ($PSBoundParameters.ContainsKey('AutoContinue')) {
        Invoke-ChatqAutoCommand -Value $AutoContinue -Target ((@($Target) -join ' ').Trim()) -Given @($PSBoundParameters.Keys) -WhatIf:$WhatIf -Provider $Provider -AllProjects:$AllProjects
        return
    }
    $t = (@($Target) -join ' ').Trim()
    if (-not $t) { Write-ChatqCheatSheet; Write-ChatqList; return }

    # chatq 3 - open queued prompt 3
    if ($t -match '^#?\d{1,4}$' -and -not $PSBoundParameters.ContainsKey('Prompt') -and -not $Continue) {
        $job = Find-ChatqJob $t
        # chatq 3 -Attach / -Paste - add to it: the screenshot that was
        # forgotten. Only while it waits, and only files - text belongs in the
        # prompt, which chatq 3 opens.
        if ($job -and ($Attach -or $Paste)) {
            $no = Get-ChatqJobFilesRefusal $job
            if ($no) { Write-Host "  $no" -ForegroundColor Yellow; return }
            $got = Read-ChatqAttachSources $Attach -Paste:$Paste
            foreach ($s in @($got.Skipped)) { Write-Host "     skipped $s - only files go, not folders" -ForegroundColor DarkGray }
            if ($got.Error) { Write-Host "  $($got.Error) - nothing added" -ForegroundColor Yellow; return }
            if ($got.Text) { Write-Host "  the clipboard holds text, not files - chatq $($job.seq) opens the prompt to paste it in" -ForegroundColor Yellow; return }
            $add = Add-ChatqJobFiles $job $got
            if ($add.Error) { Write-Host "  $($add.Error)" -ForegroundColor Yellow; return }
            Write-Host "  #$($job.seq) '$($job.title)' now has $(Format-ChatqAttachSummary @(Get-ChatqAttachments $job))" -ForegroundColor Green
            Write-ChatqBoard
            return
        }
        if ($job) {
            $p = Get-ChatqPromptPath $job
            Write-Host "  #$($job.seq) '$($job.title)' $($script:ChatqDot) $($job.state) $($script:ChatqDot) $p" -ForegroundColor DarkGray
            if ($job.state -ne 'queued') { Write-Host '  already sent - editing it changes nothing now' -ForegroundColor DarkGray }
            elseif ($job.kind -eq 'continue') { Write-Host '  a -Continue job always sends "continue" - the file is only for show' -ForegroundColor DarkGray }
            $af = @(Get-ChatqAttachments $job)
            if ($af) { Write-Host "  $(Format-ChatqAttachSummary $af) $($script:ChatqDot) $(Get-ChatqAttachDir $job)" -ForegroundColor DarkGray }
            if (Test-Path -LiteralPath $p) { Invoke-ChatqEditor $p -NoWait }
            return
        }
    }
    try { $notBefore = ConvertFrom-ChatqWhen $At $In } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; return }

    # The files and the clipboard before the pick: text pasted as the prompt
    # should weigh in on which chat it is for, as a typed one does.
    if (($Attach -or $Paste) -and $Continue) {
        Write-Host '  -Continue sends "continue" and nothing else - give the files with -Prompt instead' -ForegroundColor Yellow
        return
    }
    $got = $null
    if ($Attach -or $Paste) {
        $got = Read-ChatqAttachSources $Attach -Paste:$Paste
        foreach ($s in @($got.Skipped)) { Write-Host "     skipped $s - only files go, not folders" -ForegroundColor DarkGray }
        if ($got.Error) { Write-Host "  $($got.Error) - nothing queued" -ForegroundColor Yellow; return }
    }
    $given = $PSBoundParameters.ContainsKey('Prompt')
    $textNote = $null
    if ($got -and $got.Text) {
        if ($given) { $Prompt = $Prompt.TrimEnd() + "`n`n" + $got.Text; $textNote = "the clipboard's text goes under the prompt" }
        else { $Prompt = $got.Text; $given = $true; $textNote = "the clipboard's text is the prompt" }
    }

    $res = Resolve-ChatqTarget $t $(if ($given) { $Prompt } else { '' }) $Provider -AllProjects:$AllProjects
    if ($res.Error) { Write-Host "  $($res.Error)" -ForegroundColor Yellow; return }
    Write-ChatqPick $res
    Write-ChatqPromptHint $t $res -HasPrompt:$given -Continue:$Continue
    $info = Get-ChatqJobInfo $res.Row
    if ($info.Error) { Write-Host "     $($info.Error)" -ForegroundColor Yellow; return }
    Write-ChatqJobInfo $info $Mode -Continue:$Continue $res.Row.Provider
    if ($Model) { Write-Host "     model $Model for this run (the chat's own: $(if ($info.Model) { $info.Model } else { 'unknown' }))" -ForegroundColor DarkGray }
    if ($textNote) { Write-Host "     $textNote" -ForegroundColor DarkGray }
    if ($got) {
        $pending = @(foreach ($s in $got.Files) { Get-Item -LiteralPath $s })
        if ($got.Image) { $pending += [pscustomobject]@{ Name = 'clip.png'; Length = $got.Image.Length } }
        if ($pending) {
            Write-Host "     with $(Format-ChatqAttachSummary $pending)" -ForegroundColor DarkGray
            $bytes = ($pending | Measure-Object -Property Length -Sum).Sum
            if ($pending.Count -gt $script:ChatqAttachWarnCount -or $bytes -gt $script:ChatqAttachWarnBytes) {
                Write-Host '     that is a lot for one run - every file costs context, and usage' -ForegroundColor Yellow
            }
        }
    }
    if ($WhatIf) { Write-Host '     -WhatIf: nothing queued' -ForegroundColor DarkGray; return }

    $how = @{ Mode = $Mode; Model = $Model; NotBefore = $notBefore; First = $First; Typed = $t }
    if ($Continue -or $given) {
        $made = New-ChatqJob -Row $res.Row -Prompt $Prompt -Kind $(if ($Continue) { 'continue' } else { 'prompt' }) -Info $info -Sources $got -Resolve $res @how
        if ($made.Error) { Write-Host "  $($made.Error)" -ForegroundColor Yellow; return }
        $job = $made.Job
        $missed = $made.Missed
    }
    else {
        # The editor. The files go in before the tab opens: a copy that fails -
        # one moved or locked since it was checked - then stops the job before
        # a word of it has been typed, rather than after.
        $slot = New-ChatqJobSlot $res.Row
        if ($got) {
            try { $null = Save-ChatqAttachSources $slot.Dir $got }
            catch { Write-Host "  a file could not be copied - nothing queued: $($_.Exception.Message)" -ForegroundColor Yellow; return }
        }
        Save-ChatqText $slot.Path $slot.Header
        Write-Host '     write the prompt in the editor tab, then save and close it (empty = cancel)' -ForegroundColor DarkGray
        Write-Host '     Ctrl+V there pastes a screenshot into it, and it goes with the prompt' -ForegroundColor DarkGray
        Invoke-ChatqEditor $slot.Path
        $text = Remove-ChatqPromptHeader ([System.IO.File]::ReadAllText($slot.Path, [System.Text.Encoding]::UTF8))
        if (-not $text) {
            Remove-Item -LiteralPath $slot.Path -Force -EA SilentlyContinue
            Remove-Item -LiteralPath $slot.Dir -Recurse -Force -EA SilentlyContinue
            Write-Host '  cancelled - nothing queued' -ForegroundColor DarkGray
            return
        }
        # relevance was scored on the title alone - now the prompt can weigh in
        if ($res.Rule -like '*/relevance') {
            $res2 = Resolve-ChatqTarget $t $text $Provider -AllProjects:$AllProjects
            if (-not $res2.Error -and $res2.Row.Path -ne $res.Row.Path) {
                $info2 = Get-ChatqJobInfo $res2.Row
                if (-not $info2.Error) {
                    Write-ChatqPick $res2 '  re-picked with the prompt ->'
                    Write-ChatqJobInfo $info2 $Mode -Continue:$Continue $res2.Row.Provider
                    $res = $res2; $info = $info2
                    $slot.File = "#$($slot.Seq) $(Get-ChatqSafeName $res.Row.Title).md"
                    $new = Join-Path $script:ChatqQueueDir $slot.File
                    Move-Item -LiteralPath $slot.Path -Destination $new -Force
                    $slot.Path = $new
                }
            }
        }
        $job = New-ChatqJobRecord $slot $res.Row $info -Kind 'prompt' -Resolve $res @how
        $missed = (Register-ChatqJob $job).Missed
    }
    $seq = $job.seq
    # what the prompt links to in data/queue: an image pasted in the tab
    foreach ($x in @($missed)) { Write-Host "     could not take in $x - it goes without it" -ForegroundColor Yellow }
    $files = @(Get-ChatqAttachments $job)

    $jobs = @(Get-ChatqJobs)
    # the watcher's own view if it is running - it knows about an overload -
    # else a scan of the transcripts
    $blocks = Get-ChatqBlocks
    $eta = (Get-ChatqEta $jobs $blocks)[$job.id]
    $b = $blocks[(Get-ChatqLane $job)]
    $why = if ($b -and $b.Type -eq 'overloaded') { ' (Claude is overloaded - watching status.claude.com)' }
    elseif ($b -and $b.Until) { " ($($b.Type) limit resets $($b.Until.ToString('HH:mm')))" }
    else { ' (not limited right now)' }
    Write-Host "  queued #$seq  sends $eta$why" -ForegroundColor Green
    if ($files) { Write-Host "     $(Format-ChatqAttachSummary $files)" -ForegroundColor DarkGray }
    if (-not (Start-ChatqWatcher)) {
        Write-Host '  the watcher did not start - chatqrun to try again, chatqrun -Foreground to see why' -ForegroundColor Yellow
    }
    Write-ChatqBoard
}

function chatqlist {
    <#
    .SYNOPSIS
    What is queued, when it sends, and what already ran.
    .PARAMETER Board
    Open the live board (data/queue.md) in VS Code - Ctrl+Shift+V there for the
    preview, which follows every change. Long prompts fold away.
    .PARAMETER All
    Include every finished job, not just the last day's.
    #>
    param([switch]$Board, [switch]$All)
    Set-StrictMode -Off
    if ($Board) {
        Write-ChatqBoard
        Invoke-ChatqEditor $script:ChatqBoardPath -NoWait
        Write-Host '  opened data/queue.md - Ctrl+Shift+V there for the live preview' -ForegroundColor DarkGray
        return
    }
    Write-ChatqList -All:$All
}

function chatqrm {
    <#
    .SYNOPSIS
    Drop queued jobs by number or id. -Force cancels one that is running.
    .PARAMETER Finished
    Drop every job that is done, skipped, failed or needs input.
    #>
    param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Ref, [switch]$Force, [switch]$Finished)
    Set-StrictMode -Off
    $jobs = @(Get-ChatqJobs)
    $targets = if ($Finished) { @($jobs | Where-Object { $_.state -in 'done', 'skipped', 'failed', 'needs-input' }) }
    else { @(foreach ($r in @($Ref)) { $j = Find-ChatqJob $r $jobs; if ($j) { $j } else { Write-Host "  no job $r" -ForegroundColor Yellow } }) }
    if (-not $targets) { if (-not $Ref -and -not $Finished) { Write-Host '  usage: chatqrm <n> [-Force] | chatqrm -Finished' -ForegroundColor DarkGray }; return }
    foreach ($j in $targets) {
        if ($j.state -eq 'running') {
            if (-not $Force) { Write-Host "  #$($j.seq) is running - chatqrm $($j.seq) -Force cancels it" -ForegroundColor Yellow; continue }
            $stop = Stop-ChatqJobRun $j
            if ($stop -eq 'cancelling') {
                Write-Host "  #$($j.seq) cancelling - stopped within a few seconds" -ForegroundColor DarkGray
                continue
            }
            if ($stop -eq 'not running') { Write-Host "  #$($j.seq) had already ended - chatqrm $($j.seq) removes it" -ForegroundColor DarkGray; continue }
            Write-Host "  #$($j.seq) was left running by a watcher that stopped - marked failed" -ForegroundColor DarkGray
            Write-Host "    chatqrm $($j.seq) removes it, chatqrun $($j.seq) sends it again" -ForegroundColor DarkGray
            continue
        }
        $null = Remove-ChatqJob $j
        Write-Host "  removed #$($j.seq) '$($j.title)'" -ForegroundColor DarkGray
    }
    Write-ChatqBoard
}

function chatqrun {
    <#
    .SYNOPSIS
    Start the watcher, requeue a job, skip the wait, or stop.
    .PARAMETER Ref
    A failed or needs-input job to queue again. One whose prompt already reached
    the chat is sent as "continue" rather than twice.
    .PARAMETER Now
    Stop waiting for the reset: probe now, and send if the limit is over.
    .PARAMETER Foreground
    Run the watcher in this console and watch what it does.
    .PARAMETER Stop
    Stop the watcher. A running job is cut off and marked failed.
    .PARAMETER Mode
    With a job number: requeue it in this permission mode.
    .PARAMETER First
    With a job number: put it at the front of the queue - a queued one moves
    up, a finished one is requeued there.
    #>
    param(
        [Parameter(Position = 0)][string]$Ref,
        [switch]$Now, [switch]$Foreground, [switch]$Stop,
        [ValidateSet('default', 'acceptEdits', 'auto', 'bypassPermissions', 'manual', 'dontAsk', 'plan')][string]$Mode,
        [switch]$First
    )
    Set-StrictMode -Off
    if ($Stop) {
        # Listening for phone replies stops too, and before data/stop is
        # written: while the window is open every new shell - and a watcher
        # on its way out - starts a watcher to listen. The next alert that
        # can be answered opens it again.
        $closed = Close-ChatqReplyWindow
        if (-not (Test-ChatqWatcherAlive)) {
            Write-Host "  the watcher is not running$(if (-not $closed) { ' - data/replies.json could not be written, so a new shell may start one to listen for phone replies' })" -ForegroundColor DarkGray
            return
        }
        Save-ChatqText $script:ChatqStopPath 'stop'
        Write-Host '  stopping - within a few seconds' -ForegroundColor DarkGray
        return
    }
    if ($Ref) {
        $j = Find-ChatqJob $Ref
        if (-not $j) { Write-Host "  no job $Ref" -ForegroundColor Yellow; return }
        if ($First -and $j.state -eq 'queued') {
            Set-ChatqJobFirst $j
            Write-Host "  #$($j.seq) moved to the front" -ForegroundColor Green
            Write-ChatqBoard
            Write-ChatqList
            return
        }
        # a finished one put first is requeued there
        if ($First -and $j.state -in 'failed', 'needs-input', 'done', 'skipped') { Set-ChatqProp $j 'first' (Get-ChatqStamp) }
        $again = Reset-ChatqJob $j $Mode
        if ($again.Error) { Write-Host "  $($again.Error)" -ForegroundColor DarkGray; return }
        $how = if ($again.Landed) { 'as "continue" - the prompt already reached the chat' } else { 'with its prompt' }
        Write-Host "  #$($j.seq) queued again, $how" -ForegroundColor Green
    }
    if ($Foreground) {
        if ($Now) { Send-ChatqWake 'now' }
        Invoke-ChatqWatchLoop -Foreground
        return
    }
    # -Now travels as the watcher's one wake-up write: sent separately, the
    # poke that follows would overwrite it before the watcher read it
    $wake = if ($Now) { 'now' } else { 'poke' }
    if (@(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })) {
        if (-not (Start-ChatqWatcher -Wake $wake)) { Write-Host '  the watcher did not start - chatqrun -Foreground to see why' -ForegroundColor Yellow }
    }
    Write-ChatqList
}

function chatqlog {
    <#
    .SYNOPSIS
    What a run did: the reply, the tools it used, how it ended. -Raw for the stream.
    #>
    param([Parameter(Position = 0)][string]$Ref, [switch]$Raw)
    Set-StrictMode -Off
    $j = if ($Ref) { Find-ChatqJob $Ref } else { @(Get-ChatqJobs | Where-Object { $_.startedAt } | Sort-Object startedAt)[-1] }
    if (-not $j) { Write-Host '  no such job' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host "  #$($j.seq) '$($j.title)' $($script:ChatqDot) $($j.state)" -ForegroundColor Cyan
    foreach ($h in @($j.history)) {
        $at = ConvertTo-ChatqDate $h.at
        Write-Host ("    {0}  {1,-11} {2}" -f $at.ToString('MM-dd HH:mm'), $h.state, $h.why) -ForegroundColor DarkGray
    }
    $log = Join-Path $script:ChatqLogDir "$($j.id).jsonl"
    if (-not (Test-Path -LiteralPath $log)) { Write-Host '  no run yet'; Write-Host ''; return }
    if ($Raw) { Get-Content -LiteralPath $log -Encoding UTF8; return }
    Write-Host ''
    foreach ($e in @(Get-ChatqLogEntries $j)) {
        switch ($e.Type) {
            'init' { Write-Host "  $($e.Text)" -ForegroundColor DarkGray }
            'denied' { Write-Host "  ! denied $($e.Text)" -ForegroundColor Yellow }
            'text' { Write-Host ''; Write-Host $e.Text }
            'tool' { Write-Host "  > $($e.Text)" -ForegroundColor DarkGray }
            'result' { Write-Host ''; Write-Host "  = $($e.Text)" -ForegroundColor DarkGray }
            'error' { Write-Host "  ! $($e.Text)" -ForegroundColor Yellow }
        }
    }
    Write-Host ''
}

function Test-ChatqCanAsk {
    # Can this shell ask a question and have it answered at the keyboard?
    # Not a hidden process, not -NonInteractive, not input from a pipe or a
    # file, and never the watcher. $script:ChatqAskSeam (tests): $false for
    # no, a scriptblock that answers for yes.
    if ($null -ne $script:ChatqAskSeam) { return ($script:ChatqAskSeam -is [scriptblock]) }
    try {
        if ($env:CHATQ_WATCHER -eq '1' -or -not [Environment]::UserInteractive -or $Host.Name -ne 'ConsoleHost') { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        if (@([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^[-/]noni' }).Count) { return $false }
        return $true
    }
    catch { return $false }
}

function Wait-ChatqPairCandidates {
    <#
    chatnotify -Pair, after the pairing push went out: wait for the
    phone's answer - until the pairing runs out - and put each one that
    comes in to you, with its code, to confirm or not. The watcher is the
    one reading the reply topic; this reads data/replies.json once a second.
    Ctrl+C ends the wait and leaves the pairing open: chatnotify shows the
    answers, chatnotify -Confirm takes one. Returns when a phone is paired
    - here, or in the setup window meanwhile - or the pairing is over.
    #>
    param([datetime]$Until)
    $asked = @{}
    Write-Host '  waiting for the phone (Ctrl+C stops waiting; the pairing stays open)' -ForegroundColor DarkGray
    while ((Get-Date) -lt $Until) {
        $cfg = Get-ChatqConfig
        $rc = Get-ChatqReplyConfig $cfg
        if (-not $rc.PairId) {
            if ($rc.Paired) { Write-Host "  paired - $($rc.Phone)" -ForegroundColor Green }
            else { Write-Host '  the pairing is over - chatnotify -Pair starts another' -ForegroundColor Yellow }
            return
        }
        foreach ($pc in @(Get-ChatqPairCandidates $cfg)) {
            if ($asked.ContainsKey($pc.Id)) { continue }
            $asked[$pc.Id] = $true
            Write-Host "  $($pc.Label) answered - code $($pc.Code)" -ForegroundColor Cyan
            $q = 'same code on the phone? (y/n)'
            $a = if ($script:ChatqAskSeam -is [scriptblock]) { [string](& $script:ChatqAskSeam $q) } else { Read-Host "  $q" }
            if ($a.Trim() -notmatch '^(y|yes)$') {
                Write-Host '  not that one - still waiting (an answer you do not recognise is someone else''s)' -ForegroundColor DarkGray
                continue
            }
            $cr = Confirm-ChatqPairCandidate -Id $pc.Id
            if ($cr.Error) { Write-Host "  $($cr.Error)" -ForegroundColor Yellow; return }
            Write-Host "  paired - $($cr.Label)$(if ($cr.Sent) { ' - a push says so on the phone' })" -ForegroundColor Green
            return
        }
        if ($script:ChatqPairWaitSeam) { & $script:ChatqPairWaitSeam } else { Start-Sleep -Seconds 1 }   # tests
    }
    Write-Host '  the pairing ran out - chatnotify -Pair starts another' -ForegroundColor Yellow
}

function chatnotify {
    <#
    .SYNOPSIS
    Phone alerts through Join (joaomgcd): started, needs input, done, failed.
    .DESCRIPTION
    Get the API key and device id from https://joinjoaomgcd.appspot.com (the
    "Join API" button). -Device takes a device id, a group (group.phone,
    group.android, group.all) or a device name. The key is DPAPI-protected on
    Windows. Alerts always go to data/logs/alerts.log as well.

    Paste the key itself rather than the whole push URL that page shows. A URL
    pasted bare never reaches chatq at all - PowerShell stops at its first & -
    and one in quotes has its key and device read out of it.

    Tasker: every title starts "chatq ", so a profile on the Join plugin's
    event can filter them, or match only "needs input" and "failed".

    ntfy instead of, or as well as, Join: -Ntfy <topic>. Anyone who knows the
    topic can read the alerts, so treat it as a password - a long random one on
    ntfy.sh, or your own server with -NtfyServer and -NtfyToken.

    -Command runs your own PowerShell on every alert, with the alert in
    $env:CHATQ_EVENT, CHATQ_TITLE, CHATQ_TEXT, CHATQ_PRIORITY, CHATQ_JOB and
    CHATQ_PRESENT (1 while you are at the PC). A desktop toast is on unless
    -Toast off. The phone stays quiet while you are at the PC - keyboard or
    mouse used in the last -QuietMinutes (5; 0 turns that off). -Events keeps
    all but the named events off the phone (done, failed, 'needs input',
    started, limited, overloaded, waiting; all for every one).

    Chats you run yourself - in VS Code or a terminal, not through chatq -
    alert too, from the overlay (Windows): 'needs input' when one has waited
    on you for 20 s, 'done' when one finished a turn, and only while you are
    away from the PC for -QuietMinutes (never with 0) - whichever window is
    in front, since away means nobody is looking at it. -LiveAlerts off
    keeps the phone to what chatq runs.

    Usage heads-ups: 'usage' alerts when a 5-hour or weekly window reaches
    -UsageAt (90; up to three, 75, 90), from the overlay; and, from the
    watcher, 10 minutes before a limit resets with prompts queued - the
    phone's page offers Send now - and when it has. -UsageAlerts off,
    -UsageReset off.

    Quiet hours: -QuietHours 00:00-07:00 (this PC's clock) holds the
    phone's alerts, except -Urgent (failed, unless named otherwise; none
    for nothing), and sends them as one summary when the window ends. The
    toast and your command still run; the command gets CHATQ_QUIET=1.
    -QuietHours off sends what was held at once.

    -Say 'needs input', failed: Join reads a short line aloud on the phone
    for those events - through its speaker too, when no headphones are
    in. -SayLanguage auto (Korean for a Hangul title), en, ko or another
    code; none for nothing.

    -Reply on: each phone alert carries a link to a page where you type the
    next prompt for that chat - or allow edits, retry, skip, stop, ask for
    the status - and the watcher picks it up. The phone is paired once first
    (-Pair; -Reply on does it when none is): a push you tap on it, and the
    page there makes a key that only that phone and this PC hold, and shows
    a six-digit code. The same code comes up here - -Pair waits for it and
    asks - and you confirm it (or later: -Confirm 123456); an answer whose
    code you did not see on your phone is someone else's. Replies go
    sealed with the key (AES and an HMAC) through a random ntfy.sh topic,
    and no alert after the pairing push carries anything secret. A job a
    reply queues or requeues runs in acceptEdits at most (reply.maxMode in
    config.json sets another cap), and a Codex one in workspace-write at
    most. -Pair again - or -Reply renew - pairs afresh: the phone paired
    before stops working at once. -ReplyPage <https URL> serves the page
    from a copy of your own: the page keeps the phone's key under its site,
    and every <user>.github.io project page shares one. -Setup opens all of
    this in a window (Windows); -Devices lists the devices on your Join
    account.

    -Permit on: a queued Claude run that meets a permission prompt asks the
    phone - a push that names the chat and the kind of call, and a page
    that shows the call itself, sealed for the phone - and waits
    -PermitWait minutes (10) for Allow once or Deny. Off by default: it lets
    the phone make a command run on this PC. -PermitTools names what the
    phone may approve (default: Bash, PowerShell, Edit, Write, MultiEdit,
    NotebookEdit, WebFetch; mcp__server__* for an MCP server's tools).

    A chat you run yourself that asks a question (AskUserQuestion) shows it
    on the board and its needs input alert's page, every option with its
    description. -Ask on lets the phone answer it too: chatq adds a small
    Claude Code hook, as the plugin chatq-ask, that holds the question for
    the phone -AskWait minutes (240) while the PC's dialog stays open - the
    first answer counts. -Manual prints the hook for your settings instead.

    The page shows Claude's whole answer with done, needs input and failed
    (-FullText off leaves the alert's excerpt only), and opened from a
    bookmark it is the overlay on the phone - usage, every chat, the queue -
    where you can queue to any chat, act on the queue, or start a chat in a
    folder chatq knows (-Compose off turns that off; -NewMode sets the mode
    a new one runs in, capped as replies are). The PC reads the phone while
    an alert is out; -Listen always keeps a hidden PowerShell listening
    while a phone is paired, asking ntfy.sh every 20 s.

    chatqnotify is the old name, from when this only served chatq's queue,
    and still works.
    .EXAMPLE
    chatnotify -Setup
    .EXAMPLE
    chatnotify -ApiKey 0123abcd... -Device group.phone
    .EXAMPLE
    chatnotify -Reply on
    .EXAMPLE
    chatnotify -Pair
    .EXAMPLE
    chatnotify -Confirm 123456
    .EXAMPLE
    chatnotify -Events done, failed, 'needs input'
    .EXAMPLE
    chatnotify -Ntfy chatq-7f3a9c1e2b
    .EXAMPLE
    chatnotify -Command 'Invoke-RestMethod https://example.com/hook -Method Post -Body $env:CHATQ_TEXT'
    .EXAMPLE
    chatnotify -Test
    .EXAMPLE
    chatnotify -LiveAlerts off
    .EXAMPLE
    chatnotify -UsageAt 75, 90
    .EXAMPLE
    chatnotify -QuietHours 00:00-07:00 -Urgent failed, 'needs input'
    .EXAMPLE
    chatnotify -Say 'needs input', failed
    .EXAMPLE
    chatnotify -Permit on -PermitWait 15
    .EXAMPLE
    chatnotify -Ask on
    #>
    param(
        [string]$ApiKey, [string]$Device, [switch]$Test, [switch]$Off,
        [string]$Ntfy, [string]$NtfyServer, [string]$NtfyToken,
        [string]$Command, [ValidateSet('on', 'off')][string]$Toast, [int]$QuietMinutes = -1,
        [switch]$Setup, [ValidateSet('on', 'off', 'renew')][string]$Reply, [string[]]$Events, [switch]$Devices, [switch]$Pair,
        [string]$Confirm, [string]$ReplyPage, [ValidateSet('on', 'off')][string]$LiveAlerts,
        [ValidateSet('on', 'off')][string]$UsageAlerts, [string[]]$UsageAt, [ValidateSet('on', 'off')][string]$UsageReset,
        [string]$QuietHours, [string[]]$Urgent, [string[]]$Say, [string]$SayLanguage,
        [ValidateSet('on', 'off')][string]$Permit, [string]$PermitWait, [string[]]$PermitTools,
        [ValidateSet('on', 'off')][string]$Ask, [string]$AskWait, [switch]$Manual,
        [ValidateSet('on', 'off')][string]$FullText, [ValidateSet('on', 'off')][string]$Compose, [ValidateSet('alerts', 'always')][string]$Listen, [string]$NewMode
    )
    Set-StrictMode -Off
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $cr = Confirm-ChatqPairCandidate -Code $Confirm
        if ($cr.Error) { Write-Host "  $($cr.Error)" -ForegroundColor Yellow; return }
        Write-Host "  paired - $($cr.Label)$(if ($cr.Sent) { ' - a push says so on the phone' })" -ForegroundColor Green
        return
    }
    if ($Setup) {
        if ($script:ChatqIsWindows) { [void](Start-ChatqPhoneSetup); return }
        Write-Host '  the setup window is Windows-only - the same from here:' -ForegroundColor Yellow
        Write-Host '      chatnotify -ApiKey <key> -Device <device id | group.phone>   Join' -ForegroundColor Cyan
        Write-Host '      chatnotify -Devices                                          the devices on that key' -ForegroundColor Cyan
        Write-Host '      chatnotify -Reply on                                         answer alerts from the phone' -ForegroundColor Cyan
        Write-Host '      chatnotify -Pair                                             pair the phone (again)' -ForegroundColor Cyan
        Write-Host '      chatnotify -Confirm 123456                                   confirm the code the phone shows' -ForegroundColor Cyan
        Write-Host "      chatnotify -Events done, failed, 'needs input'               what reaches the phone" -ForegroundColor Cyan
        Write-Host '      chatnotify -QuietMinutes 5 / -Toast on / -Test' -ForegroundColor Cyan
        Write-Host '      chatnotify -Ntfy <topic> [-NtfyServer <url>] / -Command <ps>   other channels' -ForegroundColor Cyan
        Write-Host '      chatnotify -LiveAlerts on|off / -ReplyPage <https URL>' -ForegroundColor Cyan
        Write-Host '      chatnotify -UsageAt 90 / -UsageReset on|off / -QuietHours 00:00-07:00 / -Say ''needs input''' -ForegroundColor Cyan
        Write-Host '      chatnotify -Permit on|off [-PermitWait <min>]                 approve tool calls from the phone' -ForegroundColor Cyan
        Write-Host '      chatnotify -Ask on|off [-AskWait <min>] [-Manual]              answer Claude''s questions from the phone' -ForegroundColor Cyan
        Write-Host '      chatnotify -FullText on|off / -Compose on|off / -Listen alerts|always / -NewMode <mode>' -ForegroundColor Cyan
        return
    }
    if ($Devices) {
        # the key given (a pasted push URL too), else the one saved
        $key = if ($ApiKey) { (ConvertFrom-ChatqJoinPaste $ApiKey).Key } else {
            $c = Get-ChatqConfig
            if ($c.PSObject.Properties['join'] -and $c.join) { Unprotect-ChatqSecret $c.join.apiKey }
        }
        if (-not $key) { Write-Host '  no Join key - chatnotify -Devices -ApiKey <key>, or save one first' -ForegroundColor Yellow; return }
        $r = Get-ChatqJoinDevices $key
        if ($r.Error) { Write-Host "  $($r.Error)" -ForegroundColor Yellow }
        foreach ($dv in @($r.Devices)) {
            $what = if ($dv.Model) { "$($dv.Name) ($($dv.Model))" } else { $dv.Name }
            Write-Host ('  {0,-34} {1}' -f $dv.Id, $what) -ForegroundColor $(if ($dv.Type -eq 'group') { 'DarkGray' } else { 'Cyan' })
        }
        Write-Host '  chatnotify -Device <id> sends to that one' -ForegroundColor DarkGray
        return
    }
    # the saving is shared with the setup window: Set-ChatqNotifyConfig
    $ch = @{}
    if ($Off) { $ch['Off'] = $true }
    if ($ApiKey) { $ch['ApiKey'] = $ApiKey }
    if ($Device) { $ch['Device'] = $Device }
    if ($Ntfy) { $ch['Ntfy'] = $Ntfy }
    if ($NtfyServer) { $ch['NtfyServer'] = $NtfyServer }
    if ($NtfyToken) { $ch['NtfyToken'] = $NtfyToken }
    if ($PSBoundParameters.ContainsKey('Command')) { $ch['Command'] = $Command }
    if ($Toast) { $ch['Toast'] = $Toast }
    if ($QuietMinutes -ge 0) { $ch['QuietMinutes'] = $QuietMinutes }
    if ($PSBoundParameters.ContainsKey('Events')) { $ch['Events'] = $Events }
    if ($PSBoundParameters.ContainsKey('ReplyPage')) { $ch['ReplyPage'] = $ReplyPage }
    if ($LiveAlerts) { $ch['LiveAlerts'] = $LiveAlerts }
    foreach ($xn in 'UsageAlerts', 'UsageAt', 'UsageReset', 'QuietHours', 'Urgent', 'Say', 'SayLanguage') { if ($PSBoundParameters.ContainsKey($xn)) { $ch[$xn] = $PSBoundParameters[$xn] } }
    if ($Permit) { $ch['Permit'] = $Permit }
    if ($PSBoundParameters.ContainsKey('PermitWait')) { $ch['PermitWait'] = $PermitWait }
    if ($PSBoundParameters.ContainsKey('PermitTools')) { $ch['PermitTools'] = $PermitTools }
    # answering Claude's questions from the phone (src/ask.ps1)
    if ($Ask) { $ch['Ask'] = $Ask; $ch['AskManual'] = [bool]$Manual }
    if ($PSBoundParameters.ContainsKey('AskWait')) { $ch['AskWait'] = $AskWait }
    # the whole answer, the board and new chats, listening all the time
    if ($FullText) { $ch['FullText'] = $FullText }
    if ($Compose) { $ch['Compose'] = $Compose }
    if ($Listen) { $ch['Listen'] = $Listen }
    if ($NewMode) { $ch['NewMode'] = $NewMode }
    # renew is what pairing afresh used to be called, and does the same
    if ($Reply -eq 'renew') { $Pair = $true }
    elseif ($Reply) { $ch['Reply'] = $Reply }
    $res = Set-ChatqNotifyConfig $ch
    foreach ($m in @($res.Messages)) { Write-Host "  $($m.Text)" -ForegroundColor $m.Color }
    if ($res.Error -or $Off) { return }
    $changed = $res.Changed
    if ($Pair -or $res.NeedsPairing) {
        $pr = Start-ChatqReplyPairing
        foreach ($r in @($script:ChatqAlertReport)) { Write-Host "  $r" -ForegroundColor $(if ($r -match ': (sent|shown|ran)$') { 'Green' } else { 'Yellow' }) }
        if ($pr.Error) { Write-Host "  pairing: $($pr.Error)" -ForegroundColor Yellow; return }
        Write-Host "  pairing alert sent - tap it on the phone by $($pr.Until.ToString('HH:mm')), then Pair on the page that opens" -ForegroundColor Green
        Write-Host '  a phone paired before no longer works' -ForegroundColor DarkGray
        if (Test-ChatqCanAsk) { Wait-ChatqPairCandidates $pr.Until }
        else { Write-Host '  the phone then shows a code: chatnotify -Confirm <that code> pairs it' -ForegroundColor DarkGray }
        if (-not $Test) { return }
    }
    if ($Test -or $ApiKey -or $Ntfy) {
        # -Loud: typed at the PC by definition, and meant for the phone anyway
        $ok = Send-ChatqAlert 'test' "chatq reaches this device $($script:ChatqDot) $([Environment]::MachineName)" 1 -Loud
        foreach ($r in @($script:ChatqAlertReport)) { Write-Host "  $r" -ForegroundColor $(if ($r -match ': (sent|shown|ran)$') { 'Green' } else { 'Yellow' }) }
        if (Test-ChatqQuietIn (Get-ChatqConfig)) { Write-Host '  quiet hours now - only urgent alerts and tests go' -ForegroundColor DarkGray }
        if ($ok) {
            Write-Host '  check your phone' -ForegroundColor Green
            if ((Get-ChatqReplyConfig).Links) { Write-Host '  tap it for the reply page - "Send a test reply" comes back here as a push' -ForegroundColor DarkGray }
        }
        return
    }
    if (-not $changed) {
        $cfg = Get-ChatqConfig
        $any = $false
        if ($cfg.PSObject.Properties['join'] -and $cfg.join -and $cfg.join.apiKey) { $any = $true; Write-Host "  Join on $($script:ChatqDot) device $($cfg.join.device)" -ForegroundColor DarkGray }
        if ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy -and $cfg.ntfy.topic) { $any = $true; Write-Host "  ntfy on $($script:ChatqDot) $(if ($cfg.ntfy.server) { $cfg.ntfy.server } else { 'https://ntfy.sh' })" -ForegroundColor DarkGray }
        if ($cfg.PSObject.Properties['command'] -and $cfg.command) { Write-Host '  command on' -ForegroundColor DarkGray }
        $toastOn = -not ($cfg.PSObject.Properties['toast'] -and $cfg.toast -eq $false)
        $qm = if ($cfg.PSObject.Properties['quietMinutes']) { [int]$cfg.quietMinutes } else { 5 }
        Write-Host "  toast $(if ($toastOn) { 'on' } else { 'off' }) $($script:ChatqDot) phone quiet while at the PC: $(if ($qm) { "$qm min" } else { 'off' })" -ForegroundColor DarkGray
        if ($cfg.PSObject.Properties['phoneEvents'] -and $null -ne $cfg.phoneEvents) {
            Write-Host "  the phone gets: $(@($cfg.phoneEvents) -join ', ') (and tests and replies)" -ForegroundColor DarkGray
        }
        Write-Host "  chats you run yourself: $(Get-ChatqLiveAlertStatusText $cfg)" -ForegroundColor DarkGray
        Write-ChatqNotifyExtrasStatus $cfg
        $rst = Get-ChatqPhoneStatusText $cfg
        Write-Host "  replies from the phone: $rst" -ForegroundColor DarkGray
        if ($rst -eq 'not paired') { Write-Host '    chatnotify -Pair sends the pairing alert to tap' -ForegroundColor DarkGray }
        # the answers to the pairing waiting: confirm the one whose code
        # the phone shows
        foreach ($pc in @(Get-ChatqPairCandidates $cfg)) {
            Write-Host "    $($pc.Label) answered$(if ($pc.At) { " at $($pc.At.ToString('HH:mm'))" }) - code $($pc.Code)   chatnotify -Confirm $($pc.Digits)" -ForegroundColor Cyan
        }
        $rcs = Get-ChatqReplyConfig $cfg
        if ($rcs.Wanted -and $rcs.MaxMode -ne 'acceptEdits') { Write-Host "    a reply runs a job in $($rcs.MaxMode) at most" -ForegroundColor DarkGray }
        Write-Host "  permissions from the phone: $(Get-ChatqPermitStatusText $cfg)" -ForegroundColor DarkGray
        Write-Host "  questions from the phone: $(Get-ChatqAskStatusText $cfg)" -ForegroundColor DarkGray
        Write-ChatqBoardNotifyStatus $cfg
        if ($any) { Write-Host '  chatnotify -Test sends one' -ForegroundColor DarkGray }
        else {
            Write-Host '  no phone alerts yet - Join or ntfy:' -ForegroundColor DarkGray
            if ($script:ChatqIsWindows) { Write-Host '      chatnotify -Setup                                           all of it in a window' -ForegroundColor Cyan }
            Write-Host '      chatnotify -ApiKey <key> -Device <device id | group.phone>   (https://joinjoaomgcd.appspot.com, Join API)' -ForegroundColor Cyan
            Write-Host '        the key itself, not the push URL - PowerShell stops at the & in one unless it is quoted' -ForegroundColor DarkGray
            Write-Host '      chatnotify -Ntfy <long random topic>                        (https://ntfy.sh, free)' -ForegroundColor Cyan
        }
    }
}

function Write-ChatqCheatSheet {
    Write-Host ''
    Write-Host '  chatq <title> [-Prompt s]   queue a prompt for that chat (no -Prompt: editor)' -ForegroundColor Cyan
    Write-Host '  chatq <title> -Continue     queue "continue" for a chat the limit cut off' -ForegroundColor Cyan
    Write-Host '  chatq [<title>] -AutoContinue ask|on|off|never  what the limit cuts off: ask, continue by itself, or leave' -ForegroundColor Cyan
    Write-Host '  chatq <n>                   open queued prompt n' -ForegroundColor Cyan
    Write-Host '  chatqlist [-Board]          the queue; -Board = live board in VS Code' -ForegroundColor Cyan
    Write-Host '  chatqrm <n> [-Force]        drop a job; -Force cancels a running one' -ForegroundColor Cyan
    Write-Host '  chatqrun [<n>] [-Now]       requeue n / stop waiting and try now' -ForegroundColor Cyan
    Write-Host '  chatqlog <n>                what a run did' -ForegroundColor Cyan
    Write-Host '  chatnotify                  alerts: toast here, Join or ntfy on the phone' -ForegroundColor Cyan
    Write-Host '  chatoverlay                 every open chat, the queue and usage, always on top' -ForegroundColor Cyan
    Write-Host '  chatconsole                 all of the above in a window: write, drop files, send now' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  -WhatIf shows the pick only   -Mode auto|acceptEdits|...   -At 13:00 / -In 2h' -ForegroundColor DarkGray
    Write-Host '  -Attach a.png, spec.pdf / -Paste   send files, a screenshot or the clipboard with it' -ForegroundColor DarkGray
    Write-Host '  Tab fills in a title from any part of it, like chatrm: chatq card red<Tab>' -ForegroundColor DarkGray
    Write-Host '  chat = every command, find and delete included' -ForegroundColor DarkGray
    Write-Host "  claude-codex-chat-manager $script:ChatVersion $($script:ChatqDot) $script:ChatqScriptPath" -ForegroundColor DarkGray
}

#endregion
