<#
M3's hour (the M3 plan's step 5b, TESTING.md S59 step 1): the release
chatqd listening for real, about an hour.
Run 2026-10-22 (TESTING.md S59). Tier 1: needs the user's go-ahead (network
to ntfy.sh). Run it from a normal console. Where a firewall blocks outbound
connections by default (this PC's does), a new chatqd.exe gets WSAEACCES
(10013) on every connect and hands the window to the PowerShell watcher
(recorded by the spawn seam, not started): the hour then measures nothing,
so it needs an outbound allow rule for that exe, removed after.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m3\run-5b.ps1 [-Minutes 60] [-JunkEvery 10]

- The checkout is the one this script sits in. It must hold a release
  chatqd (native\target\release\chatqd.exe) and no data/config.json: a
  work clone, never the checkout a real watcher runs from.
- A throwaway root in this script's own data/ (tests/m3/data/5b, ignored
  by git as every data/ is): a copy of the checkout's loader and src/,
  with its own data/. Never the checkout's data/, never %TEMP%.
- A random topic (chatq5b-<24 hex>) and a random 32-byte key, both plain in
  root/data/config.json (no DPAPI: they are throwaway), no server named, so
  the poll goes to ntfy.sh. The topic is never printed or logged here: only
  its masked form, chatq5b-****<last 4>.
- seams: spawn + capture, so a respawn or handoff is recorded, never started.
- CLAUDE_CONFIG_DIR / CODEX_HOME / CHAT_CODE_USER point at empty folders in
  the root, so the board step scans no real chat.
- Every minute: chatqd's private bytes and working set to data/5b-samples.csv,
  and one "gate" row 60 s after the 10th poll (native/SPEC.md 3.3's gate).
  Every -JunkEvery minutes: one plain-text post to the topic, which the poll
  must log as junk (format refusal) with no step.
- At the end, in a finally (so also on an error or Ctrl+C): data/stop, the
  exit awaited, config.json deleted. Then a summary: the gate figure,
  time-weighted private MB (mean, max), poll failures, junk lines, steps
  run, a false "no ack" in chatqd.log, the topic in any log (must be none).
  The process is only ever the one this script started; nothing else is
  touched.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param([int]$Minutes = 60, [int]$JunkEvery = 10)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$clone = Split-Path -Parent (Split-Path -Parent $here)
$exe = Join-Path $clone 'native\target\release\chatqd.exe'
$root = Join-Path $here 'data\5b'
$data = Join-Path $root 'data'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "no release chatqd at $exe" }
if (Test-Path -LiteralPath (Join-Path $clone 'data\config.json')) { throw 'this checkout has a data/config.json: run it from a work clone' }

# the root, fresh
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $data
Copy-Item -LiteralPath (Join-Path $clone 'Charlie-and-the-chat-factory.ps1') -Destination $root
Copy-Item -LiteralPath (Join-Path $clone 'src') -Destination $root -Recurse
foreach ($d in 'claude', 'codex', 'code-user', 'capture') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $root $d) }

# topic and key: random, never shown
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$b = New-Object byte[] 12; $rng.GetBytes($b)
$topic = 'chatq5b-' + (($b | ForEach-Object { $_.ToString('x2') }) -join '')
$k = New-Object byte[] 32; $rng.GetBytes($k)
$key = [Convert]::ToBase64String($k).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$mask = 'chatq5b-****' + $topic.Substring($topic.Length - 4)
$utf8 = New-Object System.Text.UTF8Encoding $false
$cfg = [ordered]@{ reply = [ordered]@{ on = $true; topic = @{ value = $topic; protected = $false }; key = @{ value = $key; protected = $false } } }
[IO.File]::WriteAllText((Join-Path $data 'config.json'), ($cfg | ConvertTo-Json -Depth 5), $utf8)
$until = [DateTime]::UtcNow.AddMinutes($Minutes + 5).ToString('o')
[IO.File]::WriteAllText((Join-Path $data 'replies.json'), (@{ openUntil = $until } | ConvertTo-Json), $utf8)
$seams = Join-Path $root 'seams.json'
[IO.File]::WriteAllText($seams, (@{ spawn = $true; capture = (Join-Path $root 'capture') } | ConvertTo-Json), $utf8)

# chatqd's environment: what vectors.ps1 sets, so nothing real is reached
$env:CHATQ_NATIVE_SEAMS = $seams
$env:CLAUDE_CONFIG_DIR = Join-Path $root 'claude'
$env:CODEX_HOME = Join-Path $root 'codex'
$env:CHAT_CODE_USER = Join-Path $root 'code-user'
$env:CHATQ_NOFRONT = '1'
$env:CHATQ_GH = Join-Path $root 'no-such-gh.exe'
foreach ($n in 'CHATQ_ENGINE', 'CHATQ_CHATQD', 'CHATQ_CLAUDE', 'CHATQ_CODEX', 'CHATQ_WATCHER') { Remove-Item "env:$n" -EA SilentlyContinue }

