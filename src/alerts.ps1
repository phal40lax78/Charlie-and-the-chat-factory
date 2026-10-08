# Charlie-and-the-chat-factory, src/alerts.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region config and alerts -----------------------------------------------------

function Get-ChatqConfig {
    $c = Read-ChatqJson $script:ChatqConfigPath
    if (-not $c) { $c = [pscustomobject]@{} }
    return $c
}

<#
One lock, data/config.lock, around every read-change-save of config.json,
as Use-ChatqReplyState holds data/replies.lock: chatnotify, the setup
window, a pairing confirmed from the phone, the overlay's settings, the
ask and auto-continue switches each read the file, change their part and
save the whole. Two of them at once - a pairing confirmed while the setup
window saved - and the one saving last put back what the other had just
changed: the key a phone was paired with, gone. Taken, the file is read
again under it, so each writes over what the other saved, not what it read
before. No caller takes it inside itself today - Set-ChatqNotifyConfig
lets go before Set-ChatqAskChanges takes it - but one that did would not
wait 3 s on its own handle and fail: taken again it only counts, and lets
go with the outer one. Up to 3 s of tries, each wait a random length; then it throws. Never
held across anything that sends or waits on the network.
#>
$script:ChatqConfigLockDepth = 0
$script:ChatqConfigLockHandle = $null

function Lock-ChatqConfig {
    if ($script:ChatqConfigLockDepth -gt 0 -and $script:ChatqConfigLockHandle) { $script:ChatqConfigLockDepth++; return }
    $h = Open-ChatqLock $script:ChatqConfigLockPath
    if (-not $h) { throw 'data/config.lock is held by another process' }
    $script:ChatqConfigLockHandle = $h
    $script:ChatqConfigLockDepth = 1
}

function Unlock-ChatqConfig {
    if ($script:ChatqConfigLockDepth -le 0) { return }
    $script:ChatqConfigLockDepth--
    if ($script:ChatqConfigLockDepth -gt 0) { return }
    if ($script:ChatqConfigLockHandle) { $script:ChatqConfigLockHandle.Dispose() }
    $script:ChatqConfigLockHandle = $null
}

function Save-ChatqConfig {
    # config.json saved whole; off Windows it holds the keys unprotected, so
    # the owner's alone, as every save of it keeps it. The caller holds
    # Lock-ChatqConfig and read what it changes under it.
    param($Cfg)
    Save-ChatqJson $script:ChatqConfigPath $Cfg
    if (-not $script:ChatqIsWindows) { try { & chmod 600 $script:ChatqConfigPath } catch {} }
}

