# tests/vectors/jsonl.ps1: native/vectors/jsonl.json (native/SPEC.md 2.3, 2.6,
# 6.1) - a run's stdout as Invoke-ChatqProcess reads it. Each case is the bytes
# a CLI writes: a child PowerShell writes exactly them to its stdout, and the
# real Invoke-ChatqProcess runs it, the clock held still. The Rust runner feeds
# the same bytes to chatq-core's jsonl::LineReader.
#
# An input is hex, or for a line too long for the file a recipe: pre (hex),
# line {head, fill, count, tail} - head + fill x count + tail, as UTF-8 - and
# post (hex).
#
# The answer: lines, each as Invoke-ChatqProcess handed it to -OnLine (one
# longer than 256 code units as {units, sha256} of its UTF-8); log, the .jsonl
# bytes (past 512 as {length, sha256}) as on Windows, CRLF after each line,
# whatever Environment.NewLine is here; and parsed, whether
# Update-ChatqClaudeState read each line - an init line sets Init - which a
# line past 1048576 code units never is.

function Get-NvJsonlHex([string]$Text) {
    return (ConvertTo-NvHex ($script:NvUtf8.GetBytes($Text)))
}

function New-NvJsonlCase([string]$Name, [string]$Hex) {
    return [ordered]@{ name = $Name; input = [ordered]@{ hex = $Hex } }
}

function New-NvJsonlLong([string]$Name, [string]$Pre, [string]$Fill, [int]$Units, [string]$Post) {
    # an init line of exactly $Units code units, its pad $Fill over and over
    $head = '{"type":"system","subtype":"init","session_id":"s1","pad":"'
    $room = $Units - $head.Length - 2
    $count = [int][Math]::Floor($room / $Fill.Length)
    $tail = ('x' * ($room - $count * $Fill.Length)) + '"}'
    return [ordered]@{ name = $Name; input = [ordered]@{ pre = $Pre; line = [ordered]@{ head = $head; fill = $Fill; count = $count; tail = $tail }; post = $Post } }
}

function Get-NvJsonlBytes($In) {
    if (Get-NvHas $In 'hex') {
        $b = ConvertFrom-NvHex ([string]$In.hex)
        return , $b
    }
    $l = $In.line
    $ms = New-Object System.IO.MemoryStream
    $pre = ConvertFrom-NvHex ([string]$In.pre)
    $ms.Write($pre, 0, $pre.Length)
    $mid = $script:NvUtf8.GetBytes([string]$l.head + ([string]$l.fill * [int]$l.count) + [string]$l.tail)
    $ms.Write($mid, 0, $mid.Length)
    $post = ConvertFrom-NvHex ([string]$In.post)
    $ms.Write($post, 0, $post.Length)
    return , $ms.ToArray()
}

function Get-NvJsonlSha([byte[]]$Bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-NvHex $h.ComputeHash($Bytes)) } finally { $h.Dispose() }
}