Write-Host "5b: topic $mask, $Minutes min, root $root"
$loader = Join-Path $root 'Charlie-and-the-chat-factory.ps1'
$logs = Join-Path $data 'logs'
# read while chatqd may be appending: a busy file reads as empty this time
function LogText($n) { $f = Join-Path $logs $n; if (Test-Path -LiteralPath $f) { try { [IO.File]::ReadAllText($f) } catch { '' } } else { '' } }
$p = $null
$csv = Join-Path $data '5b-samples.csv'
$posted = 0
$samples = New-Object System.Collections.ArrayList
# The gate figure (native/SPEC.md 3.3): private bytes 60 s after
# the 10th poll. chatqd logs no line per poll, so the 10th is reckoned from
# the listening line, which the first poll comes just before, at the open
# window's cadence (gates::POLL_OPEN_SECONDS, 15 s): 9 x 15 + 60 s after it.
$gateAfter = 9 * 15 + 60
$listenAt = $null
$gate = $null
try {
    $p = Start-Process -FilePath $exe -ArgumentList @('watch', '--root', "`"$root`"", '--script', "`"$loader`"", '--ps', "`"$ps`"") -WindowStyle Hidden -PassThru
    Write-Host "5b: chatqd pid $($p.Id)"
    [IO.File]::WriteAllText($csv, "at,privateMB,workingSetMB,kind`r`n", $utf8)
    $t0 = Get-Date
    $nextSample = $t0
    while (((Get-Date) - $t0).TotalMinutes -lt $Minutes) {
        $p.Refresh()
        if ($p.HasExited) { Write-Host "5b: chatqd exited early, code $($p.ExitCode)"; break }
        $now = Get-Date
        if (-not $listenAt -and (LogText 'watcher.log') -match 'listening for phone replies') {
            $listenAt = $now
            Write-Host "5b: listening at +$([int]($now - $t0).TotalSeconds) s; gate sample $gateAfter s on"
        }
        $isGate = $listenAt -and -not $gate -and ($now - $listenAt).TotalSeconds -ge $gateAfter
        if ($isGate -or $now -ge $nextSample) {
            $priv = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
            $ws = [math]::Round($p.WorkingSet64 / 1MB, 2)
            if ($isGate) {
                $gate = $priv
                [IO.File]::AppendAllText($csv, "$($now.ToString('o')),$priv,$ws,gate`r`n", $utf8)
                Write-Host "5b: gate sample $priv MB private"
            }
            if ($now -ge $nextSample) {
                $null = $samples.Add($priv)
                [IO.File]::AppendAllText($csv, "$($now.ToString('o')),$priv,$ws,minute`r`n", $utf8)
                $nextSample = $nextSample.AddSeconds(60)
            }
        }
        $min = [int]($now - $t0).TotalMinutes
        if ($JunkEvery -gt 0 -and $min -ge ($posted + 1) * $JunkEvery) {
            $posted++
            try {
                $null = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "https://ntfy.sh/$topic" -Body "5b junk $posted" -TimeoutSec 15
                Write-Host "5b: junk post $posted to $mask"
            }
            catch { Write-Host "5b: junk post $posted failed: $($_.Exception.GetType().Name)" }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    # stop it, and wait for its own exit; only ever the one this script
    # started. config.json goes whatever happened above
    if ($p) {
        try { [IO.File]::WriteAllText((Join-Path $data 'stop'), '', $utf8) } catch { }
        if (-not $p.HasExited -and -not $p.WaitForExit(60000)) { Write-Host '5b: chatqd did not stop within 60 s: killing the one this script started'; try { $p.Kill() } catch { } }
    }
    Remove-Item -LiteralPath (Join-Path $data 'config.json') -Force -EA SilentlyContinue
}

$wl = LogText 'watcher.log'; $rl = LogText 'replies.log'; $dl = LogText 'chatqd.log'
$leak = @(Get-ChildItem -LiteralPath $logs -File -EA SilentlyContinue | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains($topic) }).Count
$steps = @(Select-String -InputObject $dl -Pattern 'step \d+ (\S+) exited' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }) | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }
$mean = if ($samples.Count) { [math]::Round(($samples | Measure-Object -Average).Average, 2) } else { 0 }
$max = if ($samples.Count) { ($samples | Measure-Object -Maximum).Maximum } else { 0 }
$lastJson = Join-Path $data 'native\last.json'
$last = if (Test-Path -LiteralPath $lastJson) { try { ([IO.File]::ReadAllText($lastJson) | ConvertFrom-Json).state } catch { '<unreadable>' } } else { '<none>' }
Write-Host ''
Write-Host "5b summary ($mask)"
Write-Host "  gate MB        : $(if ($null -ne $gate) { $gate } else { '<not reached>' }) (private, 60 s after the 10th poll by the 15 s cadence)"
Write-Host "  samples        : $($samples.Count), one a minute"
Write-Host "  private MB     : mean $mean (time-weighted: equal intervals), max $max"
Write-Host "  junk posted    : $posted; refusal lines in replies.log: $(([regex]::Matches($rl, 'refused - format')).Count)"
Write-Host "  poll failed    : $(([regex]::Matches($rl, 'poll failed')).Count)"
Write-Host "  steps          : $($steps -join ', ')"
Write-Host "  'no ack'       : $(([regex]::Matches($dl, 'no ack')).Count)"
Write-Host "  topic in logs  : $leak file(s) (must be 0)"
Write-Host "  exit code      : $(if ($p -and $p.HasExited) { $p.ExitCode } else { '<none>' }); last.json state: $last"
Write-Host "  captured       : $(@(Get-ChildItem -LiteralPath (Join-Path $root 'capture') -File -EA SilentlyContinue).Count) record(s)"
Write-Host "  listening line : $([bool]($wl -match 'listening for phone replies'))"
