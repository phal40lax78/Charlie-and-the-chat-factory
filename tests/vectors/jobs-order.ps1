# tests/vectors/jobs-order.ps1: native/vectors/jobs-order.json - the queue
# order, Get-ChatqJobs (src/queue.ps1) over a queue folder of job files, and
# the lane a job's limits go by, Get-ChatqLane (src/watcher.ps1). Rust:
# native/crates/chatq-core/tests/jobs_order_vectors.rs.
#
# An order case is a queue folder: its files {name, text, [bom]}, written as
# UTF-8; folders named like job files (dirs); or none at all (noQueue). The
# answer is what Get-ChildItem lists there and the jobs Get-ChatqJobs gives
# back, in its order, each by its tag (a job that is a string, as itself).
# File names are a letter and two digits, which both PowerShells list in one
# order. Sort-Object is not stable, so jobs whose keys all tie come back as
# each PowerShell's .NET leaves them: those answers differ by edition.
#
# A lane case is a job, read as the tool reads one (ConvertFrom-Json), and
# Get-ChatqLane's answer for it.

function New-NvJobsOrderFile([string]$Name, [string]$Text, [switch]$Bom) {
    $f = [ordered]@{ name = $Name; text = $Text }
    if ($Bom) { $f['bom'] = $true }
    return $f
}

function New-NvJobsOrderJob([string]$Tag, [string]$Body) {
    # <tag>.json, a job whose id and tag are <tag>, with $Body's fields
    $t = '{"id":"' + $Tag + '","tag":"' + $Tag + '"'
    if ($Body) { $t += ',' + $Body }
    return (New-NvJobsOrderFile "$Tag.json" ($t + '}'))
}

