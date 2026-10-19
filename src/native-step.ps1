# A helper step of chatqd, the native watcher (native/SPEC.md 3.6): what
# chatqd starts for each piece of work still written in PowerShell, as
#   <powershell> -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file>
#     -In <D>\native\step-<n>.in.json -Out <D>\native\step-<n>.out.json
#     -Watcher <chatqd's pid> -WatcherStart <its start, UTC ticks> [-Seams <file>]
# Not a part of the script: it loads the script as the watcher does, runs
# the one op In names (Invoke-ChatqNativeStep, src/watcher.ps1) and exits.
# Exit 3 is a load that failed; any op's outcome is in Out, with exit 0.
param([string]$In, [string]$Out, [int]$Watcher, [int64]$WatcherStart, [string]$Seams)
try { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Charlie-and-the-chat-factory.ps1') }
catch { exit 3 }
# Bypass was for the load: the runs and your alert command run under your
# own policy, as the watcher's do
Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue

# The harness's seams file (native/SPEC.md 6.5): each name onto the seams
# the self-test sets in-process. capture records a toast, a push, a Join or
# down call, a live chat's alert and (with spawn) a watcher's launch as
# <capture>/<kind>-<n>.json, the first n free, instead of making it.
function Save-StepCapture([string]$Kind, $Record) {
    $dir = $script:StepCaptureDir
    for ($n = 1; ; $n++) {
        $p = Join-Path $dir "$Kind-$n.json"
        if (Test-Path -LiteralPath $p) { continue }
        try { $fs = [System.IO.File]::Open($p, 'CreateNew', 'Write', 'None') }
        catch { if (Test-Path -LiteralPath $p) { continue }; throw }
        try { $b = [System.Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 8)); $fs.Write($b, 0, $b.Length) }
        finally { $fs.Dispose() }
        return
    }
}
$stepSeams = if ($Seams) { try { Get-Content -LiteralPath $Seams -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
$stepHas = { param($n) $stepSeams -and $stepSeams.PSObject.Properties[$n] }
if (& $stepHas 'capture') {
    $script:StepCaptureDir = [string]$stepSeams.capture
    $script:ChatqToastSeam = { param($Title, $Text) Save-StepCapture 'toast' ([ordered]@{ title = $Title; text = $Text }) }
    $script:ChatqNtfySeam = { param($server, $body, $headers) Save-StepCapture 'ntfy' ([ordered]@{ server = $server; body = $body; headers = $headers }) }
    $script:ChatqJoinSeam = { param($url) Save-StepCapture 'join' ([ordered]@{ url = $url }); $null }
    $script:ChatqDownSeam = { param($Method, $Url, $Headers, $Body) Save-StepCapture 'down' ([ordered]@{ method = $Method; url = $Url; headers = $Headers; body = $Body }); $null }
    $script:ChatqLiveSendSeam = { param($o) Save-StepCapture 'live' ([ordered]@{ alert = $o }) }
    if ((& $stepHas 'spawn') -and $stepSeams.spawn -eq $true) {
        $script:ChatqSpawn = { param($l) Save-StepCapture 'spawn' ([ordered]@{ engine = $l.Engine; exe = $l.Exe; args = @($l.Args); command = $l.Command }); $true }
    }
}
if (& $stepHas 'clock') {
    $script:ChatqClockSeam = if (($stepSeams.clock -is [int]) -or ($stepSeams.clock -is [long]) -or ($stepSeams.clock -is [double]) -or ($stepSeams.clock -is [decimal])) { (Get-Date).AddSeconds([double]$stepSeams.clock) }
    else { ConvertTo-ChatqDate $stepSeams.clock }
}
if (& $stepHas 'statusUrl') { $script:ChatqStatusUrl = [string]$stepSeams.statusUrl }
if (& $stepHas 'idleSeconds') { $script:ChatqIdleSeam = [double]$stepSeams.idleSeconds }
if (& $stepHas 'alive') {
    $stepAlive = [bool]$stepSeams.alive
    $script:ChatqAliveSeam = if ($stepAlive) { { param($Entry) $true } } else { { param($Entry) $false } }
    $script:ChatqAskAliveSeam = if ($stepAlive) { { param($Req) $true } } else { { param($Req) $false } }
}
if (& $stepHas 'ntfyBase') { $script:ChatqReplyServer = [string]$stepSeams.ntfyBase }
if (& $stepHas 'handoverOff') { $script:ChatHandoverOff = [bool]$stepSeams.handoverOff }

# The parent test: chatqd is alive while a process has its pid and its start
# time, to the second. None, or one whose start cannot be read, is a pid
# reused or chatqd gone, and a step that finds it so ends itself.
$script:ChatqStepParent = {
    try { [math]::Abs((Get-Process -Id $Watcher -EA Stop).StartTime.ToUniversalTime().Ticks - $WatcherStart) -le 10000000 } catch { $false }
}.GetNewClosure()

Invoke-ChatqNativeStep -In $In -Out $Out
exit 0