function Set-ChatqProp {
    # ConvertFrom-Json objects only take assignment to properties they have
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Protect-ChatqSecret {
    # DPAPI on Windows: only this user on this machine can read it back, which
    # is exactly who the watcher runs as. Elsewhere there is no DPAPI, so it is
    # stored as given and the file is made owner-only.
    param([string]$Plain)
    if ($script:ChatqIsWindows) {
        $ss = ConvertTo-SecureString $Plain -AsPlainText -Force
        return @{ value = (ConvertFrom-SecureString $ss); protected = $true }
    }
    return @{ value = $Plain; protected = $false }
}

function Unprotect-ChatqSecret {
    param($Secret)
    if (-not $Secret -or -not $Secret.value) { return $null }
    if (-not $Secret.protected) { return [string]$Secret.value }
    try {
        $ss = ConvertTo-SecureString ([string]$Secret.value)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    catch { return $null }
}

function Get-ChatqJoinUrl {
    # Join's push API is one GET. Hangul is nine bytes per syllable once
    # escaped, so the text is trimmed until the whole URL fits. -Url is the
    # reply link a tap opens; -NotificationId makes a later alert replace
    # this one on the phone. When even 20 characters of text do not fit, the
    # icon goes, then the chat's title inside the reply link (its c=).
    # -Say and -Language: a line the phone reads aloud (Get-ChatqJoinSay),
    # after the text in the query; dropped whole once the text is down to 20
    # characters, before the icon - spoken words matter less than a
    # notification that can be read.
    param([string]$Key, [string]$Device, [string]$Title, [string]$Text, [int]$Priority,
        [string]$Url, [string]$NotificationId, [string]$Icon, [switch]$DismissOnTouch,
        [string]$Say, [string]$Language)
    $base = 'https://joinjoaomgcd.appspot.com/_ah/api/messaging/v1/sendPush?'
    $dev = if ($Device -match '^[0-9a-fA-F]{32}$' -or $Device -match '^group\.') { 'deviceId' } else { 'deviceNames' }
    $t = [string]$Text
    $link = $Url
    $spoken = [string]$Say
    while ($true) {
        $q = [ordered]@{ apikey = $Key; $dev = $Device; title = $Title; text = $t; priority = $Priority; group = 'chatq' }
        if ($spoken) { $q.Insert(4, 'say', $spoken); if ($Language) { $q.Insert(5, 'language', $Language) } }
        if ($link) { $q['url'] = $link }
        if ($Icon) { $q['icon'] = $Icon }
        if ($NotificationId) { $q['notificationId'] = $NotificationId }
        if ($DismissOnTouch) { $q['dismissOnTouch'] = 'true' }
        $url = $base + (($q.GetEnumerator() | ForEach-Object { $_.Key + '=' + (ConvertTo-ChatqUriPart ([string]$_.Value)) }) -join '&')
        if ($url.Length -le 1900) { return $url }
        if ($t.Length -gt 20) {
            # never between the two halves of an emoji
            $cut = [int]($t.Length * 0.85)
            if ([char]::IsHighSurrogate($t[$cut - 1])) { $cut-- }
            $t = $t.Substring(0, $cut).TrimEnd() + $script:ChatqEllipsis
            continue
        }
        if ($spoken) { $spoken = ''; continue }
        if ($Icon) { $Icon = ''; continue }
        if ($link -and $link -match '[#&]c=[^&]') { $link = $link -replace '([#&]c=)[^&]*', '$1'; continue }
        return $url
    }
}

function Send-ChatqAlert {
    <#
    Every alert goes to logs/alerts.log, then to whichever channels are set up:
      toast    the desktop, on by default - free, local, nothing leaves the PC
      command  your own PowerShell, with the alert in $env:CHATQ_* (chatnotify -Command);
               with commandLinks on (chatnotify -CommandLinks on) it is a phone
               channel too: it runs where Join and ntfy go, past the same
               gates, and gets the reply link as $env:CHATQ_LINK - an alert
               stopped short of the phone runs it all the same, with no link
      join     the phone, through Join (joaomgcd)
      ntfy     the phone, through ntfy
    The two phone channels stay quiet while you are at the PC - keyboard or
    mouse used in the last quietMinutes (5) - since the toast says it there.
    -Loud (chatnotify -Test) goes through regardless. Titles all start
    "chatq <dot> ", so a Tasker profile can filter them - or match only "needs
    input" and "failed". What the text carries (chat title, an excerpt of the
    reply) passes through the push service's servers.
    config phoneEvents holds some events back from the phone (not 'test',
    'reply' or 'pair'). With replies on and a phone paired (chatnotify
    -Pair) each phone alert carries a link to answer it from the phone - see
    src/phone.ps1 - and a window opens in which the watcher listens for the
    answer. -Job is the job the alert is about: the link says which chat to
    answer, and Join shows alerts about one chat as one notification.
      -Quick     each phone channel tried once, 8 s at most, and no command
                 unless it carries the link, then held to 8 s as well: for
                 a push sent from inside a run, which waits on it
      -NoReply   no link, nothing registered, no window: a refusal
      -PairLink  the link is this one, the pairing push's, and nothing is
                 registered; never through ntfy over http, which drops it
      -UsageKind a usage alert's kind (threshold, soon, reset), kept with it
                 in the registry: a soon one's link offers Send now
      -SeenAt    when what the alert says was so, if before now (the outbox
                 holds alerts a while): an answer to it is judged against
                 that moment, not the push's (Get-ChatqMovedOn)
    Quiet hours (src/phone-extras.ps1) come after presence: in the window,
    the phone's alert is held for the summary unless urgent or -Loud, and
    what goes then is never read aloud. Held alerts waiting once the window
    is over go first, as the summary, ahead of this one - but not ahead of a
    -Quick one: the summary is an ordinary alert, its command and its three
    tries each, and a run waits on a -Quick push. The watcher's loop, the
    outbox or the next ordinary alert sends it then.
      -Card, -Permit, -Tag, -ToastText  a permission request (src/permit.ps1):
                 its card, sealed for the phone under the alert's id as it
                 goes into the link; what an answer must match, in the
                 registry; Join's notification id; the toast's words. The
                 alert's id is kept in $script:ChatqLastAlertAid
    A permission request goes -Loud: past presence and past quiet hours,
    since a run waits on it and a held one could only expire unanswered;
    -Quick keeps it from being read aloud.
    #>
    param([string]$Event, [string]$Text, [int]$Priority = 0, [switch]$Loud, $Job,
        [switch]$Quick, [switch]$NoReply, [string]$PairLink,
        [string]$UsageKind, [string]$Card, $Permit, [string]$Tag, [string]$ToastText, $SeenAt)
    if (-not $Quick -and -not $script:ChatqSendingSummary -and (Test-ChatqHeldWaiting)) { $null = Send-ChatqHeldSummary }
    $title = "chatq $($script:ChatqDot) $Event"
    $script:ChatqAlertReport = [System.Collections.Generic.List[string]]::new()
    $script:ChatqLastAlertAid = $null
    try {
        New-ChatqDir $script:ChatqLogDir
        $line = "{0}`t{1}`t{2}" -f (Get-Date).ToString('o'), $Event, ($Text -replace '\s+', ' ')
        [System.IO.File]::AppendAllText((Join-Path $script:ChatqLogDir 'alerts.log'), $line + "`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
    $cfg = Get-ChatqConfig
    $present = Test-ChatqUserPresent $cfg
    $toastOn = -not ($cfg.PSObject.Properties['toast'] -and $cfg.toast -eq $false)
    if ($toastOn) {
        try { Show-ChatqToast $title $(if ($ToastText) { $ToastText } else { $Text }); $script:ChatqAlertReport.Add('toast: shown') }
        catch { $script:ChatqAlertReport.Add("toast: $($_.Exception.Message)") }
    }
    # your command runs on every alert, as it always has; one that carries
    # the reply link waits for the link, and runs below with the phones -
    # or, when the alert stops short of the phone, on the way out, linkless
    $cmdLinks = Test-ChatqCommandLinks $cfg
    $runCmd = {
        $e = Invoke-ChatqAlertCommand $cfg $Event $title $Text $Priority $present
        if ($e) { $script:ChatqAlertReport.Add($e) }
        elseif ($cfg.PSObject.Properties['command'] -and $cfg.command) { $script:ChatqAlertReport.Add('command: ran') }
    }
    if (-not $Quick -and -not $cmdLinks) { & $runCmd }
    $short = { if ($cmdLinks -and -not $Quick) { & $runCmd } }

    $phones = @()
    if ($cfg.PSObject.Properties['join'] -and $cfg.join) { $phones += 'join' }
    if ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy) { $phones += 'ntfy' }
    if ($cmdLinks) { $phones += 'command' }
    if (-not $phones) { $script:ChatqLastAlertError = 'no phone channel set up'; return $false }
    if (-not (Test-ChatqPhoneEvent $cfg $Event)) {
        $script:ChatqAlertReport.Add("phone: skipped - $Event is not among the phone's events")
        $script:ChatqLastAlertError = "the phone gets no '$Event' alerts (chatnotify -Events)"
        & $short
        return $false
    }
    if ($present -and -not $Loud) {
        $script:ChatqAlertReport.Add('phone: skipped - you are at the PC')
        $script:ChatqLastAlertError = 'you are at the PC, so the phone was left alone'
        & $short
        return $false
    }
    if (Test-ChatqHoldAlert $cfg $Event $Text $Priority $Job -Loud:$Loud) { & $short; return $false }
    $quietIn = Test-ChatqQuietIn $cfg
    # usage and the chats at work, read as it goes (the outbox can hold an
    # alert a while): the push's last line and the page's s=. Not on the
    # answers, pairing or permission pushes, which are about something else
    $foot = $null
    if ($Event -notin 'reply', 'pair', 'permission' -and -not $PairLink -and -not $Card) { $foot = Get-ChatqAlertFooter }
    # an answerable alert: registered before it goes, so a reply that comes
    # back at once finds it
    $rc = $null
    $reply = $null
    if ($PairLink) { $reply = [pscustomobject]@{ Aid = $null; Link = $PairLink } }
    elseif (-not $NoReply) {
        try {
            $rc = Get-ChatqReplyConfig $cfg
            if ($rc.Links) { $reply = New-ChatqReplyAlert -Event $Event -Job $Job -Rc $rc -UsageKind $UsageKind -Permit $Permit -Card $Card -SeenAt $SeenAt -Status $foot }
            # the whole answer to the down topic ahead of the push, and the
            # link made again to say so (src/phone-down.ps1)
            if ($reply) { Update-ChatqReplyFull $rc $reply $Event $Job }
        }
        catch { $reply = $null }
    }
    if ($reply -and $reply.Aid) { $script:ChatqLastAlertAid = $reply.Aid }
    # A permission request is nothing without its entry and its card: the
    # push would open nothing, for a request its sender then declines as
    # not sent. So it does not go at all, and the decline says why.
    if (($Permit -or $Card) -and -not ($reply -and $reply.Aid)) {
        $script:ChatqAlertReport.Add('phone: skipped - the permission request could not be registered')
        $script:ChatqLastAlertError = 'the permission request could not be registered'
        & $short
        return $false
    }
    $sent = $false
    $script:ChatqLastAlertError = $null
    $phoneText = if ($foot) { "$Text`n$foot" } else { $Text }
    foreach ($ch in $phones) {
        # the pairing push is nothing without its link, which ntfy over
        # plain http leaves out: through there it would count as sent and
        # open nothing on the phone
        if ($PairLink -and $ch -eq 'ntfy' -and $cfg.ntfy.server -and ([string]$cfg.ntfy.server) -notmatch '^https://') {
            $script:ChatqAlertReport.Add('ntfy: skipped - not https, so the pairing link cannot go that way')
            if (-not $sent -and -not $script:ChatqLastAlertError) { $script:ChatqLastAlertError = 'ntfy: not https - the pairing link cannot go that way' }
            continue
        }
        $err = if ($ch -eq 'join') { Send-ChatqJoin $cfg $title $phoneText $Priority -Reply $reply -Job $Job -Quick:$Quick -Event $Event -NoSay:$quietIn -Tag $Tag }
        elseif ($ch -eq 'command') {
            # CHATQ_TEXT the alert's own words, as on every other run of it; a
            # clean exit is the command's word that it sent the alert on
            $ce = Invoke-ChatqAlertCommand $cfg $Event $title $Text $Priority $present -Link $(if ($reply) { $reply.Link } else { '' }) -Quick:$Quick
            if ($ce) { $ce -replace '^command: ', '' } else { $null }
        }
        else { Send-ChatqNtfy $cfg $title $phoneText $Priority -Click $(if ($reply) { $reply.Link } else { '' }) -Quick:$Quick }
        if ($err) { $script:ChatqAlertReport.Add("${ch}: $err"); $script:ChatqLastAlertError = "${ch}: $err" }
        else { $script:ChatqAlertReport.Add("${ch}: sent"); $sent = $true }
    }
    if ($sent -and $reply) {
        # Listen for the answer. A watcher that is running does that from
        # its next pass; with none running, one is started just to listen.
        # The window is written before the watcher's lock is looked at, and
        # a watcher on its way out looks at the window after letting go of
        # the lock, so one of the two always sees the other.
        try {
            if (-not $PairLink) { Open-ChatqReplyWindow $rc }
            if ($env:CHATQ_WATCHER -ne '1' -and -not (Test-ChatqWatcherAlive)) { [void](Start-ChatqWatcherProcess) }
        }
        catch {}
    }
    return $sent
}

function Send-ChatqJoin {
    # $null when sent, else what went wrong. -Reply: New-ChatqReplyAlert's
    # answer, whose link a tap on the notification opens. -Quick: one try.
    # -Event: which alert, for the line read aloud when join.say names it -
    # never with -Quick (a push from inside a run) or -NoSay (quiet hours).
    # -Tag: the notification id to use, for a push of its own (a permission
    # request is not replaced by the chat's next alert)
    param($Cfg, [string]$Title, [string]$Text, [int]$Priority, $Reply, $Job, [switch]$Quick,
        [string]$Event, [switch]$NoSay, [string]$Tag)
    $key = Unprotect-ChatqSecret $Cfg.join.apiKey
    if (-not $key -or -not $Cfg.join.device) { return 'no key or device set' }
    # icon: chatq's own unless join.icon says otherwise ('' for none)
    $icon = if ($Cfg.join.PSObject.Properties['icon']) { [string]$Cfg.join.icon } else { $script:ChatqJoinIcon }
    # perChat (on unless false): "done" replaces "started" for the same chat
    # instead of piling up under it
    $perChat = -not ($Cfg.join.PSObject.Properties['perChat'] -and $Cfg.join.perChat -eq $false)
    $nid = if ($perChat -and $Job -and $Job.sessionId) { 'chatq-' + ([string]$Job.sessionId).Substring(0, [Math]::Min(12, ([string]$Job.sessionId).Length)) } else { '' }
    if ($Tag) { $nid = $Tag }
    $link = if ($Reply) { [string]$Reply.Link } else { '' }
    $spoken = if ($Event -and -not $Quick -and -not $NoSay) { Get-ChatqJoinSay $Cfg $Event $Job $Text } else { $null }
    $url = Get-ChatqJoinUrl $key $Cfg.join.device $Title $Text $Priority -Url $link -NotificationId $nid -Icon $icon -DismissOnTouch:([bool]$link) -Say $(if ($spoken) { $spoken.Say } else { '' }) -Language $(if ($spoken) { $spoken.Language } else { '' })
    if ($script:ChatqJoinSeam) { return (& $script:ChatqJoinSeam $url) }   # tests
    Enable-ChatqTls12
    $last = $null
    $tries = if ($Quick) { 1 } else { 3 }
    for ($try = 1; $try -le $tries; $try++) {
        try {
            $r = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $(if ($Quick) { 8 } else { 20 }) -UseBasicParsing
            if ($r.success) { return $null }
            return [string]$r.errorMessage
        }
        catch { $last = $_.Exception.Message; if ($try -lt $tries) { Start-Sleep -Seconds (2 * $try) } }
    }
    return $last
}

function Send-ChatqNtfy {
    # Published as JSON to the server root rather than with Title/Priority
    # headers: .NET Framework will not put Hangul - or the middle dot every
    # title starts with - into a header. $null when sent, else the error.
    # -Click: the reply link, opened by a tap on the notification - only over
    # https: the pairing push's link names the reply topic, and a server
    # reached in the clear would show it to the whole network. -Quick: one
    # try.
    param($Cfg, [string]$Title, [string]$Text, [int]$Priority, [string]$Click, [switch]$Quick)
    $topic = Unprotect-ChatqSecret $Cfg.ntfy.topic
    if (-not $topic) { return 'no topic set' }
    $server = if ($Cfg.ntfy.server) { ([string]$Cfg.ntfy.server).TrimEnd('/') } else { 'https://ntfy.sh' }
    $msg = [ordered]@{
        topic = $topic; title = $Title; message = $Text; tags = @('robot')
        # chatq's 0/1/2 onto ntfy's default/high/urgent
        priority = @(3, 4, 5)[[Math]::Min(2, [Math]::Max(0, $Priority))]
    }
    if ($Click -and $server -match '^https://') { $msg['click'] = $Click }
    $body = $msg | ConvertTo-Json -Compress
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($body)
    $headers = @{}
    $tok = if ($Cfg.ntfy.PSObject.Properties['token']) { Unprotect-ChatqSecret $Cfg.ntfy.token } else { $null }
    if ($tok) { $headers['Authorization'] = "Bearer $tok" }
    if ($script:ChatqNtfySeam) { & $script:ChatqNtfySeam $server $body $headers; return $null }   # tests
    Enable-ChatqTls12
    $last = $null
    $tries = if ($Quick) { 1 } else { 3 }
    for ($try = 1; $try -le $tries; $try++) {
        try {
            $null = Invoke-RestMethod -Uri $server -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' `
                -Headers $headers -TimeoutSec $(if ($Quick) { 8 } else { 20 }) -UseBasicParsing
            return $null
        }
        catch { $last = $_.Exception.Message; if ($try -lt $tries) { Start-Sleep -Seconds (2 * $try) } }
    }
    return $last
}

function Enable-ChatqTls12 {
    if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}

function Test-ChatqCommandLinks {
    # Your command is set and carries the reply link (chatnotify -CommandLinks
    # on): a phone channel then, as Join and ntfy over https are. Off unless
    # asked for - the link goes wherever the command sends it, and chatq
    # cannot tell whether that is private.
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    return [bool]($Cfg.PSObject.Properties['command'] -and $Cfg.command -and $Cfg.PSObject.Properties['commandLinks'] -and $Cfg.commandLinks -eq $true)
}

function Invoke-ChatqAlertCommand {
    # Your own PowerShell per alert - Pushover, Telegram, a Tasker webhook. The
    # alert goes in as $env:CHATQ_EVENT/TITLE/TEXT/PRIORITY/JOB/PRESENT and the
    # command runs as -EncodedCommand, so no chat title ever lands on a command
    # line where cmd's %VAR% expansion or a stray & could make it code.
    # -Link: the reply link, as CHATQ_LINK - '' when there is none, and only
    # ever given with commandLinks on (Test-ChatqCommandLinks). Capped at 30
    # s; -Quick, a push a run waits on, at 8. $null when it ran cleanly, else
    # what went wrong.
    param($Cfg, [string]$Event, [string]$Title, [string]$Text, [int]$Priority, [bool]$Present, [string]$Link, [switch]$Quick)
    if (-not ($Cfg.PSObject.Properties['command'] -and $Cfg.command)) { return $null }
    $exe = (Get-Process -Id $PID).Path
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([string]$Cfg.command))
    $env2 = @{
        CHATQ_EVENT = $Event; CHATQ_TITLE = $Title; CHATQ_TEXT = $Text; CHATQ_PRIORITY = "$Priority"
        CHATQ_JOB = [string]$script:ChatqAlertJob; CHATQ_PRESENT = $(if ($Present) { '1' } else { '0' })
        CHATQ_LINK = $Link
    }
    # quiet hours hold the phone's alerts, not your command: it is told, and
    # a Pushover or Telegram command can hold itself
    $env2['CHATQ_QUIET'] = $(if (Test-ChatqQuietIn $Cfg) { '1' } else { '0' })
    $limit = if ($script:ChatqHookTimeoutSec) { $script:ChatqHookTimeoutSec } else { 30 }
    if ($Quick -and $limit -gt 8) { $limit = 8 }
    try {
        $p = Invoke-ChatqProcess -Exe $exe -ArgList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) `
            -StdIn '' -SetEnv $env2 -TimeoutSec $limit
        if ($p.Stopped) { return "command: stopped after $limit s" }
        if ($p.ExitCode) { return "command: exit $($p.ExitCode)" }
        return $null
    }
    catch { return "command: $($_.Exception.Message)" }
}

function Show-ChatqToast {
    # A desktop notification. Windows PowerShell 5.1 reaches WinRT in-process;
    # pwsh 7 dropped the WinRT projection, so from there the same few lines run
    # in powershell.exe, which every Windows has. It shows under Windows
    # PowerShell's own registered app id - a toast from an unregistered id is
    # silently dropped.
    param([string]$Title, [string]$Text)
    if ($script:ChatqToastSeam) { & $script:ChatqToastSeam $Title $Text; return }   # tests
    $t = [string]$Text
    if ($t.Length -gt 300) { $t = $t.Substring(0, 299) + $script:ChatqEllipsis }
    if ($script:ChatqIsWindows) {
        $x = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
        $xml = "<toast><visual><binding template=`"ToastGeneric`"><text>$(& $x $Title)</text><text>$(& $x $t)</text></binding></visual></toast>"
        $code = @'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$d = New-Object Windows.Data.Xml.Dom.XmlDocument
$d.LoadXml($xml)
$n = New-Object Windows.UI.Notifications.ToastNotification $d
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($n)
'@
        if ($PSVersionTable.PSEdition -ne 'Core') { & ([scriptblock]::Create($code)); return }
        # the curly quotes too: PowerShell ends a '...' string on any of the
        # four, and a reply's excerpt is full of them
        $full = "`$xml = '" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($xml) + "'`n" + $code
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($full))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) | Out-Null
        return
    }
    if ($script:ChatIsMac) {
        $q = { param($s) ([string]$s).Replace('\', '\\').Replace('"', '\"') }
        & osascript -e "display notification `"$(& $q $t)`" with title `"$(& $q $Title)`"" 2>$null
        return
    }
    if (Get-Command notify-send -EA SilentlyContinue) { & notify-send $Title $t 2>$null }
}

function Get-ChatqIdleSeconds {
    # Seconds since the last keyboard or mouse input in this login session, or
    # $null when that cannot be told. GetLastInputInfo answers for the whole
    # session, so the hidden watcher asks it as well as any shell could.
    if ($null -ne $script:ChatqIdleSeam) { return $script:ChatqIdleSeam }   # tests
    try {
        if ($script:ChatqIsWindows) {
            if (-not ('ChatqIdle' -as [type])) {
                # the subtraction in C#, unsigned: 5.1's [Environment]::TickCount
                # is a signed int that goes negative after 24.9 days of uptime
                Invoke-ChatCompile { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ChatqIdle {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double Seconds() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) { return -1; }
        return unchecked((uint)Environment.TickCount - li.dwTime) / 1000.0;
    }
}
'@
                }
            }
            $s = [ChatqIdle]::Seconds()
            if ($s -ge 0) { return $s }
            return $null
        }
        if ($script:ChatIsMac) {
            $l = @(& ioreg -c IOHIDSystem 2>$null) | Where-Object { $_ -match 'HIDIdleTime' } | Select-Object -First 1
            if ($l -and $l -match '=\s*(\d+)') { return [double]$Matches[1] / 1e9 }
        }
    }
    catch {}
    return $null
}