function New-NvJobsOrderCase {
    param([string]$Name, $Files, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540, $Dirs, [switch]$NoQueue)
    $in = [ordered]@{ kind = 'order'; zone = $Zone; utcOffsetMinutes = $Offset; files = @($Files) }
    if ($Dirs) { $in['dirs'] = @($Dirs) }
    if ($NoQueue) { $in['noQueue'] = $true }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvJobsOrderLane([string]$Name, $Job) {
    return [ordered]@{ name = $Name; input = [ordered]@{ kind = 'lane'; job = $Job } }
}

function Get-NvJobsOrderAt([int]$Minute) {
    # createdAt 01:<minute> UTC, as a job field
    return ('"createdAt":"2026-10-15T01:{0:d2}:00Z"' -f $Minute)
}

Register-NvVector -Name 'jobs-order' -About 'Get-ChatqJobs (src/queue.ps1): every *.json file in data/queue holding a job, in the queue order - put first (latest first ahead), then continues (kind continue, or rule restart), then the rest; each oldest createdAt first, then by [int]seq. Sort-Object is not stable, so ties land as each edition''s .NET sort leaves them. Get-ChatqLane (src/watcher.ps1): provider, or provider|home. Rust: jobs::get_jobs, jobs::job_files, jobs::lane' -Cases {
    # the four keys at work
    New-NvJobsOrderCase 'keys-basic' @(
        (New-NvJobsOrderJob 'a01' '"createdAt":"2026-10-15T01:00:00Z","seq":1'),
        (New-NvJobsOrderJob 'a02' '"first":"2026-10-15T03:00:00Z"'),
        (New-NvJobsOrderJob 'a03' '"kind":"continue","createdAt":"2026-10-15T02:00:00Z"'),
        (New-NvJobsOrderJob 'a04' '"rule":"restart","createdAt":"2026-10-15T00:30:00Z"'),
        (New-NvJobsOrderJob 'a05' '"first":"2026-10-15T04:00:00Z"'),
        (New-NvJobsOrderJob 'a06' '"createdAt":"2026-10-15T00:00:00Z","seq":2'),
        (New-NvJobsOrderJob 'a07' '"createdAt":"2026-10-15T00:00:00Z","seq":1'),
        (New-NvJobsOrderJob 'a08' '"first":"2026-10-15T03:00:00Z","kind":"continue","createdAt":"2026-10-14T00:00:00Z"'))
    # the same, as a watcher in another zone sorts it
    New-NvJobsOrderCase 'keys-utc' @(
        (New-NvJobsOrderJob 'a01' '"createdAt":"2026-10-15T01:00:00Z","seq":1'),
        (New-NvJobsOrderJob 'a02' '"first":"2026-10-15T03:00:00Z"'),
        (New-NvJobsOrderJob 'a03' '"kind":"continue","createdAt":"2026-10-15T02:00:00-05:00"'),
        (New-NvJobsOrderJob 'a04' '"rule":"restart","createdAt":"2026-10-15T09:30:00+09:00"')) -Zone 'UTC' -Offset 0
    # what counts as put first, and when
    New-NvJobsOrderCase 'first-shapes' @(
        (New-NvJobsOrderJob 'b01' ('"first":"2026-10-15T03:00:00Z",' + (Get-NvJobsOrderAt 1))),
        (New-NvJobsOrderJob 'b02' ('"first":"2026-10-15T12:30:00+09:00",' + (Get-NvJobsOrderAt 2))),
        (New-NvJobsOrderJob 'b03' ('"first":true,' + (Get-NvJobsOrderAt 3))),
        (New-NvJobsOrderJob 'b04' ('"first":"not a date",' + (Get-NvJobsOrderAt 4))),
        (New-NvJobsOrderJob 'b05' ('"first":1,' + (Get-NvJobsOrderAt 5))),
        (New-NvJobsOrderJob 'b06' ('"first":"",' + (Get-NvJobsOrderAt 6))),
        (New-NvJobsOrderJob 'b07' ('"first":false,' + (Get-NvJobsOrderAt 7))),
        (New-NvJobsOrderJob 'b08' ('"first":"2026-10-15T03:00:00.0000001Z",' + (Get-NvJobsOrderAt 8))),
        (New-NvJobsOrderJob 'b09' ('"first":null,' + (Get-NvJobsOrderAt 9))),
        (New-NvJobsOrderJob 'b10' ('"First":"2026-10-15T05:00:00Z",' + (Get-NvJobsOrderAt 10))))
    # what -eq 'continue' takes for a continue
    New-NvJobsOrderCase 'kind-shapes' @(
        (New-NvJobsOrderJob 'c01' ('"kind":"CONTINUE",' + (Get-NvJobsOrderAt 1))),
        (New-NvJobsOrderJob 'c02' ('"kind":true,' + (Get-NvJobsOrderAt 2))),
        (New-NvJobsOrderJob 'c03' ('"kind":["continue","x"],' + (Get-NvJobsOrderAt 3))),
        (New-NvJobsOrderJob 'c04' ('"kind":[0,true],' + (Get-NvJobsOrderAt 4))),
        (New-NvJobsOrderJob 'c05' ('"kind":"continue ",' + (Get-NvJobsOrderAt 5))),
        (New-NvJobsOrderJob 'c06' ('"kind":5,' + (Get-NvJobsOrderAt 6))),
        (New-NvJobsOrderJob 'c07' ('"kind":{"a":1},' + (Get-NvJobsOrderAt 7))),
        (New-NvJobsOrderJob 'c08' ('"kind":false,' + (Get-NvJobsOrderAt 8))),
        (New-NvJobsOrderJob 'c09' ('"kind":null,' + (Get-NvJobsOrderAt 9))),
        (New-NvJobsOrderJob 'c10' ('"kind":["x"],' + (Get-NvJobsOrderAt 10))),
        (New-NvJobsOrderJob 'c11' ('"kind":[["continue"]],' + (Get-NvJobsOrderAt 11))),
        (New-NvJobsOrderJob 'c12' ('"kind":"restart",' + (Get-NvJobsOrderAt 12))),
        (New-NvJobsOrderJob 'c13' ('"Kind":"continue",' + (Get-NvJobsOrderAt 13))))
    # rule as [string] makes it
    New-NvJobsOrderCase 'rule-shapes' @(
        (New-NvJobsOrderJob 'd01' ('"rule":"restart",' + (Get-NvJobsOrderAt 1))),
        (New-NvJobsOrderJob 'd02' ('"rule":"RESTART",' + (Get-NvJobsOrderAt 2))),
        (New-NvJobsOrderJob 'd03' ('"rule":["restart"],' + (Get-NvJobsOrderAt 3))),
        (New-NvJobsOrderJob 'd04' ('"rule":["restart","x"],' + (Get-NvJobsOrderAt 4))),
        (New-NvJobsOrderJob 'd05' ('"rule":true,' + (Get-NvJobsOrderAt 5))),
        (New-NvJobsOrderJob 'd06' ('"rule":" restart",' + (Get-NvJobsOrderAt 6))),
        (New-NvJobsOrderJob 'd07' ('"rule":null,' + (Get-NvJobsOrderAt 7))),
        (New-NvJobsOrderJob 'd08' ('"Rule":"restart",' + (Get-NvJobsOrderAt 8))))
    # a createdAt that is no time sorts as the earliest; seq decides between
    New-NvJobsOrderCase 'created-shapes' @(
        (New-NvJobsOrderJob 'e01' '"createdAt":null,"seq":5'),
        (New-NvJobsOrderJob 'e02' '"createdAt":"","seq":4'),
        (New-NvJobsOrderJob 'e03' '"createdAt":"not a date","seq":3'),
        (New-NvJobsOrderJob 'e04' '"createdAt":5,"seq":2'),
        (New-NvJobsOrderJob 'e05' '"seq":1'),
        (New-NvJobsOrderJob 'e06' '"createdAt":"2026-10-15T01:00:00Z"'),
        (New-NvJobsOrderJob 'e07' '"createdAt":"2026-10-15T09:30:00+09:00"'),
        (New-NvJobsOrderJob 'e08' '"createdAt":"2026-10-15T01:00:00.0000001Z"'),
        (New-NvJobsOrderJob 'e09' '"createdAt":"2026-10-15T01:00:00.5Z"'),
        (New-NvJobsOrderJob 'e10' '"createdAt":"2026-10-15T01:00:00.123-00:30"'))
    # [int]seq: what converts, and the $null of what does not, which sorts
    # between the negative numbers and 0
    $seqs = @('3', '"3"', '" 4 "', '"2.5"', '2.5', '3.5', '"0x10"', '"1,000"', '"+5"', '"-0"', '"07"', '-5',
        'null', $null, 'true', 'false', '"abc"', '3000000000', '"1e3"', '[]', '[1]', '{}', '"-3"', '-1.5')
    $files = for ($i = 0; $i -lt $seqs.Count; $i++) {
        $body = '"createdAt":"2026-10-15T01:00:00Z"'
        if ($null -ne $seqs[$i]) { $body += ',"seq":' + $seqs[$i] }
        New-NvJobsOrderJob ('f{0:d2}' -f ($i + 1)) $body
    }
    New-NvJobsOrderCase 'seq-shapes' $files
    # jobs whose keys all tie: where each sort leaves them
    foreach ($n in 2, 5, 17, 40) {
        New-NvJobsOrderCase "ties-$n" @(for ($i = 1; $i -le $n; $i++) { New-NvJobsOrderJob ('t{0:d2}' -f $i) '' })
    }
    $files = for ($i = 1; $i -le 20; $i++) {
        $body = if ($i % 2) { '"createdAt":"2026-10-15T01:00:00Z"' } else { '"createdAt":"2026-10-15T02:00:00Z"' }
        $body += ',"seq":' + ($i % 3)
        if ($i % 5 -eq 0) { $body += ',"kind":"continue"' }
        New-NvJobsOrderJob ('g{0:d2}' -f $i) $body
    }
    New-NvJobsOrderCase 'mixed-ties' $files
    # the files Get-ChatqJobs reads, and those it leaves
    New-NvJobsOrderCase 'files-skipped' @(
        (New-NvJobsOrderJob 'k01' (Get-NvJobsOrderAt 1)),
        (New-NvJobsOrderFile 'k02.json' '{"id":"k02","tag":"k02"'),
        (New-NvJobsOrderFile 'k03.json' 'not json'),
        (New-NvJobsOrderFile 'k04.json' '{"id":"k04","tag":"k04"} x'),
        (New-NvJobsOrderFile 'k05.json' '{"id":"k05","tag":"k05"}{"id":"k05b","tag":"k05b"}'),
        (New-NvJobsOrderFile 'k06.json' ''),
        (New-NvJobsOrderFile 'k07.json' "  `r`n "),
        (New-NvJobsOrderFile 'k08.json' ('{"id":"k08","tag":"k08",' + (Get-NvJobsOrderAt 8) + '}') -Bom),
        (New-NvJobsOrderFile 'u01.JSON' ('{"id":"u01","tag":"u01",' + (Get-NvJobsOrderAt 9) + '}')),
        (New-NvJobsOrderFile 'n01.txt' '{"id":"n01","tag":"n01"}'),
        (New-NvJobsOrderFile 'n02.json.bak' '{"id":"n02","tag":"n02"}'),
        (New-NvJobsOrderFile 'n03.jsonx' '{"id":"n03","tag":"n03"}'),
        (New-NvJobsOrderFile 'm01.json' '{"tag":"m01"}'),
        (New-NvJobsOrderFile 'm02.json' '{"id":"","tag":"m02"}'),
        (New-NvJobsOrderFile 'm03.json' '{"id":0,"tag":"m03"}'),
        (New-NvJobsOrderFile 'm04.json' '{"id":false,"tag":"m04"}'),
        (New-NvJobsOrderFile 'm05.json' '{"id":[],"tag":"m05"}'),
        (New-NvJobsOrderFile 'm06.json' '{"id":[0],"tag":"m06"}'),
        (New-NvJobsOrderFile 'm07.json' ('{"id":{},"tag":"m07",' + (Get-NvJobsOrderAt 7) + '}')),
        (New-NvJobsOrderFile 'm08.json' ('{"Id":"m08","tag":"m08",' + (Get-NvJobsOrderAt 6) + '}')),
        (New-NvJobsOrderFile 'm09.json' ('{"id":"' + (U '\u00e9') + '","tag":"m09",' + (Get-NvJobsOrderAt 5) + '}')),
        (New-NvJobsOrderFile 'p01.json' '"hello"'),
        (New-NvJobsOrderFile 'p02.json' '5'),
        (New-NvJobsOrderFile 'p03.json' 'true'),
        (New-NvJobsOrderFile 'p04.json' 'null')) -Dirs @('d01.json')
    # a file holding a list, as Read-ChatqJson's return unrolls it
    New-NvJobsOrderCase 'array-files' @(
        (New-NvJobsOrderFile 'r01.json' ('[{"id":"r01a","tag":"r01a",' + (Get-NvJobsOrderAt 11) + '},{"id":"r01b","tag":"r01b",' + (Get-NvJobsOrderAt 12) + '}]')),
        (New-NvJobsOrderFile 'r02.json' ('[{"id":"r02a","tag":"r02a",' + (Get-NvJobsOrderAt 21) + '}]')),
        (New-NvJobsOrderFile 'r03.json' '[]'),
        (New-NvJobsOrderFile 'r04.json' ('[[{"id":"r04a","tag":"r04a",' + (Get-NvJobsOrderAt 41) + '}]]')),
        (New-NvJobsOrderFile 'r05.json' ('[[{"id":"r05a","tag":"r05a",' + (Get-NvJobsOrderAt 51) + '},{"id":"r05b","tag":"r05b",' + (Get-NvJobsOrderAt 52) + '}]]')),
        (New-NvJobsOrderFile 'r06.json' ('[{"id":"r06a","tag":"r06a",' + (Get-NvJobsOrderAt 6) + '},null]')),
        (New-NvJobsOrderFile 'r07.json' ('[{"id":"r07a","tag":"r07a",' + (Get-NvJobsOrderAt 7) + '},"r07s"]')),
        (New-NvJobsOrderFile 'r08.json' ('[{"id":"r08a","tag":"r08a",' + (Get-NvJobsOrderAt 8) + '},{"x":1,"tag":"r08x",' + (Get-NvJobsOrderAt 9) + '}]')),
        (New-NvJobsOrderFile 'r09.json' ('[{"x":1,"tag":"r09x",' + (Get-NvJobsOrderAt 31) + '},{"y":1,"tag":"r09y",' + (Get-NvJobsOrderAt 32) + '}]')),
        (New-NvJobsOrderFile 'r10.json' '["x","y"]'),
        (New-NvJobsOrderFile 'r11.json' '[{"id":[],"tag":"r11a"},{"id":[],"tag":"r11b"}]'),
        (New-NvJobsOrderFile 'r12.json' ('[{"id":0,"tag":"r12a",' + (Get-NvJobsOrderAt 33) + '},{"id":0,"tag":"r12b",' + (Get-NvJobsOrderAt 34) + '}]')),
        (New-NvJobsOrderFile 'r13.json' '[{"id":[],"tag":"r13a"},{"x":1,"tag":"r13b"}]'),
        (New-NvJobsOrderFile 'r14.json' '[null,null]'),
        (New-NvJobsOrderFile 'r15.json' '[false,0]'))
    # a time with no zone: UTC to 5.1, this zone's wall clock to pwsh 7
    New-NvJobsOrderCase 'created-zoneless' @(
        (New-NvJobsOrderJob 'z01' '"createdAt":"2026-10-15T05:00:00Z"'),
        (New-NvJobsOrderJob 'z02' '"createdAt":"2026-10-15T10:00:00"'))
    New-NvJobsOrderCase 'first-zoneless' @(
        (New-NvJobsOrderJob 'y01' '"first":"2026-10-15T12:00:00Z"'),
        (New-NvJobsOrderJob 'y02' '"first":"2026-10-15T10:00:00"')) -Zone 'SA Pacific Standard Time' -Offset -300
    New-NvJobsOrderCase 'no-queue' @() -NoQueue
    New-NvJobsOrderCase 'empty-queue' @()

    New-NvJobsOrderLane 'lane-provider' ([ordered]@{ provider = 'claude' })
    New-NvJobsOrderLane 'lane-home' ([ordered]@{ provider = 'codex'; home = 'acct\.codex-b' })
    New-NvJobsOrderLane 'lane-home-empty' ([ordered]@{ provider = 'claude'; home = '' })
    New-NvJobsOrderLane 'lane-home-null' ([ordered]@{ provider = 'claude'; home = $null })
    New-NvJobsOrderLane 'lane-home-true' ([ordered]@{ provider = 'claude'; home = $true })
    New-NvJobsOrderLane 'lane-home-zero' ([ordered]@{ provider = 'claude'; home = 0 })
    New-NvJobsOrderLane 'lane-home-zero-text' ([ordered]@{ provider = 'claude'; home = '0' })
    New-NvJobsOrderLane 'lane-home-space' ([ordered]@{ provider = 'claude'; home = ' ' })
    New-NvJobsOrderLane 'lane-home-list' ([ordered]@{ provider = 'claude'; home = @('a', 'b') })
    New-NvJobsOrderLane 'lane-home-list-null' ([ordered]@{ provider = 'claude'; home = @($null, 'x') })
    New-NvJobsOrderLane 'lane-home-empty-list' ([ordered]@{ provider = 'claude'; home = @() })
    New-NvJobsOrderLane 'lane-provider-null' ([ordered]@{ provider = $null; home = 'h' })
    New-NvJobsOrderLane 'lane-provider-missing' ([ordered]@{ home = 'h' })
    New-NvJobsOrderLane 'lane-provider-number' ([ordered]@{ provider = 5 })
    New-NvJobsOrderLane 'lane-provider-list' ([ordered]@{ provider = @('claude'); home = 'h' })
    New-NvJobsOrderLane 'lane-case' ([ordered]@{ Provider = 'claude'; HOME = 'h' })
    New-NvJobsOrderLane 'lane-non-ascii' ([ordered]@{ provider = 'claude'; home = (U 'acct\\\u00e9l\u00e8ve \u4e2d') })
    New-NvJobsOrderLane 'lane-string-job' 'claude'
} -Expect {
    param($In, $Name)
    if ([string]$In.kind -eq 'lane') {
        $job = (ConvertTo-NvJson $In.job -Compress) | ConvertFrom-Json
        return (Get-ChatqLane $job)
    }
    $null = Enter-NvData $Name
    $q = $script:ChatqQueueDir
    if (-not ((Get-NvHas $In 'noQueue') -and $In.noQueue)) {
        $null = New-Item -ItemType Directory -Path $q -Force
        if (Get-NvHas $In 'dirs') { foreach ($d in @($In.dirs)) { $null = New-Item -ItemType Directory -Path (Join-Path $q ([string]$d)) -Force } }
        foreach ($f in @($In.files)) {
            $bytes = [byte[]]$script:NvUtf8.GetBytes([string]$f.text)
            if ((Get-NvHas $f 'bom') -and $f.bom) { $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes) }
            [IO.File]::WriteAllBytes((Join-Path $q ([string]$f.name)), $bytes)
        }
    }
    $got = Use-NvCulture 'en-US' {
        Use-NvTimeZone ([string]$In.zone) {
            # the watcher's own: an [int] that throws in a sort key is an
            # error record, and a $null key
            $ErrorActionPreference = 'Continue'
            $listed = @(Get-ChildItem -LiteralPath $q -Filter *.json -File -EA SilentlyContinue | ForEach-Object { $_.Name })
            $order = New-Object System.Collections.Generic.List[object]
            foreach ($j in @(Get-ChatqJobs 2>$null)) {
                if ($j -is [System.Management.Automation.PSCustomObject]) { $order.Add($j.tag) } else { $order.Add($j) }
            }
            [ordered]@{ listed = $listed; order = $order.ToArray() }
        }
    }
    return $got
}
