# tests/vectors/overlay-snapshot.ps1: native/vectors/overlay-snapshot.json,
# data/overlay.json as each PowerShell writes it (native/SPEC.md "M9: the
# overlay's snapshot"). Every case is by its edition: input.text is
# ConvertTo-Json -Depth 6 -Compress - Invoke-ChatOverlayCycle's own call -
# of a snapshot built here in the cycle's shape, the headless host's ui and
# events with it. The answer is what a reader takes from that text: the
# schema and version, each row's key and title, Recent's, the usage line,
# the events' ids and kinds, ui.spin, and every place a value went deeper
# than 6 and was written as its .NET name instead ("@{...}",
# "System.Collections.Hashtable") - the Rust reader names the same places
# (native/overlay/src/snapshot.rs).

function New-NvOverlaySnapRow([string]$Key, [string]$Title, $Extra) {
    # a row as Get-ChatOverlayRows makes one, the nested parts with it
    $r = [ordered]@{
        key = $Key; kind = 'session'; provider = 'Claude'; status = 'idle'; chat = 'idle'; title = $Title; project = 'proj'
        prompt = 'last prompt'; stateText = 'idle 3m'; since = 1760490000000; sessionId = 'sid'; cwd = 'D:\work\proj'; where = 'vscode'; unread = $false
        auto = [ordered]@{ state = 'armed'; at = '13:00'; why = $null }
        background = @([ordered]@{ kind = 'workflow'; name = 'nightly' })
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] } }
    return [pscustomobject]$r
}

function New-NvOverlaySnap($Rows, [switch]$Headless) {
    # the cycle's snapshot, as pscustomobjects and hashtables are mixed in it
    $u = [pscustomobject]@{ provider = 'Claude'; status = 'live'; stale = $false
        windows = @([pscustomobject]@{ label = '5h'; percent = 42; severity = 'normal'; limited = $false; resetsAt = 1760500000000 }) }
    $header = [pscustomobject]@{
        usage = @($u); usageText = "Claude 5h 42%"; usageWhy = $null
        reload = @([pscustomobject]@{ pid = 4321; window = 'proj - Visual Studio Code'; id = '4321-1-k2'; state = 'asked'; say = 'reload?'; text = 'Reload to apply'; count = 1 })
        liveHold = $null; next = '14:05'; watcher = 'running'; error = $null
        notes = @([pscustomobject]@{ kind = 'ask'; text = 'two chats can continue'; tone = 'warn' })
        memory = $null; leaks = @()
        ask = [pscustomobject]@{ count = 2; resetsAt = 1760500000000; keys = @('k1', 'k2'); restart = 0; cause = ''; titles = @('one', 'two'); left = @() }
        autoContinue = 'ask'; autoOn = $false
    }
    $snap = [pscustomobject]@{
        schema = 1; version = '0.10.22'; pid = 1234; at = 1760490123123
        header = $header
        counts = [pscustomobject]@{ waiting = 0; busy = 0; idle = @($Rows).Count; running = 0; queued = 0; needsInput = 0; cutOff = 0; unread = 0; auto = 0 }
        config = [pscustomobject]@{ maxRows = 8; recent = 3; opacity = 0.9; theme = 'dark'; autoContinue = 'ask'; restartMB = 400 }
        commands = @([pscustomobject]@{ id = 1; verb = 'lock'; at = 1760490120000 })
        rows = @($Rows)
        recent = @([pscustomobject]@{ title = (U '\uCD5C\uADFC \uCC44\uD305'); project = 'old'; stateText = '2h'; sessionId = 'r1'; cwd = 'D:\old'; since = 1760480000000 })
        recentMore = @()
    }
    if ($Headless) {
        $snap | Add-Member -NotePropertyName ui -NotePropertyValue ([pscustomobject]@{ spin = $true })
        $snap | Add-Member -NotePropertyName events -NotePropertyValue @(
            [pscustomobject][ordered]@{ id = '1760490000000-1'; at = 1760490001000; kind = 'balloon'; click = 'ask'; icon = 'None'; keys = @('k1', 'k2'); ms = 10000; text = 'two chats can continue'; title = 'Charlie' })
    }
    return $snap
}