function Test-ChatqUserPresent {
    # at the PC now? config quietMinutes (default 5); 0 turns the check off
    param($Cfg)
    if (Test-ChatqPhoneWhilePresent $Cfg) { return $false }
    $m = Get-ChatqQuietMinutes $Cfg
    if ($m -le 0) { return $false }
    $s = Get-ChatqIdleSeconds
    return ($null -ne $s -and $s -lt $m * 60)
}

function Test-ChatqPhoneWhilePresent {
    # config phoneWhilePresent: the phone is sent to at the PC too - being at
    # the PC is not watching the job. Phone gates only: Test-ChatqUserAway,
    # which lets a window reload, ignores it
    param($Cfg)
    return [bool]($Cfg -and $Cfg.PSObject.Properties['phoneWhilePresent'] -and $Cfg.phoneWhilePresent)
}

function Test-ChatqPhoneAway {
    # away as far as the phone is concerned (Update-ChatqLiveAlerts,
    # Send-ChatqResetAskAlert): away, or phoneWhilePresent on
    param($Cfg)
    if (Test-ChatqPhoneWhilePresent $Cfg) { return $true }
    return [bool](Test-ChatqUserAway $Cfg)
}

function Get-ChatqQuietMinutes {
    # config quietMinutes, 5 when unset; 0 turns presence off
    param($Cfg)
    if ($Cfg -and $Cfg.PSObject.Properties['quietMinutes']) { return [double]$Cfg.quietMinutes }
    return 5
}

