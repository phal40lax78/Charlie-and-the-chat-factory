# Charlie-and-the-chat-factory, src/codex-appserver.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region codex app-server, asked a few things ------------------------------------
# codex app-server speaks JSON-RPC over stdio: one JSON object per line each
# way, a request {id, method, params}, its reply {id, result} or {id, error},
# and notifications {method, params} with no id that it sends whenever it
# likes. The VS Code panel runs one per window, privately; chatq starts its
# own for the few questions only it can answer without a model turn - how
# much of the plan is used, which threads there are, how a turn ended.
#
# What a short-lived one does, measured on codex-cli 0.159.2 (TESTING.md,
# S-A4): it answers initialize in about 0.1 s and account/rateLimits/read in
# 0.5 to 1 s. It exits the moment its stdin ends, and a reply still being
# worked out then is never sent - so stdin cannot be written once and closed,
# as Invoke-ChatqProcess does; it stays open until every reply is in. Closed
# after that, the server exits by itself within 50 ms. A rate-limit read left
# auth.json as it was. Started on a CODEX_HOME that is not there, it makes
# one - its state databases and all - so a home that is not there is never
# handed to it.
#
# What chatq leaves out, on purpose: --strict-config (a config.toml field a
# newer panel wrote would fail every read here, for no gain), --no-daemon (a
# stdio app-server is its own server; the flag is for exec and the commands
# that may route through a shared daemon), --listen (stdio is the default),
# and --analytics-default-enabled (the panel's own opt-in, not chatq's). The
# environment is a run's (New-ChatqProcessStartInfo): OPENAI_API_KEY and
# CODEX_API_KEY dropped, so what is read is the ChatGPT login the jobs bill.