function Get-NvOverlaySnapDeep($V, [string]$Path, $Out) {
    # every string a too-deep value was written as, by its path
    if ($V -is [string]) {
        if ($V.StartsWith('@{') -or $V -ceq 'System.Collections.Hashtable' -or $V -ceq 'System.Collections.Specialized.OrderedDictionary') { [void]$Out.Add($Path) }
        return
    }
    if ($null -eq $V -or $V -is [bool] -or $V -is [ValueType]) { return }
    if ($V.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        foreach ($p in $V.PSObject.Properties) { Get-NvOverlaySnapDeep $p.Value $(if ($Path) { "$Path.$($p.Name)" } else { $p.Name }) $Out }
        return
    }
    if ($V -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($x in $V) { Get-NvOverlaySnapDeep $x "$Path[$i]" $Out; $i++ }
    }
}

Register-NvVector -Name 'overlay-snapshot' -About "data/overlay.json as each PowerShell's ConvertTo-Json -Depth 6 -Compress writes the cycle's snapshot (by edition): what a reader takes from it - schema, version, rows' keys and titles, Recent's titles, the usage line, the events' ids and kinds, ui.spin - and every path whose value went past depth 6 and was written as its .NET name" -Cases {
    $ed = $script:NvEdition
    $hangul = U '\uD55C\uAE00 \uCC44\uD305 \uB300\uAE30\uC5F4'
    $plain = @((New-NvOverlaySnapRow 's:a1' 'first chat' $null), (New-NvOverlaySnapRow 'j:7' $hangul ([ordered]@{ kind = 'job' })))
    # a row with a value one level past what the cycle's depth writes whole
    $deep = New-NvOverlaySnapRow 's:d1' 'too deep' ([ordered]@{ background = @([ordered]@{ kind = 'workflow'; detail = [ordered]@{ steps = @([ordered]@{ more = [ordered]@{ x = 1 } }) } }) })
    $odd = New-NvOverlaySnapRow 'c:q"1' ('quote " back \ slash <tag> & ' + [char]0x2026) $null
    foreach ($c in @(
            @('the WPF host''s', (New-NvOverlaySnap $plain)),
            @('the headless host''s', (New-NvOverlaySnap $plain -Headless)),
            @('no rows', (New-NvOverlaySnap @() -Headless)),
            @('a row too deep', (New-NvOverlaySnap @($deep) -Headless)),
            @('escapes', (New-NvOverlaySnap @($odd) -Headless)))) {
        [ordered]@{
            name  = "$ed $($c[0])"
            by    = $ed
            input = [ordered]@{ text = (ConvertTo-Json $c[1] -Depth 6 -Compress -WarningAction SilentlyContinue) }
        }
    }
} -Expect {
    param($In, $Name)
    $v = Read-NvJson ([string]$In.text)
    $deep = New-Object System.Collections.Generic.List[string]
    Get-NvOverlaySnapDeep $v '' $deep
    # ordinal order, as the Rust reader sorts the paths it finds
    $deepAt = $deep.ToArray()
    [Array]::Sort($deepAt, [StringComparer]::Ordinal)
    $ui = if ($null -ne $v.PSObject.Properties['ui']) { [bool]$v.ui.spin } else { $null }
    return [ordered]@{
        schema    = [int]$v.schema
        version   = [string]$v.version
        rowKeys   = @(@($v.rows) | ForEach-Object { [string]$_.key })
        rowTitles = @(@($v.rows) | ForEach-Object { [string]$_.title })
        recent    = @(@($v.recent) + @($v.recentMore) | Where-Object { $_ } | ForEach-Object { [string]$_.title })
        usageText = [string]$v.header.usageText
        events    = @(@($v.events) | Where-Object { $_ } | ForEach-Object { "$($_.id) $($_.kind)" })
        spin      = $ui
        deep      = @($deepAt)
    }
}