function Test-ChatqUserAway {
    # Nobody at the PC for quietMinutes - known, not assumed. The reverse of
    # present for the phone's sake, except where it counts: an idle clock that
    # cannot be read, or quietMinutes 0, never reads as away, because away is
    # what lets a window reload under someone's hands. Only this PC's own
    # keyboard and mouse count - a chat driven from the phone is caught by the
    # transcripts instead (see Invoke-ChatqJob).
    param($Cfg)
    $m = Get-ChatqQuietMinutes $Cfg
    if ($m -le 0) { return $false }
    $s = Get-ChatqIdleSeconds
    return ($null -ne $s -and $s -ge $m * 60)
}

#endregion

#region status: the list and the board ----------------------------------------

function Get-ChatqState {
    $s = Read-ChatqJson $script:ChatqStatePath
    if (-not $s) { $s = [pscustomobject]@{} }
    return $s
}

function Test-ChatqLockHeld {
    # The watcher and the overlay each hold a lock file open with no sharing
    # for their whole life, and the OS lets go of it even when the process dies
    # hard - so being able to open it means nobody holds it. A pid file alone
    # would lie after a crash, and pids get reused.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()
        return $false
    }
    catch { return $true }
}

function Test-ChatqWatcherAlive {
    return (Test-ChatqLockHeld $script:ChatqLockPath)
}