function Invoke-ChatqCodexRpc {
    <#
    Starts codex app-server on -CodexHome, says initialize and initialized,
    sends each request, and waits for every reply - then ends the server,
    always, a timeout or an error included. Never throws.

    -Method/-Params for one request; -Calls for several in one start, each
    @{ method = ...; params = ... } (params may be left out). -Experimental
    asks for the experimental methods and fields (thread/queue/*, ...).

    Returns {Ok, Why, Init, Results, Errors, Notes, Asked, Ms, Pid}:
      Ok       every request was answered, with a result or an error
      Why      when not Ok: 'no codex CLI', 'no Codex home at <path>',
               'did not start: ...', 'initialize: <error>', 'timed out',
               'exited'
      Init     initialize's result (userAgent, codexHome, platformOs)
      Results  one per request, in order: its result, $null for one that
               failed or was never answered - the "no data" every caller
               falls back from
      Errors   one per request: the error's message, $null for a result
      Notes    the notifications' method names, in order (skipped)
      Asked    the server's own requests, by method - each refused at once,
               so none waits on an answer chatq never gives
    thread/list always goes with useStateDbOnly:true, whatever was passed:
    left out or false, the server scans every rollout and repairs Codex's
    own thread database from them - a write, from what is meant as a read.
    #>
    param(
        [string]$Method, $Params, [object[]]$Calls,
        [string]$CodexHome = $script:ChatCodexHome,
        [switch]$Experimental, [int]$TimeoutSec = 15
    )
    $s = Start-ChatqCodexRpc @PSBoundParameters
    try {
        # a second at a time: the deadline Start set is what ends a wait
        $r = $null
        while (-not $r) { $r = Step-ChatqCodexRpc $s -WaitMs 1000 }
        return $r
    }
    catch { return (Close-ChatqCodexRpc $s "failed: $($_.Exception.Message)") }
    finally { $null = Close-ChatqCodexRpc $s 'failed: left unfinished' }
}

function Start-ChatqCodexRpc {
    <#
    Invoke-ChatqCodexRpc in pieces, for a caller that cannot wait - the
    Windows panel draws on the thread that asks: this starts the server
    and says initialize; Step-ChatqCodexRpc takes the replies in as they
    come, -WaitMs at a time, and hands back Invoke's result once there is
    one; Close-ChatqCodexRpc ends it early. The same parameters as Invoke;
    -TimeoutSec runs from here, across every Step. Never throws: what
    stops it before a server runs is a session already done, its result
    waiting for the first Step.
    #>
    param(
        [string]$Method, $Params, [object[]]$Calls,
        [string]$CodexHome = $script:ChatCodexHome,
        [switch]$Experimental, [int]$TimeoutSec = 15
    )
    $list = @(@(if ($Method) { @{ method = $Method; params = $Params } }) + @($Calls | Where-Object { $_ }))
    $s = @{
        Sw = [System.Diagnostics.Stopwatch]::StartNew(); List = $list; Proc = $null; Pid = $null
        Phase = 'init'; Deadline = (Get-Date).AddSeconds($TimeoutSec); Done = $null
        Init = @{ Result = $null; Error = $null }
        St = @{
            Want = @{}; Task = $null
            Results = [object[]]::new($list.Count); Errors = [object[]]::new($list.Count)
            Notes = [System.Collections.Generic.List[string]]::new(); Asked = [System.Collections.Generic.List[string]]::new()
        }
    }
    try {
        $exe = Find-ChatqExe codex
        if (-not $exe) { $null = Close-ChatqCodexRpc $s 'no codex CLI'; return $s }
        if (-not $CodexHome) { $CodexHome = Get-ChatqHomeDir 'codex' '' }
        if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) { $null = Close-ChatqCodexRpc $s "no Codex home at $CodexHome"; return $s }
        # older than the floor: not asked at all - it would only answer
        # "unknown variant", a start's worth of nothing. Read again before
        # refusing: the cached version outlives an upgrade in place, and
        # refresh, the way to say "codex is new now", went on refusing
        $v = Get-ChatqCliVersion $exe
        if ($v -and (Compare-ChatVersion $v $script:ChatqCodexAppServerMin) -eq -1) { $v = Get-ChatqCliVersion $exe -Fresh }
        if ($v -and (Compare-ChatVersion $v $script:ChatqCodexAppServerMin) -eq -1) {
            $null = Close-ChatqCodexRpc $s "codex $v is older than $($script:ChatqCodexAppServerMin)"
            return $s
        }
        try {
            $psi = New-ChatqProcessStartInfo -Exe $exe -ArgList @('app-server') -SetEnv @{ CODEX_HOME = $CodexHome }
            $s.Proc = Start-ChatqProcess $psi
            $s.Pid = $s.Proc.Id
        }
        catch { $null = Close-ChatqCodexRpc $s "did not start: $($_.Exception.Message)"; return $s }
        # stderr read to its end beside: a full pipe would stall the server
        $null = $s.Proc.StandardError.ReadToEndAsync()
        $info = [ordered]@{ name = 'chatq'; version = $(if ($script:ChatVersion) { [string]$script:ChatVersion } else { '0' }) }
        $init = [ordered]@{ clientInfo = $info }
        if ($Experimental) { $init['capabilities'] = [ordered]@{ experimentalApi = $true } }
        $s.St.Want['0'] = -1
        if (-not (Send-ChatqCodexRpcLine $s.Proc ([ordered]@{ id = 0; method = 'initialize'; params = $init }))) { $null = Close-ChatqCodexRpc $s 'exited' }
    }
    catch { $null = Close-ChatqCodexRpc $s "failed: $($_.Exception.Message)" }
    return $s
}

function Step-ChatqCodexRpc {
    <#
    Takes in what the server of a Start-ChatqCodexRpc session has said,
    waiting up to -WaitMs for more; 0 reads only what is there already.
    $null while replies are still owed and its deadline is ahead; else the
    result, the server ended. Once initialize is answered the requests go
    out, all at once - the server works them side by side. -ExitWaitMs
    goes to Close-ChatqCodexRpc as the session ends: a panel's pass gives
    the server less time to leave by itself than a caller that can wait.
    #>
    param($S, [int]$WaitMs = 0, [int]$ExitWaitMs = 2000)
    if ($S.Done) { return $S.Done }
    $close = { param($why) Close-ChatqCodexRpc $S $why -ExitWaitMs $ExitWaitMs }
    try {
        $until = (Get-Date).AddMilliseconds($WaitMs)
        if ($S.Phase -eq 'init') {
            $why = Receive-ChatqCodexRpc $S.Proc $S.St $S.Deadline -Init $S.Init -Until $until
            if ($why -eq 'pending') { return $null }
            if ($why) { return (& $close $why) }
            if ($S.Init.Error) { return (& $close "initialize: $($S.Init.Error)") }
            if (-not (Send-ChatqCodexRpcLine $S.Proc ([ordered]@{ method = 'initialized' }))) { return (& $close 'exited') }
            for ($i = 0; $i -lt $S.List.Count; $i++) {
                $m = [string](Get-ChatField $S.List[$i] 'method')
                $msg = [ordered]@{ id = $i + 1; method = $m }
                $pa = Get-ChatqCodexRpcParams $m (Get-ChatField $S.List[$i] 'params')
                if ($null -ne $pa) { $msg['params'] = $pa }
                $S.St.Want[[string]($i + 1)] = $i
                if (-not (Send-ChatqCodexRpcLine $S.Proc $msg)) { return (& $close 'exited') }
            }
            $S.Phase = 'ask'
        }
        $why = Receive-ChatqCodexRpc $S.Proc $S.St $S.Deadline -Until $until
        if ($why -eq 'pending') { return $null }
        return (& $close $why)
    }
    catch { return (& $close "failed: $($_.Exception.Message)") }
}

function Close-ChatqCodexRpc {
    <#
    Ends a Start-ChatqCodexRpc session's server and keeps its result: Ok
    when -Why is empty. A session already done keeps the result it has, so
    a second close - a finally after the answer - changes nothing.
    -ExitWaitMs: how long the server gets to leave by itself first.
    #>
    param($S, [string]$Why, [int]$ExitWaitMs = 2000)
    if ($S.Done) { return $S.Done }
    $p = $S.Proc
    if ($p) {
        # End of stdin is the server's own way out; one that is still there a
        # moment later - hung on a request, or never read its input - is
        # ended with all it started
        try { $p.StandardInput.Close() } catch {}
        $gone = try { $p.WaitForExit($ExitWaitMs) } catch { $false }
        if (-not $gone) { Stop-ChatqTree $p; try { [void]$p.WaitForExit(5000) } catch {} }
        try { $p.Dispose() } catch {}
        $S.Proc = $null
    }
    $S.Phase = 'done'
    # initialize's answer only once it was a good one
    $init = if ($S.Init.Error) { $null } else { $S.Init.Result }
    $S.Done = [pscustomobject]@{ Ok = (-not $Why); Why = $(if ($Why) { $Why } else { $null }); Init = $init
        Results = $S.St.Results; Errors = $S.St.Errors; Notes = @($S.St.Notes); Asked = @($S.St.Asked)
        Ms = [int]$S.Sw.ElapsedMilliseconds; Pid = $S.Pid
    }
    return $S.Done
}

function Get-ChatqCodexRpcParams {
    # A request's params as they go out: thread/list's with useStateDbOnly
    # forced on (Invoke-ChatqCodexRpc says why), every other as given
    param([string]$Method, $Params)
    if ($Method -ne 'thread/list') { return $Params }
    $out = [ordered]@{}
    if ($Params -is [System.Collections.IDictionary]) { foreach ($k in $Params.Keys) { $out[[string]$k] = $Params[$k] } }
    elseif ($null -ne $Params) { foreach ($pr in $Params.PSObject.Properties) { $out[$pr.Name] = $pr.Value } }
    $out['useStateDbOnly'] = $true
    return $out
}

function Send-ChatqCodexRpcLine {
    # One message, one line, as raw UTF-8 bytes (Start-ChatqProcess says
    # why). $false when it cannot be written: the server has gone, and its
    # pipe with it.
    param($Proc, $Message)
    $b = (New-Object System.Text.UTF8Encoding $false).GetBytes((ConvertTo-Json $Message -Compress -Depth 20) + "`n")
    try {
        $Proc.StandardInput.BaseStream.Write($b, 0, $b.Length)
        $Proc.StandardInput.BaseStream.Flush()
        return $true
    }
    catch { return $false }
}

function Receive-ChatqCodexRpc {
    <#
    Reads the server's lines until every id in $State.Want is answered;
    $null then, else 'timed out' or 'exited'. A reply goes into $State's
    Results or Errors by its slot - or into -Init for initialize's, slot -1.
    A notification is noted and skipped. A request from the server is
    refused at once. A line that is no JSON is skipped; a reply that will
    not parse, but whose id can be read, counts as answered with an error,
    so one odd reply never waits out the timeout.
    -Until, sooner than -Deadline: 'pending' once it passes with replies
    still owed - a Step that may wait only so long. A line already in is
    taken past it all the same, so a poll that waits 0 ms still reads.
    #>
    param($Proc, $State, [datetime]$Deadline, [hashtable]$Init, $Until)
    while ($State.Want.Count) {
        if (-not $State.Task) { $State.Task = $Proc.StandardOutput.ReadLineAsync() }
        $now = Get-Date
        if ($now -ge $Deadline) { return 'timed out' }
        if (-not $State.Task.IsCompleted) {
            $end = if ($Until -is [datetime] -and $Until -lt $Deadline) { $Until } else { $Deadline }
            $left = ($end - $now).TotalMilliseconds
            if ($left -le 0) { return 'pending' }
            # waited a second at a time, so the deadline is looked at even
            # while the server says nothing
            $ready = $false
            try { $ready = $State.Task.Wait([int][Math]::Max(1, [Math]::Min($left, 1000))) } catch { return 'exited' }
            if (-not $ready) { continue }
        }
        if ($State.Task.IsFaulted -or $State.Task.IsCanceled) { return 'exited' }
        $line = $State.Task.Result
        $State.Task = $null
        if ($null -eq $line) { return 'exited' }
        if (-not $line.Trim()) { continue }
        $m = try { $line | ConvertFrom-Json } catch { $null }
        if (-not $m) {
            # codex writes its id first or last: {"id":3,"result":...} and
            # {"error":{...},"id":3} both
            $key = if ($line -match '^\{"id":(\d+),') { $Matches[1] } elseif ($line -match ',"id":(\d+)\}\s*$') { $Matches[1] } else { $null }
            if ($null -ne $key -and $State.Want.ContainsKey($key)) {
                $slot = $State.Want[$key]
                $State.Want.Remove($key)
                if ($slot -lt 0) { $Init.Error = 'a reply that could not be read' } else { $State.Errors[$slot] = 'a reply that could not be read' }
            }
            continue
        }
        $id = Get-ChatField $m 'id'
        $method = Get-ChatField $m 'method'
        if ($method) {
            if ($null -ne $id) {
                $null = Send-ChatqCodexRpcLine $Proc ([ordered]@{ id = $id; error = [ordered]@{ code = -32601; message = 'chatq answers no requests' } })
                $State.Asked.Add([string]$method)
            }
            else { $State.Notes.Add([string]$method) }
            continue
        }
        if ($null -eq $id) { continue }
        $key = [string]$id
        if (-not $State.Want.ContainsKey($key)) { continue }
        $slot = $State.Want[$key]
        $State.Want.Remove($key)
        $err = Get-ChatField $m 'error'
        $say = if ($null -ne $err) { $t = [string](Get-ChatField $err 'message'); if ($t) { $t } else { 'error' } } else { $null }
        if ($slot -lt 0) { $Init.Error = $say; $Init.Result = $(if ($null -eq $err) { Get-ChatField $m 'result' }) }
        elseif ($null -ne $err) { $State.Errors[$slot] = $say }
        else { $State.Results[$slot] = Get-ChatField $m 'result' }
    }
    return $null
}

#endregion
