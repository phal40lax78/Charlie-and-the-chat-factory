# tests/vectors/stream-state.ps1: native/vectors/stream-state.json (SPEC 2.9,
# 3.8, 6.1). St as Update-ChatqClaudeState and Update-ChatqCodexState
# (src/queue.ps1) build it from New-ChatqRunState, line by line, over the
# stream fixtures in tests/fixtures/stream/ and over lines made to sit on
# each edge of the two functions: the 1 MB cap, the pre-filter, each
# PowerShell's JSON parse, the switch, -eq, [string] and member
# enumeration, the two regexes. Every answer is St as SPEC 3.8 carries it
# to the post-run step, first rebuilt from that JSON here, in PowerShell,
# and compared with the real St (Test-NvStreamStateRebuild): the carried
# form loses nothing.
#
# A case's input is {provider: claude|codex, lines, [each | fresh],
# [fields]}. A line is a string, or a recipe {parts: [[text, count], ...],
# length}: each text count times, length UTF-16 units in all (a 1 MB line
# is never written out). The answer is St after the last line; with each,
# the list of St after every line; with fresh, each item of lines - a line,
# or a list of lines - runs from its own New-ChatqRunState, and the answer
# is the list of St after each item. fields keeps only those fields, in
# that order.

function Join-NvStreamStateText {
    # text from pieces: an [int] is a code point, anything else its own text
    return (-join @(foreach ($p in $args) { if ($p -is [int]) { [char]::ConvertFromUtf32($p) } else { [string]$p } }))
}

function Format-NvStreamStateText([string]$S) {
    # $S inside a JSON string as a stream writes it: quote, backslash and
    # control characters escaped, every other character as it is
    $b = New-Object System.Text.StringBuilder
    foreach ($c in $S.ToCharArray()) {
        $n = [int]$c
        if ($n -eq 0x22) { [void]$b.Append('\"') }
        elseif ($n -eq 0x5C) { [void]$b.Append('\\') }
        elseif ($n -lt 0x20 -or ($n -ge 0x7F -and $n -le 0x9F) -or $n -eq 0x2028 -or $n -eq 0x2029) { [void]$b.Append('\u').Append($n.ToString('x4')) }
        else { [void]$b.Append($c) }
    }
    return $b.ToString()
}

function Get-NvStreamStateFixture([string]$Name) {
    # tests/fixtures/stream/<Name>.jsonl as lines, its placeholders filled as
    # the suite fills them but with fixed values: no clock, no run
    $path = Join-Path (Join-Path (Join-Path $here 'fixtures') 'stream') "$Name.jsonl"
    $text = [IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding $false))
    $text = $text.Replace('{{SESSION}}', '11111111-2222-4333-8444-555555555555').Replace('{{RESETS}}', '1790000000').Replace('{{LONG}}', ('z' * 400))
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "`n")) { $list.Add($l.TrimEnd("`r")) }
    if ($list.Count -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    return , $list.ToArray()
}

function Get-NvStreamStateTurn([string]$Content, [string]$Model) {
    # an assistant line: $Content is its content list's items, $Model the
    # model's JSON (none when not given)
    $m = if ($Model) { '"model":' + $Model + ',' } else { '' }
    return '{"type":"assistant","message":{' + $m + '"content":[' + $Content + ']}}'
}

function Get-NvStreamStateSynthetic([string]$Text) {
    # a <synthetic> assistant line saying $Text, as Claude Code writes a limit
    # or an API error
    return (Get-NvStreamStateTurn ('{"type":"text","text":"' + (Format-NvStreamStateText $Text) + '"}') '"<synthetic>"')
}

function New-NvStreamStateRecipe([object[]]$Parts) {
    # a line made of parts, each @(text, count): text count times
    $len = 0
    $list = @(foreach ($p in $Parts) {
            $len += ([string]$p[0]).Length * [int]$p[1]
            , @([string]$p[0], [int]$p[1])
        })
    return [ordered]@{ parts = $list; length = $len }
}

function New-NvStreamStateLong([string]$Head, [string]$Fill, [string]$Tail, [int]$Length) {
    # a line of $Length UTF-16 units: $Head, z to make up the rest, $Fill as
    # many times as fits, $Tail
    $room = $Length - $Head.Length - $Tail.Length
    $count = [int][Math]::Floor($room / $Fill.Length)
    return (New-NvStreamStateRecipe @(@($Head, 1), @('z', ($room - $count * $Fill.Length)), @($Fill, $count), @($Tail, 1)))
}

function New-NvStreamStateCase([string]$Name, [string]$Provider, $Lines, [string[]]$Fields, [switch]$Each, [switch]$Fresh) {
    $in = [ordered]@{ provider = $Provider; lines = @($Lines) }
    if ($Each) { $in['each'] = $true }
    if ($Fresh) { $in['fresh'] = $true }
    if ($Fields) { $in['fields'] = @($Fields) }
    return [ordered]@{ name = $Name; input = $in }
}

function Get-NvStreamStateKeys {
    # New-ChatqRunState's fields in its order: St's keys on the wire
    return @('Init', 'Started', 'Session', 'Model', 'Mode', 'Version', 'Limit', 'Rate', 'SyntheticLimit', 'Overloaded',
        'Retries', 'Assistant', 'LastText', 'Tools', 'Denied', 'Result', 'ToolIds', 'PermitServer', 'Thread',
        'TurnStarted', 'TurnDone', 'TurnFailed', 'Failed')
}

function Get-NvStreamStateLine($L) {
    # a line as read back from the input: a string, or a recipe made
    if ($L -is [string]) { return $L }
    $b = New-Object System.Text.StringBuilder
    foreach ($p in @($L.parts)) { [void]$b.Append(([string]$p[0]) * [int]$p[1]) }
    $s = $b.ToString()
    if ($s.Length -ne [int]$L.length) { throw "a recipe makes $($s.Length) UTF-16 units, not $($L.length)" }
    return $s
}

function Get-NvStreamStateStream($S) {
    # a stream's lines: one line, or a list of them
    if ($S -is [string] -or $S -isnot [System.Collections.IList]) { return , @(Get-NvStreamStateLine $S) }
    return , @(foreach ($l in $S) { Get-NvStreamStateLine $l })
}

function Invoke-NvStreamStateLine($St, [string]$Line, [string]$Provider, $Raw) {
    # $Line through the tool's own function. Result, Rate and Limit hold a
    # marker meanwhile: Update-* only ever assigns them, so one the call
    # replaced came from this line, which is what SPEC 3.8 carries for it,
    # and one still holding the marker gets its old value back
    $mark = [object]::new()
    foreach ($k in 'Result', 'Rate', 'Limit') { $St[$k] = $mark }
    if ($Provider -eq 'codex') { Update-ChatqCodexState $St $Line } else { Update-ChatqClaudeState $St $Line }
    foreach ($k in 'Result', 'Rate', 'Limit') {
        if ([object]::ReferenceEquals($St[$k], $mark)) { $St[$k] = $Raw[$k].Value; continue }
        $Raw[$k] = @{ Value = $St[$k]; Line = $(if ($null -eq $St[$k]) { $null } else { $Line }) }
    }
}