function Get-ChatqBlocks {
    # When each lane is free again, keyed like the watcher keys it: its own
    # view while it runs - limits and overloads both - a fresh scan otherwise.
    # A watcher only listening for phone replies runs nothing and so learns
    # nothing about limits: its saved view would be hours stale, so that is
    # scanned too.
    param([switch]$Scan)
    $out = @{}
    $s = Get-ChatqState
    if (-not $Scan -and -not $s.listening -and (Test-ChatqWatcherAlive)) {
        if ($s.blocked) {
            foreach ($p in $s.blocked.PSObject.Properties) {
                $u = ConvertTo-ChatqDate $p.Value.until
                if ($u -and $u -gt (Get-Date)) { $out[$p.Name] = [pscustomobject]@{ Until = $u; Type = $p.Value.type; Source = $p.Value.source } }
            }
        }
        if ($s.outage) {
            foreach ($p in $s.outage.PSObject.Properties) {
                # a Codex lane's outage waits on no page, only on its backoff
                $src = if ($p.Name -like 'codex*') { 'backoff' } else { 'status.claude.com' }
                $out[$p.Name] = [pscustomobject]@{
                    Until = ConvertTo-ChatqDate $p.Value.next; Type = 'overloaded'; Status = $p.Value.status
                    Since = ConvertTo-ChatqDate $p.Value.since; Source = $src
                }
            }
        }
        return $out
    }
    $lanes = @{ claude = $null; codex = $null }
    foreach ($j in @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' -and $_.home })) { $lanes[(Get-ChatqLane $j)] = $j.home }
    foreach ($lane in @($lanes.Keys)) {
        $b = if ($lane -like 'codex*') { Get-ChatqCodexBlock $lanes[$lane] } else { Get-ChatqClaudeBlock $lanes[$lane] }
        if ($b) { $out[$lane] = $b }
    }
    return $out
}

function Format-ChatqDeferWhy {
    # What a job put off waits for, where its next look's time says too
    # little (Set-ChatqJobDeferred): a background command its chat's own
    # process started - an agent, a workflow or a shell - since when; or you
    # leaving the chat's tab, which the handover found in use. $null for the
    # rest - busy, auto-continue's vscode hold - whose next look's time says
    # it. The one maker of these words: the lists and the job's history read
    # them here (Get-ChatqEta), the overlay's rows, the console and the
    # phone through Format-ChatOverlayDeferral. Pure.
    param($Job, [datetime]$Now = (Get-Date))
    switch ([string](Get-ChatField $Job 'deferWhy')) {
        'background' {
            $s = ConvertTo-ChatqDate (Get-ChatField $Job 'deferSince')
            if (-not $s) { return 'waits for a background command' }
            return "waits for a background command (since $(Format-ChatOverlayWhen $s $Now))"
        }
        'in-use' { return 'waits for you to leave its tab' }
    }
    return $null
}

function Get-ChatqEta {
    # "sends" per queued job, the way the watcher picks: a job with a wait of
    # its own sends when that wait ends; one free now waits only behind the
    # run in progress and the free jobs queued before it - never behind a job
    # that is itself waiting, which the watcher skips. The watcher runs one
    # job at a time, so of the jobs whose waits end in the same minute - the
    # chats one limit cut off, all free at its reset - only the first sends
    # then, and each of the rest after the one before it
    param([object[]]$Jobs, [hashtable]$Blocks)
    $eta = @{}
    $now = Get-Date
    $running = @($Jobs | Where-Object { $_.state -eq 'running' }) | Select-Object -First 1
    $ahead = $running
    $tied = @{}
    foreach ($j in @($Jobs | Where-Object { $_.state -in 'queued', 'running' })) {
        if ($j.state -eq 'running') { $eta[$j.id] = 'running'; continue }
        $lane = Get-ChatqLane $j
        $b = $Blocks[$lane]
        $times = @()
        $why = $null
        if ($b -and $b.Type -eq 'overloaded') { $why = 'overloaded' }
        elseif ($b -and $b.Until) { $times += $b.Until.AddMinutes(1) }
        $nb = ConvertTo-ChatqDate $j.notBefore
        if ($nb) { $times += $nb }
        $du = ConvertTo-ChatqDate $j.deferUntil
        # auto-continue's hold for a chat open in a VS Code panel is no busy
        # chat, nor is a background command or a tab someone is in
        # (Format-ChatqDeferWhy), whose words stand in for the next look's time
        $words = $null
        if ($du -and $du -gt $now) {
            $times += $du
            $words = Format-ChatqDeferWhy $j $now
            if (-not $why) { $why = if ((Get-ChatField $j 'deferWhy') -eq 'vscode') { 'open in VS Code' } elseif ($words) { $words } else { 'chat busy' } }
        }
        $ra = ConvertTo-ChatqDate $j.retryAt
        if ($ra -and $ra -gt $now) { $times += $ra; if (-not $why) { $why = 'retry' } }
        $at = $times | Where-Object { $_ -gt $now } | Sort-Object -Descending | Select-Object -First 1
        $eta[$j.id] = if ($why -eq 'overloaded') { "when $(Format-ChatqProvider $lane) is back" }
        elseif ($words -and $why -eq $words -and $at -eq $du) { $words }
        elseif ($at) {
            $s = Format-ChatqClockTime $at $now
            $before = $tied[$s]
            $tied[$s] = $j
            if ($before) { $s = "after #$($before.seq)" }
            if ($why) { "$s ($why)" } else { $s }
        }
        elseif ($ahead) { "after #$($ahead.seq)" }
        else { 'next' }
        if (-not $at -and -not $why) { $ahead = $j }
    }
    return $eta
}

function Get-ChatqPromptStats {
    param([string]$Text)
    $first = @($Text -split '\r?\n' | Where-Object { $_.Trim() })[0]
    $lines = @($Text -split '\r?\n').Count
    [pscustomobject]@{ First = if ($first) { $first.Trim() } else { '' }; Chars = $Text.Length; Lines = $lines }
}

function Get-ChatqWidth {
    $w = 0
    try { $w = $Host.UI.RawUI.WindowSize.Width } catch {}
    if (-not $w -or $w -lt 40) { $w = 100 }
    return $w
}

function Get-ChatqStatusLine {
    param([object[]]$Jobs, [hashtable]$Blocks)
    $q = @($Jobs | Where-Object { $_.state -eq 'queued' }).Count
    $parts = @("$q queued")
    $run = @($Jobs | Where-Object { $_.state -eq 'running' })
    if ($run) { $parts += "running #$($run[0].seq)" }
    foreach ($lane in @($Blocks.Keys | Sort-Object)) {
        $b = $Blocks[$lane]
        $name = Format-ChatqLane $lane
        if ($b.Type -eq 'overloaded') {
            $st = if ($b.Status) { ", status.claude.com: $($b.Status -replace '_', ' ')" } else { '' }
            $since = if ($b.Since) { " since $($b.Since.ToString('HH:mm'))" } else { '' }
            $parts += "$name overloaded$since$st - retrying"
            continue
        }
        if (-not $b.Until) { continue }
        if ($b.Type -eq 'login needed') {
            # what the CLI said; a watcher from before it was kept says 'probe'
            $said = if ($b.Source -and $b.Source -ne 'probe') { $b.Source } else { 'login refused' }
            $parts += "$name $said - log in or check the subscription, chatq looks again every 15 min"
            continue
        }
        $parts += "$name limited until $(Format-ChatqClockTime $b.Until) ($($b.Type))"
    }
    $parts += if (Test-ChatqWatcherAlive) { 'watcher running' } else { 'watcher stopped' }
    return 'chatq ' + $script:ChatqDot + ' ' + ($parts -join " $($script:ChatqDot) ")
}

function Get-ChatqUsage {
    # How much of each window is used. Claude's comes from the utilisation it
    # caches in .claude.json, Codex's from the newest rollout's rate_limits -
    # each replaced by the overlay's live answer where that is newer - and
    # all only as fresh as their last fetch, so each says when that was. For
    # chatqlist alone: the board is rewritten on every watcher pass, and
    # re-reading the file each time is not worth a number nobody looks at there.
    # Codex's is -CodexHome's: by default the home chatq lists Codex chats
    # from, the overlay's too - not $env:CODEX_HOME as it reads now, which a
    # shell can point at another account after chatq loaded.
    param([string]$CodexHome = $script:ChatCodexHome)
    $out = [System.Collections.Generic.List[object]]::new()
    $label = { param($d) if ($d.Date -eq (Get-Date).Date) { $d.ToString('HH:mm') } else { $d.ToString('ddd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } }
    try {
        $path = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $HOME '.claude.json' }
        $u = Read-ChatqCachedUtilization $path
        if ($u) {
            $parts = @(foreach ($l in @($u.utilization.limits)) {
                    if (-not $l) { continue }
                    $p = [int][Math]::Round([double]$l.percent)
                    # reset since the fetch: empty, as the overlay has it
                    $rs = if ($l.resets_at) { ConvertTo-ChatqResetDate $l.resets_at } else { $null }
                    if ($rs -and $rs -le (Get-Date)) { $p = 0 }
                    $scoped = $l.PSObject.Properties['scope'] -and $l.scope
                    switch ([string]$l.kind) {
                        'session' { "5h $p%" }
                        'five_hour' { "5h $p%" }
                        { $_ -in 'weekly_all', 'seven_day', 'weekly' } { "week $p%" }
                        default {
                            # one model's weekly limit - worth a word only once used
                            if ($scoped -and $p -gt 0) {
                                $name = if ($l.scope.model.display_name) { $l.scope.model.display_name } else { 'model' }
                                "$name week $p%"
                            }
                        }
                    }
                })
            if ($parts) {
                $at = [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$u.fetchedAtMs).LocalDateTime
                $out.Add([pscustomobject]@{ Provider = 'Claude'; Parts = $parts; AsOf = & $label $at; AsOfAt = $at })
            }
        }
    }
    catch {}
    # That cache moves only when Claude Code itself asks. The overlay asks
    # the usage endpoint every few minutes and keeps the answer in its
    # snapshot, so the newer of the two is shown: the phone's status once
    # read the cache 35 minutes old, 37% of the 5 h window where the overlay
    # already had 62%.
    try {
        $s = Read-ChatqJson $script:ChatOverlayPath
        $h = if ($s -and $s.PSObject.Properties['header']) { $s.header } else { $null }
        $lu = if ($h -and $h.PSObject.Properties['usage']) {
            @($h.usage | Where-Object { $_ -and $_.provider -eq 'Claude' -and $_.source -eq 'live' -and $_.at })[0]
        }
        $parts = if ($lu -and $lu.PSObject.Properties['windows']) {
            @($lu.windows | Where-Object { $_ -and $_.label } | ForEach-Object { "$($_.label) $([int][Math]::Round([double]$_.percent))%" })
        }
        if ($parts) {
            $at = [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$lu.at).LocalDateTime
            $live = [pscustomobject]@{ Provider = 'Claude'; Parts = $parts; AsOf = & $label $at; AsOfAt = $at }
            $old = @($out | Where-Object { $_.Provider -eq 'Claude' })[0]
            if (-not $old) { $out.Insert(0, $live) }
            elseif ($at -gt $old.AsOfAt) { $out[$out.IndexOf($old)] = $live }
        }
    }
    catch {}
    try {
        # the newest snapshot, read as the overlay and the limit check read it
        $cs = Find-ChatqCodexLimitSnapshot -HomeDir (Get-ChatqHomeDir 'codex' $CodexHome)
        if ($cs) {
            $parts = @(foreach ($w in @($cs.Limits)) {
                    # a window whose reset passed is empty, as the overlay
                    # reads it (ConvertTo-ChatOverlayUsage): the last
                    # rollout can be days old, and its 3% long gone
                    if ($w.ResetsAt -and $w.ResetsAt -le (Get-Date)) { "$($w.Label) 0%"; continue }
                    $p = "$($w.Label) $([int][Math]::Round($w.Percent))%"
                    if ($w.Percent -ge 100 -and $w.ResetsAt) { $p += ", resets $(& $label $w.ResetsAt)" }
                    $p
                })
            $at = $cs.At
            if ($parts) { $out.Add([pscustomobject]@{ Provider = 'Codex'; Parts = $parts; AsOf = if ($at) { & $label $at } else { $null }; AsOfAt = $at }) }
        }
    }
    catch {}
    # The overlay asks codex app-server for the account's figure every few
    # minutes (Update-ChatOverlayUsage); the rollout moves only when a turn
    # runs. The newer wins, as with Claude's - but only when the overlay
    # asked under this home: it is a process of its own, with the
    # CODEX_HOME of the shell that started it, and another account's figure
    # under this one's name would be a wrong number, not an old one. The
    # figure names its home; one that names none is never taken.
    try {
        $mine = [string](Get-ChatqHomeDir 'codex' $CodexHome)
        $s = Read-ChatqJson $script:ChatOverlayPath
        $h = if ($s -and $s.PSObject.Properties['header']) { $s.header } else { $null }
        $lu = if ($h -and $h.PSObject.Properties['usage']) {
            @($h.usage | Where-Object { $_ -and $_.provider -eq 'Codex' -and $_.source -eq 'live' -and $_.at })[0]
        }
        $theirs = if ($lu) { [string](Get-ChatField $lu 'home') } else { '' }
        if ($mine -and $theirs -and (Get-ChatqFolderKey $mine) -eq (Get-ChatqFolderKey $theirs)) {
            $parts = if ($lu -and $lu.PSObject.Properties['windows']) {
                @(foreach ($w in @($lu.windows)) {
                        if (-not $w -or -not $w.label) { continue }
                        $rs = if ($w.PSObject.Properties['resetsAt'] -and $w.resetsAt) { [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$w.resetsAt).LocalDateTime } else { $null }
                        if ($rs -and $rs -le (Get-Date)) { "$($w.label) 0%"; continue }
                        $p = "$($w.label) $([int][Math]::Round([double]$w.percent))%"
                        if ([double]$w.percent -ge 100 -and $rs) { $p += ", resets $(& $label $rs)" }
                        $p
                    })
            }
            if ($parts) {
                $at = [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$lu.at).LocalDateTime
                $live = [pscustomobject]@{ Provider = 'Codex'; Parts = $parts; AsOf = & $label $at; AsOfAt = $at }
                $old = @($out | Where-Object { $_.Provider -eq 'Codex' })[0]
                if (-not $old) { $out.Add($live) }
                elseif (-not $old.AsOfAt -or $at -gt $old.AsOfAt) { $out[$out.IndexOf($old)] = $live }
            }
        }
    }
    catch {}
    return $out.ToArray()
}

function Get-ChatqAlertFooter {
    # The phone alert's last line: how much of each usage window is used
    # (Get-ChatqUsage) and how many chats are at work - "Claude 5h 42%,
    # week 18% $ChatqDot 3 working, 1 waiting". A provider at 0% everywhere is not
    # in use and left out.
    # Chats are counted as the overlay counts them (Get-ChatqChatCounts), so
    # the push and the panel agree. A part that cannot be read is left out;
    # $null when neither can. Never throws.
    if ($script:ChatqFooterSeam) { return (& $script:ChatqFooterSeam) }   # tests
    $d = " $($script:ChatqDot) "
    $parts = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($u in @(Get-ChatqUsage)) {
            # a provider not in use - every window at 0% - is left out, so
            # only what you run shows, Claude or Codex alike
            if (-not @(@($u.Parts) | Where-Object { $_ -notmatch ' 0%$' })) { continue }
            $parts.Add("$($u.Provider) $(@($u.Parts) -join ', ')")
        }
    }
    catch {}
    try {
        $c = Get-ChatqChatCounts
        if ($c) {
            $w = [int]$c.busy
            $n = [int]$c.waiting
            $parts.Add($(if ($n) { "$w working, $n waiting" } else { "$w working" }))
        }
    }
    catch {}
    if (-not $parts.Count) { return $null }
    return ($parts -join $d)
}

function Get-ChatqChatCounts {
    # How many open chats are working and waiting, as the overlay's header
    # has them: its snapshot's counts while it keeps data/overlay.json fresh
    # (within 2 minutes, as the phone board reads it), else the same rows
    # built from the registry and each chat's background work. Not Claude's registry status
    # alone: a chat idle to Claude with a workflow, background agent or
    # background shell still at work is working to the overlay - the push
    # once said 1 working where the panel showed 3. @{ busy; waiting }, or
    # $null when neither can be read.
    param([datetime]$Now = (Get-Date))
    try {
        $s = Read-ChatqJson $script:ChatOverlayPath
        $at = if ($s -and [int](Get-ChatField $s 'schema') -eq 1 -and (Get-ChatField $s 'at')) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.at).LocalDateTime } else { $null }
        $c = if ($s) { Get-ChatField $s 'counts' } else { $null }
        if ($at -and $c -and [Math]::Abs(($Now - $at).TotalMinutes) -lt 2) {
            return [pscustomobject]@{ busy = [int](Get-ChatField $c 'busy'); waiting = [int](Get-ChatField $c 'waiting') }
        }
    }
    catch {}
    # Get-ChatqBoardScan's way, less what only the board needs - the cut-off
    # look, the queue, the Recent list - which took it 20 s on a busy machine
    try {
        $ctx = New-ChatOverlayContext
        $entries = @(Read-ChatqSessionRegistry (Join-Path $ctx.ClaudeHome 'sessions') @{})
        $alive = @($entries | Where-Object { $_.SessionId -and (Test-ChatqSessionAlive $_) })
        $live = @($alive | Where-Object { -not $_.Kind -or $_.Kind -eq 'interactive' })
        foreach ($e in $live) { try { Update-ChatOverlayText $ctx $e } catch {} }
        $bg = try { Update-ChatOverlayBackground @{} $live $alive $ctx.Text $null -Whole } catch { @{} }
        $rows = @(Get-ChatOverlayRows -Sessions $live -Texts $ctx.Text -Jobs @() -Now $Now -Unread @{} -Background $bg)
        $chats = @($rows | Where-Object { $_ -and $_.kind -eq 'session' } | ForEach-Object { [string]$_.chat })
        return [pscustomobject]@{ busy = @($chats | Where-Object { $_ -eq 'busy' }).Count; waiting = @($chats | Where-Object { $_ -eq 'waiting' }).Count }
    }
    catch { return $null }
}