Register-NvVector -Name 'jsonl' -About 'A run''s stdout as Invoke-ChatqProcess (src/queue.ps1) reads it: a StreamReader over UTF-8 that detects a byte-order mark, ReadLineAsync line by line, each line written to the .jsonl log and then handed to -OnLine; and the 1048576-code-unit rule of Update-ChatqClaudeState. input: the bytes (hex), or a recipe {pre, line {head, fill, count, tail}, post} for a long line. expect: lines (past 256 code units as {units, sha256} of its UTF-8), log (the .jsonl as written on Windows, CRLF after each line; past 512 bytes as {length, sha256}), parsed (Update-ChatqClaudeState found the init line).' -Cases {
    $cr = "`r"
    $lf = "`n"
    # how lines end
    New-NvJsonlCase 'nothing' ''
    New-NvJsonlCase 'a line with no end' (Get-NvJsonlHex 'a')
    New-NvJsonlCase 'a line, LF' (Get-NvJsonlHex "a$lf")
    New-NvJsonlCase 'a line, CRLF' (Get-NvJsonlHex "a$cr$lf")
    New-NvJsonlCase 'a line, CR' (Get-NvJsonlHex "a$cr")
    New-NvJsonlCase 'a lone CR between' (Get-NvJsonlHex "a$($cr)b")
    New-NvJsonlCase 'an empty line between' (Get-NvJsonlHex "a$lf$($lf)b")
    New-NvJsonlCase 'LF alone' (Get-NvJsonlHex $lf)
    New-NvJsonlCase 'LF LF LF' (Get-NvJsonlHex "$lf$lf$lf")
    New-NvJsonlCase 'CRLF CRLF' (Get-NvJsonlHex "$cr$lf$cr$lf")
    New-NvJsonlCase 'CR CRLF' (Get-NvJsonlHex "$cr$cr$lf")
    New-NvJsonlCase 'LF CR' (Get-NvJsonlHex "$lf$cr")
    New-NvJsonlCase 'CRLF then CR' (Get-NvJsonlHex "a$cr$lf$($cr)b$lf")
    # what a CLI writes
    New-NvJsonlCase 'stream-json lines' (Get-NvJsonlHex ('{"type":"system","subtype":"init","session_id":"s1"}' + $lf + '{"type":"assistant","message":{"content":[]}}' + $lf))
    New-NvJsonlCase 'stream-json, CRLF and no last end' (Get-NvJsonlHex ('{"type":"system","subtype":"init"}' + $cr + $lf + '{"type":"result","subtype":"success"}'))
    New-NvJsonlCase 'U+2028 and U+0085 are no line ends' (Get-NvJsonlHex ('a' + [char]0x2028 + 'b' + [char]0x85 + 'c' + $lf))
    New-NvJsonlCase 'NUL in a line' '6100620a'
    New-NvJsonlCase 'hangul and an emoji' (Get-NvJsonlHex ([string][char]0xD55C + [char]0xD83D + [char]0xDE00 + $lf))
    # bytes that do not decode
    New-NvJsonlCase 'ff in a line' '61ff620a'
    New-NvJsonlCase 'e0 80 80 in a line' '61e08080620a'
    New-NvJsonlCase 'ed a0 80 in a line' '61eda080620a'
    New-NvJsonlCase 'e2 82 before LF' 'e2820a61'
    New-NvJsonlCase 'e2 82 cut at the end' '610ae282'
    New-NvJsonlCase 'f0 9f 98 cut at the end, no LF' '61f09f98'
    # byte-order marks
    New-NvJsonlCase 'mark utf-8' ('efbbbf' + (Get-NvJsonlHex "a$lf"))
    New-NvJsonlCase 'mark utf-8 twice' ('efbbbfefbbbf' + (Get-NvJsonlHex "a$lf"))
    New-NvJsonlCase 'mark utf-16le' ('fffe' + (ConvertTo-NvHex ([System.Text.Encoding]::Unicode.GetBytes("a$($lf)b"))))
    New-NvJsonlCase 'mark utf-16be' ('feff' + (ConvertTo-NvHex ([System.Text.Encoding]::BigEndianUnicode.GetBytes("a$cr$($lf)b$cr$lf"))))
    New-NvJsonlCase 'mark utf-32le' ('fffe0000' + (ConvertTo-NvHex ([System.Text.Encoding]::UTF32.GetBytes("a$lf"))))
    New-NvJsonlCase 'mark utf-8 cut short' 'efbb'
    # the reader's 4096-byte buffer cut through
    $x = 'x' * 4095
    New-NvJsonlLong 'CRLF across the buffer' '' 'x' 4095 '0d0a79'
    New-NvJsonlCase 'hangul across the buffer' ((Get-NvJsonlHex $x) + 'ed959c0a')
    New-NvJsonlCase 'e0 80 80 across the buffer' ((Get-NvJsonlHex $x) + 'e080800a')
    # the 1 MB rule
    $e = [string][char]0xE9
    $emoji = [string][char]0xD83D + [char]0xDE00
    New-NvJsonlLong 'init of 1048576 units' '' 'x' 1048576 '0a'
    New-NvJsonlLong 'init of 1048577 units' '' 'x' 1048577 '0a'
    New-NvJsonlLong 'init of 1048576 units of e acute' '' $e 1048576 '0a'
    New-NvJsonlLong 'init of 1048577 units of e acute' '' $e 1048577 '0a'
    New-NvJsonlLong 'init of 1048576 units of emoji' '' $emoji 1048576 '0d0a'
    New-NvJsonlLong 'init of 1048577 units of emoji' '' $emoji 1048577 ''
    New-NvJsonlLong 'a long line between short ones' (Get-NvJsonlHex ('{"type":"system","subtype":"init"}' + $lf)) 'x' 1048577 ('0a' + (Get-NvJsonlHex ('{"type":"system","subtype":"init"}' + $lf)))
} -Expect {
    param($In, $Name)
    $dir = Enter-NvData $Name
    $out = Join-Path $dir 'stdout.bin'
    [IO.File]::WriteAllBytes($out, (Get-NvJsonlBytes $In))
    $logPath = Join-Path (Join-Path $dir 'logs') 'job.jsonl'
    $jsonlSeen = New-Object System.Collections.Generic.List[string]
    $write = '$b = [IO.File]::ReadAllBytes(''' + ($out -replace "'", "''") + '''); $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length); $o.Flush()'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($write))
    $child = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Use-NvTimeZone 'UTC' {
        Use-NvClock '2026-10-15T00:00:00Z' {
            Invoke-ChatqProcess -Exe $child -ArgList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -LogPath $logPath `
                -OnLine { param($l) $jsonlSeen.Add($l) } -OnTick { $watch.Elapsed.TotalSeconds -gt 120 }
        }
    }
    if ($r.Stopped) { throw "the child PowerShell was stopped: $($r.Stopped)" }
    if ($r.ExitCode -ne 0) { throw "the child PowerShell exited $($r.ExitCode): $($r.StdErr)" }
    $log = [IO.File]::ReadAllBytes($logPath)
    if ([Environment]::NewLine -ne "`r`n") {
        # a line holds no CR or LF: every LF is a line's end
        $crlf = New-Object System.Collections.Generic.List[byte]
        foreach ($b in $log) { if ($b -eq 10) { $crlf.Add(13) }; $crlf.Add($b) }
        $log = $crlf.ToArray()
    }
    $lines = @(foreach ($l in $jsonlSeen) {
            if ($l.Length -le 256) { $l } else { [ordered]@{ units = $l.Length; sha256 = (Get-NvJsonlSha ($script:NvUtf8.GetBytes($l))) } }
        })
    $parsed = @(foreach ($l in $jsonlSeen) { $st = New-ChatqRunState; Update-ChatqClaudeState $st $l; [bool]$st.Init })
    $shown = if ($log.Length -le 512) { ConvertTo-NvHex $log } else { [ordered]@{ length = $log.Length; sha256 = (Get-NvJsonlSha $log) } }
    [ordered]@{ lines = $lines; log = $shown; parsed = $parsed }
}