function ConvertTo-NvStreamStateJson($St, $Raw) {
    # St as SPEC 3.8 carries it: every field by its PS name, scalars and lists
    # as JSON values, ToolIds an object, Result, Rate and Limit the raw line
    # each came from (null when the field is)
    $keys = Get-NvStreamStateKeys
    $have = @($St.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($have -join ',') -cne (@($keys | Sort-Object) -join ',')) { throw "New-ChatqRunState's fields are now $($have -join ', '): carry each new one in St's JSON" }
    $o = [ordered]@{}
    foreach ($k in $keys) {
        $v = $St[$k]
        if ($k -eq 'Result' -or $k -eq 'Rate' -or $k -eq 'Limit') { $o[$k] = $Raw[$k].Line }
        elseif ($k -eq 'Tools' -or $k -eq 'Denied') { $o[$k] = $v.ToArray() }
        elseif ($k -eq 'ToolIds') { $o[$k] = $v.Clone() }
        else { $o[$k] = $v }
    }
    return $o
}

function Compare-NvStreamStateValue($A, $B, [string]$At) {
    # the same value: type for type, keys and properties in their casing
    if ($null -eq $A -or $null -eq $B) {
        if ($null -ne $A -or $null -ne $B) { throw "St rebuilt from its JSON differs at ${At}: null on one side" }
        return
    }
    if ($A.GetType() -ne $B.GetType()) { throw "St rebuilt from its JSON differs at ${At}: $($A.GetType().FullName), not $($B.GetType().FullName)" }
    if ($A -is [System.Collections.IDictionary]) {
        [string[]]$ka = @($A.Keys)
        [string[]]$kb = @($B.Keys)
        [Array]::Sort($ka, [StringComparer]::Ordinal)
        [Array]::Sort($kb, [StringComparer]::Ordinal)
        if (($ka -join "`n") -cne ($kb -join "`n")) { throw "St rebuilt from its JSON differs at ${At}: its keys" }
        foreach ($k in $ka) { Compare-NvStreamStateValue $A[$k] $B[$k] "$At.$k" }
        return
    }
    if ($A.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $pa = @($A.PSObject.Properties)
        $pb = @($B.PSObject.Properties)
        if ($pa.Count -ne $pb.Count) { throw "St rebuilt from its JSON differs at ${At}: its properties" }
        for ($i = 0; $i -lt $pa.Count; $i++) {
            if ($pa[$i].Name -cne $pb[$i].Name) { throw "St rebuilt from its JSON differs at ${At}: property $($pa[$i].Name)" }
            Compare-NvStreamStateValue $pa[$i].Value $pb[$i].Value "$At.$($pa[$i].Name)"
        }
        return
    }
    if ($A -is [System.Collections.IList]) {
        if ($A.Count -ne $B.Count) { throw "St rebuilt from its JSON differs at ${At}: its length" }
        for ($i = 0; $i -lt $A.Count; $i++) { Compare-NvStreamStateValue $A[$i] $B[$i] ($At + '[' + $i + ']') }
        return
    }
    if (-not $A.Equals($B)) { throw "St rebuilt from its JSON differs at ${At}" }
}

function Test-NvStreamStateRebuild($St, $Json) {
    # SPEC 3.8's post-run side, as that step will do it: St made again from
    # its JSON, each raw line back through ConvertFrom-Json and Rate and Limit
    # taking .rate_limit_info as PS did, must be the St the functions built
    $back = Read-NvJson (ConvertTo-NvJson $Json -Compress)
    $r = New-ChatqRunState
    foreach ($k in 'Init', 'Started', 'TurnStarted', 'TurnDone') { $r[$k] = [bool]$back.$k }
    foreach ($k in 'Retries', 'Assistant') { $r[$k] = [int]$back.$k }
    foreach ($k in 'Session', 'Model', 'Mode', 'Version', 'LastText', 'SyntheticLimit', 'Overloaded', 'PermitServer', 'Thread', 'TurnFailed', 'Failed') { $r[$k] = $back.$k }
    foreach ($x in @($back.Tools)) { $r.Tools.Add([string]$x) }
    foreach ($x in @($back.Denied)) { $r.Denied.Add([string]$x) }
    foreach ($p in @($back.ToolIds.PSObject.Properties)) { $r.ToolIds[$p.Name] = [string]$p.Value }
    if ($null -ne $back.Result) { $r.Result = $back.Result | ConvertFrom-Json }
    foreach ($k in 'Rate', 'Limit') { if ($null -ne $back.$k) { $r[$k] = ($back.$k | ConvertFrom-Json).rate_limit_info } }
    Compare-NvStreamStateValue $St $r 'St'
}

function Get-NvStreamStateAnswer($St, $Raw, [string[]]$Fields) {
    # St's JSON, proved to rebuild into St, then only $Fields when given
    $o = ConvertTo-NvStreamStateJson $St $Raw
    Test-NvStreamStateRebuild $St $o
    if (-not $Fields) { return $o }
    $p = [ordered]@{}
    foreach ($f in $Fields) {
        if (-not $o.Contains($f)) { throw "St has no field '$f'" }
        $p[$f] = $o[$f]
    }
    return $p
}

function Invoke-NvStreamStateRun([string]$Provider, $Lines, [string[]]$Fields, [bool]$Each) {
    # one stream from a new St: St after it, or with $Each after each line
    $st = New-ChatqRunState
    $raw = @{}
    foreach ($k in 'Result', 'Rate', 'Limit') { $raw[$k] = @{ Value = $null; Line = $null } }
    $snaps = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Lines) {
        Invoke-NvStreamStateLine $st $line $Provider $raw
        if ($Each) { $snaps.Add((Get-NvStreamStateAnswer $st $raw $Fields)) }
    }
    if ($Each) { return , $snaps.ToArray() }
    return (Get-NvStreamStateAnswer $st $raw $Fields)
}