function Write-ChatqList {
    param([switch]$All)
    $jobs = @(Get-ChatqJobs)
    # a job waiting on you in a chat you went on in yourself: skipped, as the
    # overlay would, so the list does not call it waiting (Sync-ChatqAnsweredJobs)
    if (@(Sync-ChatqAnsweredJobs $jobs)) { $jobs = @(Get-ChatqJobs) }
    $blocks = Get-ChatqBlocks
    $eta = Get-ChatqEta $jobs $blocks
    $width = Get-ChatqWidth
    Write-Host ''
    Write-Host (' ' + (Get-ChatqStatusLine $jobs $blocks)) -ForegroundColor DarkGray
    # The percentages come from each tool's own cache, which is refreshed only
    # when that tool runs. Two ways it then misleads, both of them here today:
    # a lane limited right now cannot be at 0% of its 5 h window - the reading
    # simply predates the limit - and a reading hours old is not news at all.
    $use = @(Get-ChatqUsage | ForEach-Object {
            $u = $_
            $parts = @($u.Parts)
            # only the window that is actually blocked: a weekly limit says
            # nothing about the 5 h one, and an overload or a logged-out
            # account is not a usage limit at all
            $kinds = @($Blocks.Keys | Where-Object { $_ -like "$($u.Provider.ToLower())|*" -or $_ -eq $u.Provider.ToLower() } |
                    Where-Object { $Blocks[$_].Until } | ForEach-Object { [string]$Blocks[$_].Type })
            if (@($kinds | Where-Object { $_ -in 'five_hour', 'session' }).Count) {
                $parts = @($parts | ForEach-Object { if ($_ -like '5h *') { '5h limited' } else { $_ } })
            }
            if (@($kinds | Where-Object { $_ -in 'seven_day', 'weekly', 'weekly_all' }).Count) {
                $parts = @($parts | ForEach-Object { if ($_ -like 'week *') { 'week limited' } else { $_ } })
            }
            $old = $u.AsOfAt -and ((Get-Date) - $u.AsOfAt).TotalHours -ge 1
            $a = if ($u.AsOf) { " (as of $($u.AsOf)$(if ($old) { ' - stale' }))" } else { '' }
            "$($u.Provider) $($parts -join " $($script:ChatqDot) ")$a"
        })
    if ($use) { Write-Host ('  usage  ' + ($use -join "  $($script:ChatqDot)  ")) -ForegroundColor DarkGray }
    # the chats the limit cut off that nothing is queued for, and what
    # auto-continue does about them (src/auto-continue.ps1)
    $cut = @(Get-ChatqCutOffChats $jobs)
    Write-ChatqAutoLine $jobs $cut

    $open = @($jobs | Where-Object { $_.state -in 'queued', 'running', 'needs-input', 'failed' })
    if ($open) {
        $sendW = 16
        $numW = 4
        $rest = [Math]::Max(30, $width - $numW - $sendW - 6)
        $chatW = [int]($rest * 0.42)
        $promptW = $rest - $chatW
        Write-Host ('  ' + (Format-ChatCell '#' $numW) + (Format-ChatCell 'chat' $chatW) + ' ' +
            (Format-ChatCell 'prompt' $promptW) + ' ' + 'sends') -ForegroundColor DarkGray
        foreach ($j in $open) {
            $text = if ($j.kind -eq 'continue') { if (Get-ChatField $j 'auto') { 'continue (auto)' } else { 'continue' } } else { [string](Read-ChatqPrompt $j) }
            $ps = Get-ChatqPromptStats $text
            $when = ConvertTo-ChatqDate $j.chatWhen
            $age = if ($when) { " ($(Get-ChatAge $when))" } else { '' }
            $state = switch ($j.state) {
                'queued' { $eta[$j.id] }
                'running' {
                    $s = ConvertTo-ChatqDate $j.startedAt
                    $a = if ($s) { Get-ChatAge $s } else { 'now' }
                    if ($a -eq 'now') { 'running' } else { "running $a" }
                }
                'needs-input' { 'needs you' }
                'failed' { 'failed' }
            }
            # a run waiting on the phone to allow a call (src/permit.ps1)
            if ($j.state -eq 'running') { $state += Get-ChatqPermitWaitText $j }
            $color = switch ($j.state) { 'needs-input' { 'Yellow' } 'failed' { 'Red' } 'running' { 'Green' } default { 'Gray' } }
            Write-Host ('  ' + (Format-ChatCell "$($j.seq)" $numW)) -NoNewline
            Write-Host ((Format-ChatCell "$($j.title)$age" $chatW) + ' ') -NoNewline -ForegroundColor Cyan
            Write-Host ((Format-ChatCell $ps.First $promptW) + ' ') -NoNewline
            Write-Host $state -ForegroundColor $color
            $pad = ' ' * (2 + $numW + $chatW + 1)
            $long = $ps.Lines -gt 1 -or (Get-ChatCells $ps.First) -gt $promptW
            $nf = @(Get-ChatqAttachments $j).Count
            if ($long -or $nf) {
                $bits = @()
                if ($long) { $bits += '{0:N0} chars {1} {2} lines' -f $ps.Chars, $script:ChatqDot, $ps.Lines }
                if ($nf) { $bits += "+$nf file$(if ($nf -ne 1) { 's' })" }
                Write-Host ($pad + [char]0x21B3 + ' ' + ($bits -join " $($script:ChatqDot) ")) -ForegroundColor DarkGray
            }
            if ($j.state -in 'needs-input', 'failed' -and $j.result.reason) {
                Write-Host ($pad + (Format-ChatCell ([string]$j.result.reason) $promptW -NoPad)) -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host '  nothing queued' -ForegroundColor DarkGray
    }

    if ($cut) {
        $autoSt = Get-ChatqAutoListStates $cut $jobs
        $names = ($cut | Select-Object -First 4 | ForEach-Object {
                $w = if ($_.Why -eq 'overloaded') { '529' } else { 'limit' }
                "$($_.Title) ($w $(if ($_.At) { $_.At.ToString('HH:mm') })$(Get-ChatqAutoListTag $autoSt[[string]$_.Id]))"
            }) -join ', '
        Write-Host "  cut off, nothing queued:  $names" -ForegroundColor Yellow
        Write-Host "    chatq '<title>' -Continue  queues a continue for one" -ForegroundColor DarkGray
    }

    $since = if ($All) { [datetime]::MinValue } else { (Get-Date).AddHours(-24) }
    $done = @($jobs | Where-Object { $_.state -in 'done', 'skipped' -and (ConvertTo-ChatqDate $_.endedAt) -gt $since })
    foreach ($j in $done) {
        $end = ConvertTo-ChatqDate $j.endedAt
        $mark = if ($j.state -eq 'skipped') { '-' } else { [string][char]0x2713 }
        $x = if ($j.result.excerpt) { " $($script:ChatqDot) `"$($j.result.excerpt)`"" } elseif ($j.result.reason) { " $($script:ChatqDot) $($j.result.reason)" } else { '' }
        $line = "  $mark #$($j.seq) $($j.title)$x"
        Write-Host ((Format-ChatCell $line ($width - 8) -NoPad) + '  ' + $end.ToString('HH:mm')) -ForegroundColor DarkGray
    }
    Write-Host "  chatq <n> opens prompt n $($script:ChatqDot) chatqlist -Board = live board in VS Code $($script:ChatqDot) chatqlog <n> = what a run did" -ForegroundColor DarkGray
    Write-Host ''
}

function Get-ChatqFence {
    # a code fence longer than any backtick run inside the prompt
    param([string]$Text)
    $max = 2
    foreach ($m in [regex]::Matches($Text, '`+')) { if ($m.Length -gt $max) { $max = $m.Length } }
    return ('`' * ($max + 1))
}

function Write-ChatqBoard {
    # data/queue.md - open it once in VS Code with Ctrl+Shift+V and the preview
    # follows every change the watcher writes. Long prompts fold away.
    try {
        $jobs = @(Get-ChatqJobs)
        $blocks = Get-ChatqBlocks
        $eta = Get-ChatqEta $jobs $blocks
        # a pipe as an entity, not \| - text that already holds \| (grep
        # alternation) would otherwise end up \\| and split the cell
        $e = { param($s) ([string]$s -replace '\|', '&#124;' -replace '[\r\n]+', ' ') }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# chatq')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((Get-ChatqStatusLine $jobs $blocks) + " $($script:ChatqDot) updated $((Get-Date).ToString('HH:mm:ss'))")
        [void]$sb.AppendLine()
        $open = @($jobs | Where-Object { $_.state -in 'queued', 'running', 'needs-input', 'failed' })
        $recent = @($jobs | Where-Object { $_.state -in 'done', 'skipped' -and (ConvertTo-ChatqDate $_.endedAt) -gt (Get-Date).AddDays(-2) })
        if ($open -or $recent) {
            [void]$sb.AppendLine('| # | chat | state | sends | prompt |')
            [void]$sb.AppendLine('|---|------|-------|-------|--------|')
            foreach ($j in @($open) + @($recent)) {
                $text = if ($j.kind -eq 'continue') { if (Get-ChatField $j 'auto') { 'continue (auto)' } else { 'continue' } } else { [string](Read-ChatqPrompt $j) }
                $ps = Get-ChatqPromptStats $text
                $first = if ($ps.First.Length -gt 60) { $ps.First.Substring(0, 60) + $script:ChatqEllipsis } else { $ps.First }
                $sends = if ($j.state -eq 'queued') { $eta[$j.id] } else { '' }
                if ($j.state -eq 'running') { $sends = (Get-ChatqPermitWaitText $j) -replace "^ $([regex]::Escape($script:ChatqDot)) ", '' }
                [void]$sb.AppendLine("| $($j.seq) | $(& $e $j.title) | $($j.state) | $(& $e $sends) | $(& $e $first) ($('{0:N0}' -f $ps.Chars) chars) |")
            }
            [void]$sb.AppendLine()
            foreach ($j in @($open) + @($recent)) {
                $text = if ($j.kind -eq 'continue') { $script:ChatqContinueText } else { [string](Read-ChatqPrompt $j) }
                $ps = Get-ChatqPromptStats $text
                $mode = if ($j.mode) { $j.mode } else { $j.modeAtQueue }
                [void]$sb.AppendLine("## #$($j.seq) $($script:ChatqDot) $(& $e $j.title)")
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("$($j.provider) $($script:ChatqDot) $mode $($script:ChatqDot) ``$($j.cwd)`` $($script:ChatqDot) $($j.state) $($script:ChatqDot) picked by $($j.rule)")
                [void]$sb.AppendLine()
                if ($j.result -and ($j.result.reason -or $j.result.excerpt)) {
                    if ($j.result.reason) { [void]$sb.AppendLine("> **$($j.result.kind)** $(& $e $j.result.reason)") }
                    if ($j.result.excerpt) { [void]$sb.AppendLine("> $(& $e $j.result.excerpt)") }
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine("[run log](logs/$($j.id).jsonl)")
                    [void]$sb.AppendLine()
                }
                $f = Get-ChatqFence $text
                $sum = [System.Net.WebUtility]::HtmlEncode($(if ($ps.First.Length -gt 80) { $ps.First.Substring(0, 80) + $script:ChatqEllipsis } else { $ps.First }))
                [void]$sb.AppendLine("<details><summary>$sum $($script:ChatqDot) $('{0:N0}' -f $ps.Chars) chars</summary>")
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("$f" + 'text')
                [void]$sb.AppendLine($text)
                [void]$sb.AppendLine($f)
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('</details>')
                [void]$sb.AppendLine()
            }
        }
        else {
            [void]$sb.AppendLine('_nothing queued_')
        }
        Save-ChatqText $script:ChatqBoardPath $sb.ToString()
    }
    catch {}
}

#endregion