Register-NvVector -Name 'stream-state' -About ('Update-ChatqClaudeState / Update-ChatqCodexState (src/queue.ps1, by input.provider) from New-ChatqRunState, fed input.lines in order. ' +
    'A line is a string, or a recipe {parts: [[text, count], ...], length}: each text count times, length UTF-16 units in all. ' +
    'The answer is St after the last line; with input.each, the list of St after each line; with input.fresh, each item of input.lines ' +
    '(a line, or a list of lines) runs from its own New-ChatqRunState and the answer is the list of St after each item. ' +
    'input.fields keeps only those fields, in that order. ' +
    'St is SPEC 3.8''s transport: each New-ChatqRunState field by its own name, in its order; scalars and lists as JSON values; ToolIds an object; ' +
    'Result, Rate and Limit the raw line each was set from, or null. Each answer was rebuilt from that JSON in PowerShell ' +
    '(the raw lines through ConvertFrom-Json, .rate_limit_info for Rate and Limit) and compared with the real St. ' +
    'Started stays false: the run''s OnLine sets it, not these functions. Made under en-US.') -Cases {
    $sid = '11111111-2222-4333-8444-555555555555'
    $shy = Join-NvStreamStateText 0xAD

    # --- the fixtures: whole streams, the whole St ---------------------------------
    # one of each shape (the rest of tests/fixtures/stream/ repeats these
    # shapes with other texts)
    foreach ($f in 'watch-claude', 'asks', 'auth-403', 'denied', 'error', 'noresult', 'overage-success', 'rejected', 'weekly-synthetic') {
        New-NvStreamStateCase "fixture $f" 'claude' (Get-NvStreamStateFixture $f)
    }
    foreach ($f in 'watch-codex', 'codex-badrequest', 'codex-limit', 'codex-overload', 'codex-retry-done') {
        New-NvStreamStateCase "fixture $f" 'codex' (Get-NvStreamStateFixture $f)
    }
    # line by line: St after each line is what the run's OnLine sees (the
    # first Init starts the run)
    New-NvStreamStateCase 'fixture overloaded, line by line' 'claude' (Get-NvStreamStateFixture 'overloaded') -Each -Fields 'Init', 'Retries', 'Assistant', 'Overloaded'

    # --- init and the permission bridge ------------------------------------------
    $i0 = '{"type":"system","subtype":"init","session_id":"' + $sid + '","model":"claude-fake-1","permissionMode":"default","claude_code_version":"2.1.278"'
    New-NvStreamStateCase 'init, chatqpermit connected' 'claude' @($i0 + ',"mcp_servers":[{"name":"chatqpermit","status":"connected"}]}') -Fields 'Init', 'Session', 'Model', 'Mode', 'Version', 'PermitServer'
    New-NvStreamStateCase 'init twice keeps the permit server' 'claude' @(($i0 + ',"mcp_servers":[{"name":"chatqpermit","status":"connected"}]}'), '{"type":"system","subtype":"init","session_id":"second","mcp_servers":[]}') -Fields 'Session', 'Model', 'PermitServer'
    New-NvStreamStateCase 'init, fields of any JSON type' 'claude' @('{"type":"system","subtype":"init","session_id":5,"model":["a",1,null],"permissionMode":{"k":"v","n":[true]},"claude_code_version":1.5}') -Fields 'Session', 'Model', 'Mode', 'Version'
    New-NvStreamStateCase 'init, keys in any case' 'claude' @('{"type":"system","Subtype":"init","Session_ID":"s","MODEL":"m"}') -Fields 'Init', 'Session', 'Model'
    # the first server named chatqpermit (-eq: any case, any item of a list)
    # gives PermitServer its status as [string]
    $i1 = '{"type":"system","subtype":"init","mcp_servers":'
    New-NvStreamStateCase 'init, mcp_servers forms' 'claude' @(foreach ($v in '[{"name":"chatqpermit","status":"failed"}]', '[{"name":"github","status":"connected"}]', '[]', 'null',
            '{"name":"chatqpermit","status":"connected"}', '[{"name":"other","status":"x"},{"name":"ChatqPermit","status":"failed"},{"name":"chatqpermit","status":"connected"}]',
            '[null,"",0,"chatqpermit",{"name":"chatqpermit"}]', '[{"name":"chatqpermit","status":3}]', '[{"name":"chatqpermit","status":{"state":"connected","tries":2}}]',
            '[{"name":true,"status":"x"}]', '[{"name":false,"status":"x"}]', '[{"name":["github","chatqpermit"],"status":"listed"}]', '[{"name":[["chatqpermit"]],"status":"nested"}]',
            '[[{"name":"chatqpermit","status":"a"},{"name":"x","status":"b"}]]', '[[{"name":"chatqpermit","status":"a"}]]', '[{"name":"chatqpermit","status":["a","b"]}]',
            '[{"name":"chatqpermit","status":null}]', '[{"name":"chatqpermit","status":""}]') { $i1 + $v + '}' }) -Fresh -Fields 'PermitServer'
    New-NvStreamStateCase 'init, subtype forms' 'claude' @(foreach ($v in '"INIT"', '["other","init"]', '["init","init"]', 'true', 'false', '5', '{"init":1}', '[["init"]]', 'null', '" init"',
            ('"in' + $shy + 'it"'), '"init\u0000"') { '{"type":"system","subtype":' + $v + ',"session_id":"s"}' }) -Fresh -Fields 'Init', 'Session'

    # --- permission_denied: tool_name truthy, then [string] ----------------------
    $d0 = '{"type":"system","subtype":"permission_denied","tool_name":'
    New-NvStreamStateCase 'denied, tool_name forms' 'claude' (@('{"type":"system","subtype":"permission_denied","tool_use_id":"toolu_1"}') + @(foreach ($v in '"Write"', '""', '7', '0', 'true', 'false', 'null',
                '12345678901234', '{"a":1,"b":[1,2],"c":null,"d":true,"e":{"f":"g"},"s":"x y","n":-7,"t":false,"ea":[],"eo":{}}', '{}', '["a",{"k":1},null,2,true,false,""]',
                '["only"]', '["",""]', '[""]', '[]', '[["a","b"]]', '[[null]]', '[[[]]]', '[[0]]', '[[""]]', '[[]]', '[{}]', '[false]', '[0.0]', "'single'") { $d0 + $v + '}' })) -Fresh -Fields 'Denied'
    New-NvStreamStateCase 'denied, twice, subtype in capitals' 'claude' @(($d0 + '"Write"}'), '{"type":"system","subtype":"PERMISSION_DENIED","tool_name":"Bash"}') -Fields 'Denied'
    # numbers as each PowerShell's JSON reads them, then as [string] renders
    # them: 5.1 reads 1.5 as a decimal, pwsh 7 as a double; - and twenty
    # digits as an Int32 in 5.1, a BigInteger in pwsh 7 however small
    New-NvStreamStateCase 'denied, tool_name numbers' 'claude' @(foreach ($n in '-5', '1.5', '0.1', '1e2', '1.5E+3', '3.0000000000000004e-1', '1.5e300', '1e-4', '1e-5', '1e15',
            '1.23456789012345e14', '1e21', '2.5e-10', '9223372036854775807', '9223372036854775808', '12345678901234567890', '007', '-010', '.5', '-.5', '5.', '0.5e1',
            '5.e1', '-0', '-0.0', '00', '0e5', 'NaN', 'Infinity', '-Infinity', '1.2.3', '1e', 'infinity', '+Infinity', '-00000000000000000000', '-00000000000000000001') { $d0 + $n + '}' }) -Fresh -Fields 'Denied'
    New-NvStreamStateCase 'denied, tool_name numbers by edition' 'claude' @(foreach ($n in '1.0', '1.50', '5-', '+5', '+.5', '79228162514264337593543950336', '1E400', '-1E400',
            '010', '08', '0x10', '0x1F', '0xFFFFFFFFFFFFFFFF') { $d0 + $n + '}' }) -Fresh -Fields 'Denied'

    # --- api_retry, and the switch over the type ---------------------------------
    $r0 = '{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":1000,"error_status":529,"error":"overloaded","session_id":"' + $sid + '"}'
    New-NvStreamStateCase 'retry, three' 'claude' @($r0, $r0, $r0) -Fields 'Retries'
    New-NvStreamStateCase 'retry, subtype forms' 'claude' @('{"type":"system","subtype":"API_RETRY"}', '{"type":"system","subtype":"compact_boundary"}', '{"type":"system","subtype":"hook_response"}',
        '{"type":"system"}', ('{"type":"system","subtype":"api' + $shy + '_retry"}'), '{"type":"system","subtype":"api_retry\u0000"}', '{"type":"system","subtype":["api_retry","API_RETRY"]}') -Fresh -Fields 'Init', 'Retries', 'Denied'
    # each item of a type list, one level down, as [string] against each
    # clause; the x key gets a line past the pre-filter
    $x = ',"subtype":"api_retry","x":{"type":"result"}}'
    New-NvStreamStateCase 'switch, type forms' 'claude' @(foreach ($v in 'true', 'false', '5', '{"k":"result"}', '[["result"]]', '[true]', 'null', '[]', '["system","SYSTEM"]',
            '["system","result"]', '[null,"system"]', '"SYSTEM"', ('"sys' + $shy + 'tem"'), '"system\u0000"', '"system "') { '{"type":' + $v + $x }) -Fresh -Fields 'Retries', 'Result'

    # --- rate_limit_event ----------------------------------------------------------
    $ra = '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790000000,"rateLimitType":"five_hour"}}'
    $rr = '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790000000,"rateLimitType":"five_hour","overageStatus":"rejected"}}'
    $rw = '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790000000,"rateLimitType":"seven_day","utilization":0.9}}'
    # Rate is set from any rate_limit_info, falsy ones too; Limit when its
    # status -eq rejected
    New-NvStreamStateCase 'rate, events' 'claude' @($ra, $rr, $rw, '{"rate_limit_info":{"status":"rejected"},"type":"rate_limit_event"}', '{"type": "rate_limit_event", "rate_limit_info": {"status": "rejected"}}',
        '{"type":"rate_limit_event","rate_limit_info":false}', '{"type":"rate_limit_event","rate_limit_info":0}', '{"type":"rate_limit_event","rate_limit_info":""}',
        @($rr, $ra), @($rr, '{"type":"rate_limit_event"}'), @($ra, '{"type":"rate_limit_event","rate_limit_info":null}')) -Fresh -Fields 'Rate', 'Limit'
    New-NvStreamStateCase 'rate, info forms' 'claude' @(foreach ($v in '{"status":"REJECTED"}', '{"status":["allowed","rejected"]}', '{"status":true}', '{"status":false}', '{"status":0}',
            '{"status":""}', '{"status":null}', '{"resetsAt":1790000000}', '{"status":[["rejected"]]}', '"rejected"', '{}', '[]', '[{"status":"rejected"}]',
            '[{"status":"allowed"},{"status":"rejected"}]') { '{"type":"rate_limit_event","rate_limit_info":' + $v + '}' }) -Fresh -Fields 'Limit'

    # --- assistant turns: the count and the last text ----------------------------
    # each after a text saying "before" in the same turn, so a form that
    # gives no text shows
    $b = '{"type":"text","text":"before"},'
    New-NvStreamStateCase 'text, forms after a text' 'claude' @(foreach ($c in '{"type":"text","text":"Done."}', '{"type":"thinking","thinking":"the model''s own","signature":"x"}',
            '{"type":"text","text":"a"},{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"b"}', '{"type":"text","text":"a"},{"type":"text","text":""}',
            '{"type":"text","text":5}', '{"type":"text","text":1.5}', '{"type":"text","text":true}', '{"type":"text","text":false}', '{"type":"text","text":0}', '{"type":"text","text":"0"}',
            '{"type":"text","text":["a","b"]}', '{"type":"text","text":["",""]}', '{"type":"text","text":["a",null]}', '{"type":"text","text":[null,"a"]}',
            '{"type":"text","text":["x",""]}', '{"type":"text","text":[""]}', '{"type":"text","text":[[null,null]]}', '{"type":"text","text":[[null]]}', '{"type":"text","text":[[]]}',
            '{"type":"text","text":{"k":1}}', '{"type":"text","text":{}}', '{"type":"TEXT","text":"a"},{"Type":"Text","Text":"b"}', '{"type":true,"text":"yes"}',
            '{"type":["text"],"text":"listed"}', '"x",5,null,true,{"type":"text","text":"ok"}') { Get-NvStreamStateTurn ($b + $c) }) -Fresh -Fields 'LastText'
    # (a lone text of - and twenty zeros: pwsh 7's BigInteger 0 is as false as
    # 5.1's Int32 0)
    New-NvStreamStateCase 'text, content forms' 'claude' @('{"type":"assistant","message":{"content":{"type":"text","text":"solo"}}}', '{"type":"assistant","message":{"content":"plain"}}',
        '{"type":"assistant","message":{"content":[]}}', '{"type":"assistant","message":{"content":null}}', '{"type":"assistant"}',
        '{"type":"assistant","Message":{"Model":"m","Content":[{"Type":"text","TEXT":"hi"}]}}', (Get-NvStreamStateTurn '{"type":"text","text":-00000000000000000000}')) -Fresh -Fields 'Assistant', 'LastText'

    # --- tool_use: Tools gets every name, ToolIds every id -----------------------
    New-NvStreamStateCase 'tools, forms' 'claude' (@(foreach ($c in '{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{}}',
                '{"type":"tool_use","id":"t1","name":5}', '{"type":"tool_use","id":"t1","name":true}', '{"type":"tool_use","id":"t1"}', '{"type":"tool_use","id":"t1","name":["A","B"]}',
                '{"type":"tool_use","id":"t1","name":{"k":1,"m":"v"}}', '{"type":"tool_use","id":5,"name":"N"}', '{"type":"tool_use","id":0,"name":"N"}', '{"type":"tool_use","id":"","name":"N"}',
                '{"type":"tool_use","name":"N"}', '{"type":"tool_use","id":["x","y"],"name":"N"}', '{"type":"tool_use","id":true,"name":"N"}', '{"type":"TOOL_USE","id":"t1","name":"Bash"}',
                '{"type":"tool_use","id":-00000000000000000000,"name":"N"}', '{"type":"tool_use","id":-00000000000000000001,"name":"N"}',
                '{"type":"tool_use","id":"t1","name":"A"},{"type":"tool_use","id":"t1","name":"B"}') { Get-NvStreamStateTurn $c }) +
        , @((Get-NvStreamStateTurn '{"type":"tool_use","id":"t1","name":"Bash"}'), (Get-NvStreamStateTurn '{"type":"tool_use","id":"t1","name":"Read"}'))) -Fresh -Fields 'Tools', 'ToolIds'
    # ToolIds is a PS hashtable: ids alike but for case are one key, the
    # first id's spelling kept
    New-NvStreamStateCase 'tools, ids alike but for case' 'claude' @(foreach ($p in @(@('toolu_AB', 'TOOLU_ab'), @((Join-NvStreamStateText 0xE9), (Join-NvStreamStateText 0xC9)),
                @((Join-NvStreamStateText 0x3C3), (Join-NvStreamStateText 0x3C2)), @('s', (Join-NvStreamStateText 0x17F)), @('i', (Join-NvStreamStateText 0x131)),
                @('I', (Join-NvStreamStateText 0x130)))) {
            Get-NvStreamStateTurn ('{"type":"tool_use","id":"' + $p[0] + '","name":"N1"},{"type":"tool_use","id":"' + $p[1] + '","name":"N2"}')
        }) -Fresh -Fields 'ToolIds'
    # letters whose simple upper case is a letter with a iota beside, or is
    # not their round trip: one key in both, pwsh 7's @{} folding as
    # OrdinalIgnoreCase and 5.1's by the culture (5.1 keeps the micro sign
    # apart from Mu, which pwsh 7 does not: no vector can hold that pair)
    New-NvStreamStateCase 'tools, ids alike but for case, Greek and title case' 'claude' @(foreach ($p in @(@(0x1F80, 0x1F88), @(0x1FB3, 0x1FBC), @(0x1C5, 0x1C4))) {
            Get-NvStreamStateTurn ('{"type":"tool_use","id":"' + (Join-NvStreamStateText $p[0]) + '","name":"N1"},{"type":"tool_use","id":"' + (Join-NvStreamStateText $p[1]) + '","name":"N2"}')
        }) -Fresh -Fields 'ToolIds'
    # 5.1's @{} compares by the culture, where a soft hyphen or NUL in an id
    # is no character; pwsh 7's compares ordinally
    New-NvStreamStateCase 'tools, ids alike but for a soft hyphen or NUL' 'claude' @(foreach ($p in @(@((Join-NvStreamStateText 'a' 0xAD 'b'), 'ab'), @('a\u0000b', 'ab'))) {
            Get-NvStreamStateTurn ('{"type":"tool_use","id":"' + $p[0] + '","name":"N1"},{"type":"tool_use","id":"' + $p[1] + '","name":"N2"}')
        }) -Fresh -Fields 'ToolIds'

    # --- <synthetic> turns ---------------------------------------------------------
    $syn = '"<synthetic>"'
    # (the real limit and overload texts are in the fixtures)
    New-NvStreamStateCase 'synthetic, turns' 'claude' (@((Get-NvStreamStateSynthetic 'Prompt is too long'), (Get-NvStreamStateSynthetic 'API Error: 529 overloaded, and you hit your limit')) +
        @(foreach ($c in '{"type":"text","text":"hit your"},{"type":"text","text":"limit"}', '{"type":"text","text":"API Error:"},{"type":"text","text":503}',
                '{"type":"text","text":{"k":"overloaded"}}', '{"type":"text","text":["API","Error: 529"]}', '{"type":"text","text":[null,"API Error: 500"]}',
                '{"type":"text","text":true},{"type":"text","text":"overloaded"}', '{"type":"text","text":{"k":1}},{"type":"text","text":[["a","b"],"API Error: 500"]}',
                '{"type":"text","text":3.0000000000000004e-1},{"type":"text","text":"overloaded"}', '',
                '{"type":"text","text":"API Error: 500"},{"type":"tool_use","id":"t1","name":"Bash"}') { Get-NvStreamStateTurn $c $syn }) +
        @(foreach ($m in '"<SYNTHETIC>"', '["<synthetic>"]', '["<synthetic>","x"]', 'true', 'false', 'null', '" <synthetic>"') { Get-NvStreamStateTurn '{"type":"text","text":"API Error: 503"}' $m }) +
        , @((Get-NvStreamStateTurn '{"type":"text","text":"Working."}'), (Get-NvStreamStateSynthetic 'API Error: 500 Internal server error'))) -Fresh -Fields 'Assistant', 'Tools', 'SyntheticLimit', 'Overloaded'
    # -join renders a decimal part with its scale on 5.1, a double on pwsh 7
    New-NvStreamStateCase 'synthetic, a decimal part' 'claude' @(Get-NvStreamStateTurn '{"type":"text","text":1.50},{"type":"text","text":"overloaded"}' $syn) -Fields 'SyntheticLimit', 'Overloaded'
    # the synthetic branch returns from the function: a type list's later
    # items wait
    $sx = ',"message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500"}]},"x":{"type":"result"}}'
    New-NvStreamStateCase 'synthetic, in a type list' 'claude' @(('{"type":["assistant","result"]' + $sx), ('{"type":["result","assistant"]' + $sx),
        '{"type":["assistant","assistant"],"message":{"content":[{"type":"text","text":"twice"}]},"x":{"type":"result"}}') -Fresh -Fields 'Assistant', 'LastText', 'Overloaded', 'Result'

    # --- the two regexes on a <synthetic> turn's text (SPEC 2.9) -----------------
    New-NvStreamStateCase 'rx, limit' 'claude' @(foreach ($t in 'You''ve hit your session limit', 'HIT YOUR LIMIT', 'You''ve hit your Opus limit', 'Claude AI usage limit reached|1790000000',
            'Usage Limit Reached', 'Your limit will reset at 5pm', 'limit resets 5pm', 'You have reached the limit', (Join-NvStreamStateText 'hit your ' 0x17F 'ession limit'),
            (Join-NvStreamStateText 'hit your limit ' 0x17F), (Join-NvStreamStateText 'hit your wee' 0x212A 'ly limit'), (Join-NvStreamStateText 'H' 0x130 'T YOUR L' 0x130 'M' 0x130 'T'),
            (Join-NvStreamStateText 'h' 0x130 't your limit'), (Join-NvStreamStateText 'h' 0x131 't your l' 0x131 'm' 0x131 't'), (Join-NvStreamStateText 'h' 0x131 't your limit'),
            (Join-NvStreamStateText 'usage' 0xA0 'limit reached'), (Join-NvStreamStateText 0xFF48 0xFF49 0xFF54 ' your limit'), (Join-NvStreamStateText 'hit your li' 0xAD 'mit'),
            (Join-NvStreamStateText 'hit your se' 0xDF 'ion limit'), (Join-NvStreamStateText 'hit your se' 0x1E9E 'ion limit'), (Join-NvStreamStateText 'hit your' 10 'limit')) {
            Get-NvStreamStateSynthetic $t
        }) -Fresh -Fields 'SyntheticLimit'
    # \s is .NET's white space, \d a BMP decimal digit, (?i) en-US casing
    New-NvStreamStateCase 'rx, API Error' 'claude' @(foreach ($t in 'API Error: 529 Overloaded.', 'api error:529', 'API ERROR: 503', (Join-NvStreamStateText 'API Error:' 9 10 ' 503'),
            (Join-NvStreamStateText 'API Error:' 0xB 0xC '529'), (Join-NvStreamStateText 'API Error:' 0x1C '529'), 'API Error: 429', 'API Error: 52', 'API Error : 503',
            (Join-NvStreamStateText 'API Error' 0xFF1A '503'), (Join-NvStreamStateText 'AP' 0x130 ' Error: 503'), (Join-NvStreamStateText 'ap' 0x131 ' error: 503')) {
            Get-NvStreamStateSynthetic $t
        }) -Fresh -Fields 'SyntheticLimit', 'Overloaded'
    New-NvStreamStateCase 'rx, API Error, space' 'claude' @(foreach ($c in 0xA0, 0x85, 0x1680, 0x180E, 0x200A, 0x200B, 0x2028, 0x2029, 0x3000, 0xFEFF) {
            Get-NvStreamStateSynthetic (Join-NvStreamStateText 'API Error:' $c '529')
        }) -Fresh -Fields 'Overloaded'
    New-NvStreamStateCase 'rx, API Error, digits' 'claude' @(foreach ($p in @(@('5', 0x662, 0x669), @(0x665, 0x662, 0x669), @('5', 0xFF12, 0xFF19), @('5', 0x968, 0x96F), @('5', 0xBE6, 0xBEF),
                @('5', 0xA9F0, 0xA9F9), @('5', 0x1D7D0, 0x1D7D7), @('5', 0xB2, 0xB3), @('5', 0x2461, 0x2462), @('5', 0x216B, 0x216B))) {
            Get-NvStreamStateSynthetic (Join-NvStreamStateText 'API Error: ' $p[0] $p[1] $p[2])
        }) -Fresh -Fields 'Overloaded'
    # \b around overloaded: .NET's word characters are letters, Mn marks,
    # decimal digits, connector punctuation and the two zero width joiners,
    # one UTF-16 unit at a time
    New-NvStreamStateCase 'rx, overloaded' 'claude' @(foreach ($t in 'Overloaded', 'OVERLOADED_ERROR', 'The API is overloaded right now.', 'overloaded_errors', 'overloaded_errorX',
            'overloadedX', 'Xoverloaded', '1overloaded', '_overloaded', '-overloaded-') {
            Get-NvStreamStateSynthetic $t
        }) -Fresh -Fields 'Overloaded'
    New-NvStreamStateCase 'rx, overloaded, a character before' 'claude' @(foreach ($c in 0xE9, 0xAA, 0x2B0, 0x1C5, 0x301, 0x345, 0x903, 0x20DD, 0x660, 0x216B, 0xB2,
            0x2040, 0x200D, 0x200C, 0xAD, 0x24B6, 0x1D400, 0x1F600, 0xB7) {
            Get-NvStreamStateSynthetic (Join-NvStreamStateText $c 'overloaded')
        }) -Fresh -Fields 'Overloaded'
    New-NvStreamStateCase 'rx, overloaded, a character after' 'claude' @(foreach ($c in 0xE9, 0x903, 0x301, 0x200D, 0x216B, 0x1D400, 0x660) {
            Get-NvStreamStateSynthetic (Join-NvStreamStateText 'overloaded' $c)
        }) -Fresh -Fields 'Overloaded'

    # --- result ----------------------------------------------------------------------
    New-NvStreamStateCase 'result, lines' 'claude' @(('{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"ok","session_id":"' + $sid + '"}'),
        '{"is_error":false,"num_turns":1,"subtype":"success","result":"ok","permission_denials":[],"type":"result"}', ' {"type":"result","subtype":"success"}',
        '{"type": "result", "subtype": "success"}', '{"Type":"result","subtype":"success","x":{"type":"result"}}', '{"type":["result","result"],"subtype":"success"}',
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"x":{"type":"result"}}',
        '{"type":"user","message":"it says \"type\":\"result\""}', '[{"type":"result","subtype":"x"}]',
        @('{"type":"result","subtype":"error_during_execution","is_error":true}', '{"type":"result","subtype":"success","is_error":false}'),
        @('{"type":"result","subtype":"success"}', '{"type":"result"')) -Fresh -Fields 'Result'
    New-NvStreamStateCase 'result, holding an assistant' 'claude' @('{"type":"result","subtype":"success","x":{"type":"assistant"}}') -Fields 'Assistant', 'Result'

    # --- the pre-filter: which lines are parsed at all ---------------------------
    # StartsWith is culture-aware: a soft hyphen in the prefix is no character
    New-NvStreamStateCase 'filter, lines' 'claude' @('{"message":{"model":"m","content":[{"type":"text","text":"x"}]},"type":"assistant"}', '{"subtype":"api_retry","type":"system"}',
        '{"type":"SYSTEM","subtype":"api_retry"}', '{"type":"SYSTEM","subtype":"api_retry","x":{"type":"result"}}', '{"Type":"system","subtype":"api_retry"}',
        ' {"type":"system","subtype":"api_retry"}', (Join-NvStreamStateText 9 '{"type":"system","subtype":"api_retry"}'), '{"type": "system", "subtype": "api_retry"}',
        '{"type": "assistant", "message": {"model": "m", "content": [{"type": "text", "text": "x"}]}}', @('', ' ', (Join-NvStreamStateText 9), (Join-NvStreamStateText 13)),
        @((Join-NvStreamStateText '{"type":"system","subtype":"api_retry"}' 13), '{"type":"system","subtype":"api_retry"}   ', (Join-NvStreamStateText '{"type":"system","subtype":"api_retry"}' 9)),
        @('{"type":"user","message":{"role":"user","content":"go"},"session_id":"s"}', '{"type":"tool_progress","tool_use_id":"t1","tool_name":"Bash","elapsed_time_seconds":90}'),
        @('{"type":"thread.started","thread_id":"t"}', '{"type":"turn.started"}', '{"type":"item.completed","item":{"type":"agent_message","text":"x"}}'),
        '{"type":"user","x":{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}}', (Join-NvStreamStateText '{"type":"sys' 0xAD 'tem","subtype":"api_retry"}'),
        (Join-NvStreamStateText 0xAD '{"type":"system","subtype":"api_retry"}'), (Join-NvStreamStateText '{"type":"assis' 0xAD 'tant","message":{"content":[{"type":"text","text":"x"}]}}')) -Fresh -Fields 'Retries', 'Assistant', 'Rate', 'Result'
    # a NUL in the prefix: no character to pwsh 7's StartsWith, one to 5.1's
    New-NvStreamStateCase 'filter, a NUL in the prefix' 'claude' @((Join-NvStreamStateText 0 '{"type":"system","subtype":"api_retry"}'), (Join-NvStreamStateText '{"type":"sys' 0 'tem","subtype":"api_retry"}'),
        (Join-NvStreamStateText '{"type":"system' 0 '","subtype":"api_retry"}')) -Fresh -Fields 'Retries'

    # --- the JSON parse --------------------------------------------------------------
    $j0 = '{"type":"system","subtype":"api_retry"'
    # pwsh 7 reads a comment, but not one the line's end cuts short; neither
    # reads a key named for a member PSObject keeps (psobject, psbase, ...)
    New-NvStreamStateCase 'json, refused by both' 'claude' @($j0, '{"type":"system","subtype":"api_retry', ($j0 + ',"x":"\q"}'), ($j0 + ',"x":TRUE}'), ($j0 + ',"x":tru}'), ($j0 + ',"x":True}'),
        ($j0 + '}//'), ($j0 + '} //'), ($j0 + '}/'), ($j0 + '}/*'), ($j0 + ',"psobject":1}'), ($j0 + ',"PSBase":1}'), ($j0 + ',"psadapted":1}'), ($j0 + ',"psextended":1}'),
        ($j0 + ',"x":{"PSTypeNames":1}}'), ($j0 + ',"x":[{"psbase":1}]}'),
        ($j0 + ',"x":Null}'), ($j0 + ',"x":truex}'), ($j0 + ',"x":5x}'), ($j0 + ',"x":abc}'), ($j0 + ',"x":}'), ($j0 + ',"x" 1}'), ($j0 + ' "x":1}'), ($j0 + '} x'), ($j0 + '}' + $j0 + '}'),
        ($j0 + ',,"x":1}'), ($j0 + ',"x":[1}}'), ($j0 + ',"x":[5:1]}'), ($j0 + ',"x":"\u00e"}'), ($j0 + ',"x":1,"X":2}'), ($j0 + ',"x":{"a":1,"A":2}}'), ($j0 + ',"x":[{"a":1,"A":2}]}'),
        ($j0 + ',"x":[1]/}'), ($j0 + ',"x":true/}'), ($j0 + ',"":1}'), ($j0 + ',"x":{"":1}}'), ($j0 + ',"x":{"":}}'), (Join-NvStreamStateText 0xFEFF $j0 ',"x":{"type":"result"}}'),
        (Join-NvStreamStateText $j0 ',' 0xFEFF '"x":1}'),
        (Join-NvStreamStateText $j0 ',"' 0xE9 '":1,"' 0xC9 '":2}'), (Join-NvStreamStateText $j0 ',"' 0x430 '":1,"' 0x410 '":2}'), (Join-NvStreamStateText $j0 ',"' 0xFF41 '":1,"' 0xFF21 '":2}')) -Fresh -Fields 'Retries'
    New-NvStreamStateCase 'json, read by both' 'claude' @((Join-NvStreamStateText $j0 ',"s":1,"' 0x17F '":2}'), (Join-NvStreamStateText $j0 ',"i":1,"' 0x131 '":2}'), (Join-NvStreamStateText $j0 ',"i":1,"' 0x130 '":2}'),
        (Join-NvStreamStateText $j0 ',"ab":1,"a' 0xAD 'b":2}'), ($j0 + ',"x":"\ud800","y":"\udc00","z":"\udc00\ud800","w":"a\ud83d"}'), ($j0 + ',"x":"\ud83d' + '\ude00"}'), ($j0 + ',"x":"\u0000\u001f"}'),
        '{"type":"system","subtype":''api_retry''}', '{"type":"system",subtype:"api_retry"}', ($j0 + ',1a:1}'), ($j0 + ',"x":"\''\/"}'), (Join-NvStreamStateText $j0 ',"x":"a' 9 'b' 13 'c' 0 'd"}'),
        (Join-NvStreamStateText $j0 ',"x":"' 0xE9 '"}'),(Join-NvStreamStateText $j0 ',' 0xA0 '"x":1}'), (Join-NvStreamStateText $j0 ',' 0x3000 '"x":1}'), (Join-NvStreamStateText $j0 ',' 0x2028 '"x":1}'),
        (Join-NvStreamStateText $j0 ',' 0x85 '"x":1' 0x2029 '}'), ($j0 + ',"x":{}}'), ($j0 + ',"x":NaN}'), ($j0 + ',"x":-Infinity}'), ($j0 + ',"x":{"a":1,"a":2}}'), ($j0 + ',"x":"a"}' + "`t "),
        ($j0 + ',"psobjectx":1}'), (Join-NvStreamStateText $j0 ',"p' 0x17F 'object":1}'), (Join-NvStreamStateText $j0 ',"ps' 0xAD 'base":1}')) -Fresh -Fields 'Retries'
    New-NvStreamStateCase 'json, read by one' 'claude' @(($j0 + ',}'), ($j0 + ',"x":[1,2,]}'), ($j0 + ',"x":[1,,2]}'), ($j0 + ',"x":[,1]}'), ($j0 + '/*c*/}'), ($j0 + '}//c'),
        '/*c*/{"type":"system","subtype":"api_retry","x":{"type":"result"}}', ($j0 + ',"x":/*c*/1}'), ($j0 + ',/*c*/"x":1}'), ($j0 + ',"x":[1/*c*/]}'), ($j0 + ',a-b:1}'), ($j0 + ',a$b:1}'),
        ($j0 + ',a.b:1}'), ($j0 + ',"x":undefined}'), ($j0 + ',"x":"\u 041"}'), (Join-NvStreamStateText $j0 ',' 0 '"x":1}'), (Join-NvStreamStateText $j0 '}' 0), ($j0 + ',"x":0x10}'),
        ($j0 + ',"x":+5}'), ($j0 + ',"x":08}'), ($j0 + ',"x":1E400}'), ($j0 + ',"x":5-}')) -Fresh -Fields 'Retries'
    # keys micro sign and capital mu: one name to pwsh 7's OrdinalIgnoreCase,
    # two to 5.1's, whose table folds only letters that map back
    New-NvStreamStateCase 'json, micro sign and capital mu' 'claude' @(Join-NvStreamStateText '{"type":"system","subtype":"init","session_id":"s","' 0xB5 '":1,"' 0x39C '":2}') -Fields 'Init', 'Session'
    # what each one reads, through tool_name: 5.1 drops a __type key whose
    # value is a string, number or bool, and refuses one holding a list or
    # an object
    New-NvStreamStateCase 'json, values by edition' 'claude' @(foreach ($v in '[1,,2]', '[1,2,]', '[,1]', '[1,/*c*/2]', '[/*c*/]', '[1/*c*/]', '[undefined,1]', '/*c*/"A"', '"\u 041"',
            '{"a":1,"b":2,"a":3}', '{"__type":"x","k":1}', '{"k":1,"__type":5,"m":true}', '{"__type":true,"k":1}', '{"k":1,"__type":"","m":2}', '{"__type":"x"}', '{"__type":null,"k":1}',
            '{"__type":{},"k":1}', '{"__type":[],"k":1}', '{"o":{"__type":"x","k":1},"l":[{"__type":"y","m":2}]}') { $d0 + $v + '}' }) -Fresh -Fields 'Denied'
    # a value carried as it is: an object read twice over one key keeps it
    # where 5.1 first met it, where pwsh 7 last did. (No __type key here:
    # 5.1's own reader of this file would drop it.)
    New-NvStreamStateCase 'json, values kept by edition' 'claude' @(foreach ($v in '{"a":1,"b":2,"a":3}', '{"__TYPE":"x","k":1}', '{"$type":"x","$id":"1","k":1}') {
            '{"type":"system","subtype":"init","session_id":' + $v + '}'
        }) -Fresh -Fields 'Session'
    New-NvStreamStateCase 'json, the same key twice' 'claude' @('{"type":"system","subtype":"init","session_id":"a","session_id":"b"}', '{"type":"system","subtype":"api_retry","type":"result"}') -Fresh -Fields 'Init', 'Session', 'Retries', 'Result'
    New-NvStreamStateCase 'json, an escaped backslash before u' 'claude' @(Get-NvStreamStateTurn ('{"type":"text","text":"\\ud800 \\\ud83d' + '\ude00"}')) -Fields 'LastText'
    # nesting: 5.1 reads a value at most 102 deep (the line's own object is
    # 1), pwsh 7 at most 1024 objects and lists deep
    $deep = @()
    foreach ($n in 100, 101) { $deep += , (New-NvStreamStateRecipe @(@(($j0 + ',"x":'), 1), @('{"a":', $n), @('1', 1), @('}', ($n + 1)))) }
    foreach ($n in 101, 102, 1023, 1024) { $deep += , (New-NvStreamStateRecipe @(@(($j0 + ',"x":'), 1), @('[', $n), @(']', $n), @('}', 1))) }
    New-NvStreamStateCase 'json, depth' 'claude' $deep -Fresh -Fields 'Retries'

    # --- member enumeration: a property of a list is its items' ------------------
    New-NvStreamStateCase 'members, Claude' 'claude' @('[{"type":"system","subtype":"permission_denied","tool_name":null},{"tool_name":"B"},{"z":1,"x":{"type":"result"}}]',
        '[{"type":"system","subtype":"permission_denied","tool_name":"A"},{"z":1},{"tool_name":"B","x":{"type":"result"}}]',
        '[{"type":"system","subtype":"permission_denied","tool_name":"A"},"str",5,null,true,{"tool_name":"B","x":{"type":"result"}}]',
        '[{"type":"system","subtype":"api_retry"},{"subtype":"api_retry"},{"type":"result"}]') -Fresh -Fields 'Retries', 'Denied', 'Result'
    New-NvStreamStateCase 'members, turns' 'claude' @(foreach ($m in '[{"model":"m","content":[{"type":"text","text":"a"}]},{"content":[{"type":"text","text":"b"}]}]',
            '[{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500"}]},{"model":null}]', '[[{"model":"m","content":[{"type":"text","text":"deep"}]}]]',
            '[{"content":[{"type":"text","text":"a"}]},{"content":{"type":"text","text":"b"}}]', '[{"content":[[{"type":"text","text":"a"}]]},{"content":[]}]',
            '["x",5,{"content":[{"type":"text","text":"c"}]}]', '{"model":["<synthetic>","x"],"content":[{"type":"text","text":"API Error: 500"}]}') {
            '{"type":"assistant","message":' + $m + '}'
        }) -Fresh -Fields 'Assistant', 'LastText', 'Overloaded'
    New-NvStreamStateCase 'members, Codex errors' 'codex' @(foreach ($e in '[{"message":"a"},{"message":"b"}]', '["s",5,null,true,{"message":"b"}]', '[null,{"message":"b"}]', '[[],{"message":"b"}]',
            '[[{"message":"a"},{"message":"c"}],{"message":"b"}]', '[[{"x":1}],{"message":"b"}]', '[[{"x":1},{"x":2}],{"message":"b"}]', '[{"message":null},{"message":"b"}]',
            '[{"message":[]},{"message":"b"}]', '[{"message":[["x","y"]]},{"message":"b"}]', '[{"message":["x"]}]', '[{"message":[["x","y"]]}]', '[{"message":{"k":1}},{"message":"b"}]',
            '["s",5]', '[]', '[[[{"message":"a"}]],{"message":"b"}]') { '{"type":"turn.failed","error":' + $e + '}' }) -Fresh -Fields 'TurnFailed'
    New-NvStreamStateCase 'members, Codex lines' 'codex' @('[{"type":"turn.started"}]', '[{"type":"turn.started"},{"type":"turn.completed"}]', '[]', '[[{"type":"turn.started"}]]',
        (New-NvStreamStateRecipe @(@('[', 100), @('{"type":"turn.started"}', 1), @(']', 100)))) -Fresh -Fields 'TurnStarted', 'TurnDone'
    New-NvStreamStateCase 'members, a line 101 lists deep' 'codex' @(New-NvStreamStateRecipe @(@('[', 101), @('{"type":"turn.started"}', 1), @(']', 101))) -Fields 'TurnStarted'
    # 5.1 keeps a line's own list and enumerates its items' thread_id; pwsh 7
    # takes a one-item list's item itself
    New-NvStreamStateCase 'members, a one-item line by edition' 'codex' @(foreach ($t in '[1]', '[]', '[[1,2]]', '"T"') { '[{"type":"thread.started","thread_id":' + $t + '}]' }) -Fresh -Fields 'Init', 'Thread'

    # --- the 1 MB cap: a longer line is dropped unread ---------------------------
    $h = '{"type":"system","subtype":"api_retry","p":"'
    foreach ($c in @(@('ASCII', 'z'), @('astral', (Join-NvStreamStateText 0x1F600)), @('CJK', (Join-NvStreamStateText 0x4E00)))) {
        New-NvStreamStateCase "cap, $($c[0])" 'claude' @((New-NvStreamStateLong $h $c[1] '"}' 1048577), (New-NvStreamStateLong $h $c[1] '"}' 1048576)) -Each -Fields 'Retries'
    }
    New-NvStreamStateCase 'cap, Codex' 'codex' @((New-NvStreamStateLong '{"type":"turn.started","p":"' 'z' '"}' 1048577), (New-NvStreamStateLong '{"type":"turn.started","p":"' 'z' '"}' 1048576)) -Each -Fields 'TurnStarted'

    # --- Codex -------------------------------------------------------------------------
    New-NvStreamStateCase 'codex, a turn' 'codex' @(('{"type":"thread.started","thread_id":"' + $sid + '"}'), '{"type":"turn.started"}', '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}') -Each -Fields 'Init', 'Thread', 'TurnStarted', 'TurnDone'
    New-NvStreamStateCase 'codex, events' 'codex' @('{"type":"thread.started","thread_id":5}', '{"type":"thread.started"}', '{"type":"thread.started","thread_id":{"a":[1,"b"]}}',
        @('{"type":"TURN.STARTED"}', '{"type":"Thread.Started","thread_id":"T"}'), '{"type":["turn.started","turn.completed"]}', '{"type":true,"thread_id":"T"}',
        ('{"type":"turn.' + $shy + 'started"}'), '{"type":"turn.completed\u0000"}', '{"type":"turn.started "}',
        @('{"type":"item.started","item":{"id":"i","type":"command_execution","status":"in_progress"}}', '{"type":"item.updated","item":{"id":"i","type":"todo_list"}}'),
        @(($i0 + '}'), '{"type":"result","subtype":"success","result":"ok"}', '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"x"}]}}'),
        @('"text"', '5', 'null', 'true', '{}', '', '   '), @('{"type":"turn.started"', '{"type":"turn.started","x":1,"X":2}', '{"type":"turn.started"} x')) -Fresh -Fields 'Init', 'Thread', 'TurnStarted', 'TurnDone'
    New-NvStreamStateCase 'codex, failures' 'codex' @(@('{"type":"turn.failed","error":{"message":"boom"}}', '{"type":"error","message":"later"}'),
        @('{"type":"error","message":"first"}', '{"type":"turn.failed","error":{"message":"boom"}}'), @('{"type":"error","message":""}', '{"type":"error","message":"second"}', '{"type":"error","message":"third"}'),
        '{"type":"error"}', @('{"type":"turn.failed"}', '{"type":"error","message":"later"}'), '{"type":"turn.failed","error":"plain"}', '{"type":"error","message":5}',
        '{"type":"error","message":["a",null,"b"]}', '{"type":"turn.failed","error":{"message":{"k":1}}}', '{"type":"turn.failed","error":{"message":1.5}}') -Fresh -Fields 'TurnFailed', 'Failed'
    New-NvStreamStateCase 'codex, items' 'codex' (@(foreach ($t in '"The build fails."', '""', '0', '"0"', '5', '1.5', '["a","b"]', '{"k":1}', 'true', 'false', 'null', '[""]', '["",""]', '[[null]]') {
                '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":' + $t + '}}'
            }) + @('{"type":"item.completed","item":{"id":"item_0","type":"agent_message"}}', '{"type":"item.completed","item":{"type":"AGENT_MESSAGE","text":"x"}}',
            '{"type":"item.completed","item":{"type":["agent_message"],"text":"listed"}}', '{"type":"item.completed","item":{"id":"i","text":"x"}}', '{"type":"item.completed"}',
            '{"type":"item.completed","item":{"type":5}}', '{"type":"item.completed","item":{"type":true}}', '{"type":"item.completed","item":{"type":["a","b"]}}',
            @(foreach ($t in 'command_execution', 'file_change', 'reasoning', 'mcp_tool_call', 'web_search', 'todo_list') { '{"type":"item.completed","item":{"id":"i","type":"' + $t + '"}}' }))) -Fresh -Fields 'Assistant', 'LastText', 'Tools'
    # the rollout's rate_limits lines (tests/sections/usage.ps1): read by the
    # usage steps from the session file, never by the stream state
    $cxGood = '{"timestamp":"2026-09-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1790000000},"secondary":null,"plan_type":"free","rate_limit_reached_type":"rate_limit_reached"}}}'
    $cxSpaced = '{"timestamp": "2026-09-20T10:00:00.000Z", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 42.0, "window_minutes": 300, "resets_at": 1790000000}, "secondary": null, "plan_type": "plus", "rate_limit_reached_type": null}}}'
    $cxEmpty = '{"timestamp":"2026-09-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"plan_type":"free"}}}'
    $cxTorn = '{"timestamp":"2026-09-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_perc'
    New-NvStreamStateCase 'codex, rate_limits lines' 'codex' @('{"type":"thread.started","thread_id":"t"}', $cxGood, $cxSpaced, $cxEmpty, $cxTorn, '{"type":"turn.completed"}') -Each -Fields 'Init', 'TurnDone', 'Assistant', 'Tools'
    New-NvStreamStateCase 'codex, rate_limits through Claude' 'claude' @($cxGood, $cxSpaced) -Fields 'Rate', 'Limit', 'Result'
} -Expect {
    param($In, $Name)
    Use-NvCulture 'en-US' {
        $fields = if ($null -ne $In.fields) { [string[]]@($In.fields) } else { $null }
        $provider = [string]$In.provider
        if ($In.fresh) {
            $out = New-Object System.Collections.Generic.List[object]
            foreach ($s in @($In.lines)) { $out.Add((Invoke-NvStreamStateRun $provider (Get-NvStreamStateStream $s) $fields $false)) }
            , $out.ToArray()
        }
        else { Invoke-NvStreamStateRun $provider (Get-NvStreamStateStream $In.lines) $fields ([bool]$In.each) }
    }
}
