# tests/sections/attachments.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'attachments'
$env:FAKE_RECORD = $rec
$af = Join-Path $sb 'attach-src'
$null = New-Item -ItemType Directory -Path $af -Force
$png = Join-Path $af 'mock up.png'          # the space comes out of the copy's name
[System.IO.File]::WriteAllBytes($png, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3))
$txt = Join-Path $af 'notes.txt'
[System.IO.File]::WriteAllText($txt, 'the notes', $utf8)
$n0 = @(Get-ChatqJobs).Count
$d0 = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory -EA SilentlyContinue).Count
Lock-Queue { chatq 'Deadline notes' -Prompt 'look' -Attach (Join-Path $af 'nope.png') *> $null }
Check 'a missing file queues nothing' (@(Get-ChatqJobs).Count -eq $n0)
Lock-Queue { chatq 'Deadline notes' -Continue -Attach $txt *> $null }
Check '-Continue with files is refused - it sends "continue" alone' (@(Get-ChatqJobs).Count -eq $n0)
$said = Lock-Queue { chatq 'Deadline notes' -Prompt 'look' -Attach $png, $txt -WhatIf 6>&1 | Out-String -Width 400 }
Check '-WhatIf names the files and copies none' ($said -like '*2 files*' -and @(Get-ChatqJobs).Count -eq $n0 -and
    @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory -EA SilentlyContinue).Count -eq $d0) $said

Lock-Queue { chatq 'Deadline notes' -Prompt 'compare these' -Attach $png, $txt *> $null }
$ja = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'compare these' })[0]
$fa = @(Get-ChatqAttachments $ja)
Check 'the files are copied into the job, in order, the space out of the name' ($fa.Count -eq 2 -and $fa[0].Name -eq 'mock-up.png' -and $fa[1].Name -eq 'notes.txt' -and (Test-Path -LiteralPath $png)) (($fa | ForEach-Object Name) -join ',')
[System.IO.File]::WriteAllText($txt, 'changed later', $utf8)
Check 'a copy, not a link: the original changing later changes nothing' ([System.IO.File]::ReadAllText($fa[1].FullName, $utf8) -eq 'the notes')
$shown = (Write-ChatqList 6>&1 | Out-String -Width 400)
Check 'chatqlist counts a job''s files' ($shown -like '*+2 files*') ''
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $ja.id)
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
$stdin = [System.IO.File]::ReadAllText((Join-Path $rec 'stdin.bin'), $utf8)
Check 'Claude gets every file named under the prompt' ($stdin.StartsWith('compare these') -and
    $stdin -like "*Attached files - read each one:*- $($fa[0].FullName)*- $($fa[1].FullName)*") $stdin
Check 'and the job''s folder allowed with --add-dir' ($argv -like "*--add-dir`n$(Get-ChatqAttachDir $ja)*") ($argv -replace "`n", ' ')

Lock-Queue { chatq 'Codex gitignore thread' -Prompt 'look at this' -Attach $png, $txt *> $null }
$jc = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'look at this' })[0]
$fc = @(Get-ChatqAttachments $jc)
$null = Invoke-ChatqRun $jc 'look at this' $null $null -Files $fc
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
$stdin = [System.IO.File]::ReadAllText((Join-Path $rec 'stdin.bin'), $utf8)
Check 'Codex gets the image with -i, and -- before the thread id' ($argv -like "*-i`n$($fc[0].FullName)`n--`n$cxId`n-*") ($argv -replace "`n", ' ')
Check 'and the rest only named in the prompt, the image only said to be there' ($argv -notlike "*$($fc[1].FullName)*" -and $stdin -like "*- $($fc[1].FullName)*" -and
    $stdin -notlike "*$($fc[0].FullName)*" -and $stdin -like '*(1 image is attached to this message.)*') $stdin

# the same file twice is one copy; a wildcard is expanded; a file locked since
# it was checked stops the job instead of going without
$png2 = Join-Path $af 'second.png'
[System.IO.File]::WriteAllBytes($png2, [byte[]](0x89, 0x50, 0x4E, 0x47, 5))
Lock-Queue { chatq 'Deadline notes' -Prompt 'one file given two times' -Attach $png, $png *> $null }
$jd = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'one file given two times' })[0]
Check 'the same file given twice goes once' (@(Get-ChatqAttachments $jd).Count -eq 1)
Lock-Queue { chatq 'Deadline notes' -Prompt 'all the shots' -Attach (Join-Path $af '*.png') *> $null }
$jw = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'all the shots' })[0]
Check 'a wildcard brings every match' ((@(Get-ChatqAttachments $jw) | ForEach-Object Name) -join ',' -eq 'mock-up.png,second.png') ((@(Get-ChatqAttachments $jw) | ForEach-Object Name) -join ',')
$n2 = @(Get-ChatqJobs).Count
$d2 = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory -EA SilentlyContinue).Count
$held = [System.IO.File]::Open($png2, 'Open', 'ReadWrite', 'None')
try { $said = Lock-Queue { chatq 'Deadline notes' -Prompt 'locked' -Attach $png, $png2 6>&1 | Out-String -Width 400 } } finally { $held.Dispose() }
Check 'a file that cannot be copied queues nothing, and leaves no folder' (@(Get-ChatqJobs).Count -eq $n2 -and
    @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory -EA SilentlyContinue).Count -eq $d2 -and $said -like '*could not be copied*') $said

# chatq <n> -Attach adds to a job still waiting, and only to one
$said = (chatq $jd.seq -Attach $txt 6>&1 | Out-String -Width 400)
Check 'chatq <n> -Attach adds a file to a queued job' (@(Get-ChatqAttachments $jd).Count -eq 2 -and $said -like '*now has 2 files*') $said
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @(); Text = 'words' } }
$said = (chatq $jd.seq -Paste 6>&1 | Out-String -Width 400)
Check 'chatq <n> -Paste with only text says where text goes, and adds nothing' (@(Get-ChatqAttachments $jd).Count -eq 2 -and $said -like '*opens the prompt*') $said
$script:ChatqClipboardSeam = $null
$said = (chatq $ja.seq -Attach $txt 6>&1 | Out-String -Width 400)
Check 'and nothing is added to one already sent' ($said -like '*would go nowhere*' -and @(Get-ChatqAttachments $ja).Count -eq 2) $said

# the clipboard, through a seam - never this machine's own. Closures: a seam
# runs inside chatq, whose own variables would shadow the test's.
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = [byte[]](0x89, 0x50, 0x4E, 0x47, 9, 9); Files = @(); Text = 'a caption that came along' } }
Lock-Queue { chatq 'Deadline notes' -Prompt 'what is wrong here' -Paste *> $null }
$jp = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'what is wrong here' })[0]
$fp = @(Get-ChatqAttachments $jp)
Check '-Paste: a screenshot becomes clip.png, the caption with it left out' ($fp.Count -eq 1 -and $fp[0].Name -eq 'clip.png' -and $fp[0].Length -eq 6) (($fp | ForEach-Object Name) -join ',')
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @($txt, $af); Text = $null } }.GetNewClosure()
Lock-Queue { chatq 'Deadline notes' -Prompt 'files from explorer' -Paste *> $null }
$jf = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'files from explorer' })[0]
Check '-Paste: files copied in Explorer come in, a folder does not' (@(Get-ChatqAttachments $jf).Count -eq 1 -and @(Get-ChatqAttachments $jf)[0].Name -eq 'notes.txt')
$cbText = "a prompt with 'quotes', `"more`" and `$vars"
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @(); Text = $cbText } }.GetNewClosure()
Lock-Queue { chatq 'Deadline notes' -Paste *> $null }
$jt = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq $cbText })[0]
Check '-Paste: text alone is the prompt, quotes and all' ($jt -and -not @(Get-ChatqAttachments $jt).Count)
Lock-Queue { chatq 'Deadline notes' -Prompt 'fix this:' -Paste *> $null }
$jt2 = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -like 'fix this:*' })[0]
Check '-Paste: text goes under a prompt given with it' ($jt2 -and (Read-ChatqPrompt $jt2) -eq "fix this:`n`n$cbText") (Read-ChatqPrompt $jt2)
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @(); Text = '' } }
$n1 = @(Get-ChatqJobs).Count
Lock-Queue { chatq 'Deadline notes' -Prompt 'x' -Paste *> $null }
Check '-Paste with nothing on the clipboard queues nothing' (@(Get-ChatqJobs).Count -eq $n1)
$script:ChatqClipboardSeam = $null

# what VS Code writes when an image is pasted into the prompt tab: the file
# beside the prompt, in data/queue/, and a link to it
$pasted = Join-Path $script:ChatqQueueDir 'image.png'
[System.IO.File]::WriteAllBytes($pasted, [byte[]](0x89, 0x50, 0x4E, 0x47, 7))
Lock-Queue { chatq 'Deadline notes' -Prompt "see ![image](image.png), [the notes](<$txt>) and [a site](https://example.com)" *> $null }
$jl = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -like 'see !*' })[0]
$fl = @(Get-ChatqAttachments $jl)
$pt = Read-ChatqPrompt $jl
Check 'a pasted image moves into the job, and its link follows it' (-not (Test-Path -LiteralPath $pasted) -and ($fl.Name -contains 'image.png') -and $pt -like "*($($jl.id)/image.png)*") $pt
Check 'a link to a file anywhere else is left as it is - the chat opens that one' ($fl.Count -eq 1 -and $pt.Contains("[the notes](<$txt>)") -and $pt.Contains('(https://example.com)')) (($fl | ForEach-Object Name) -join ',')
# nothing outside data/queue is even looked at: chatq's own data, a share
$secret = Join-Path $script:ChatqData 'secret.txt'
[System.IO.File]::WriteAllText($secret, 'private', $utf8)
$p4 = Join-Path $script:ChatqQueueDir 'shot(1).png'
[System.IO.File]::WriteAllBytes($p4, [byte[]](0x89, 0x50, 0x4E, 0x47, 4))
$vs = Join-Path $script:ChatqQueueDir '#99 Some title'
$null = New-Item -ItemType Directory -Path $vs -Force
[System.IO.File]::WriteAllBytes((Join-Path $vs 'image.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 6))
Lock-Queue { chatq 'Deadline notes' -Prompt 'mix [a](../secret.txt) [b](\\chatq-no-such-host\s\x.png) ![c](shot(1).png) ![d](<#99 Some title/image.png>) [e](#top)' *> $null }
$jm2 = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -like 'mix *' })[0]
$fm = @(Get-ChatqAttachments $jm2)
$pm = Read-ChatqPrompt $jm2
Check 'a ../ link to chatq''s own data and a \\share link are not taken' ((Test-Path -LiteralPath $secret) -and $fm.Name -notcontains 'secret.txt' -and $pm -like '*(../secret.txt)*' -and $pm -like '*(\\chatq-no-such-host\s\x.png)*') $pm
Check 'a name with parentheses, and a folder VS Code named after the prompt, are' (($fm.Name -contains 'shot-1-.png') -and ($fm.Name -contains 'image.png') -and -not (Test-Path -LiteralPath $vs) -and $pm -like '*(#top)*') (($fm | ForEach-Object Name) -join ',')
chatqrm $jm2.seq *> $null
Remove-Item -LiteralPath $secret -Force
# the same file linked twice is one copy; a name another one starts with is
# its own file, and each link is rewritten where it stands
$p2 = Join-Path $script:ChatqQueueDir 'shot.png'
$p3 = Join-Path $script:ChatqQueueDir 'shot.png.bak'
[System.IO.File]::WriteAllBytes($p2, [byte[]](0x89, 0x50, 0x4E, 0x47, 2))
[System.IO.File]::WriteAllBytes($p3, [byte[]](0x89, 0x50, 0x4E, 0x47, 3, 3))
Lock-Queue { chatq 'Deadline notes' -Prompt 'twice ![a](shot.png) and ![b](shot.png), then [c](shot.png.bak)' *> $null }
$j2 = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -like 'twice*' })[0]
$f2 = @(Get-ChatqAttachments $j2)
Check 'a file linked twice is one copy, and a look-alike name keeps its own link' ($f2.Count -eq 2 -and
    (Read-ChatqPrompt $j2) -eq "twice ![a]($($j2.id)/shot.png) and ![b]($($j2.id)/shot.png), then [c]($($j2.id)/shot.png.bak)") (Read-ChatqPrompt $j2)
chatqrm $j2.seq *> $null
$dl = Get-ChatqAttachDir $jl
chatqrm $jl.seq *> $null
Check 'chatqrm takes the job''s files with it' (-not (Test-Path -LiteralPath $dl))
foreach ($x in @(Get-ChatqJobs | Where-Object { $_.id -in @($ja.id, $jc.id, $jp.id, $jf.id, $jt.id, $jt2.id, $jd.id, $jw.id) })) { chatqrm $x.seq -Force *> $null }

# chatq -New: a prompt for a chat not made yet, from the shell - its folder
# relative to the shell's own, named or named by its first line, with the
# files, the time and the mode a prompt for any chat takes
$nwSaid = Lock-Queue { chatq -New $newDir 'Docs pass' -Prompt "write the docs`nall of them" -Attach $png -Mode acceptEdits -In 2h -First 6>&1 | Out-String -Width 400 }
$nw = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq 'Docs pass' })[0]
Check 'chatq -New queues a new chat''s job: named, in that folder, with its file, mode, time and place' (
    $nw -and $nw.cwd -eq $newDir -and $nw.rule -eq 'new' -and $nw.sessionId -match '^[0-9a-f-]{36}$' -and (Read-ChatqPrompt $nw) -eq "write the docs`nall of them" -and
    @(Get-ChatqAttachments $nw).Count -eq 1 -and $nw.mode -eq 'acceptEdits' -and $nw.notBefore -and $nw.first) $nwSaid
Check 'and says how to reach the chat once its first run makes it' ($nwSaid -like "*a new chat 'Docs pass'*" -and $nwSaid -like "*chatq $($nw.sessionId.Substring(0, 8)) writes to it*") $nwSaid
Push-Location -LiteralPath $sb
try { Lock-Queue { chatq -New 'work\fresh project' -Prompt "  `nfix the build`nthen the tests" *> $null } } finally { Pop-Location }
$nwRel = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq 'fix the build' })[0]
Check 'a folder relative to the shell''s, and no name: the first line names it' ($nwRel -and $nwRel.cwd -eq $newDir) "$($nwRel.cwd)"
# the editor, through a stand-in that writes the prompt as a tab would
$edKeep = ${function:Invoke-ChatqEditor}
${function:Invoke-ChatqEditor} = { param($Path) [System.IO.File]::AppendAllText($Path, "plan the release`nstep by step", [System.Text.UTF8Encoding]::new($false)) }
try { Lock-Queue { chatq -New $newDir *> $null } } finally { ${function:Invoke-ChatqEditor} = $edKeep }
$nwEd = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq 'plan the release' })[0]
Check 'no -Prompt: the editor, and its first line names the chat and its prompt file' (
    $nwEd -and (Read-ChatqPrompt $nwEd) -eq "plan the release`nstep by step" -and $nwEd.promptFile -eq "#$($nwEd.seq) plan the release.md" -and
    (Test-Path -LiteralPath (Get-ChatqPromptPath $nwEd))) "$($nwEd.title) $($nwEd.promptFile)"
$script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @(); Text = 'from the clipboard' } }
Lock-Queue { chatq -New $newDir -Paste *> $null }
$script:ChatqClipboardSeam = $null
$nwCb = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq 'from the clipboard' })[0]
Check '-Paste: the clipboard''s text is a new chat''s prompt' ($nwCb -and (Read-ChatqPrompt $nwCb) -eq 'from the clipboard')
$nwN = @(Get-ChatqJobs).Count
$nwRefused = foreach ($c in @(
        { chatq -New $newDir -Prompt 'x' -WhatIf }, { chatq -New (Join-Path $sb 'no such folder') -Prompt 'x' }, { chatq -New $newDir -Continue },
        { chatq -New $newDir -Prompt 'x' -Provider codex }, { chatq -New $newDir -Prompt ' ' }, { chatq -New '' -Prompt 'x' })) {
    Lock-Queue { & $c 6>&1 | Out-String -Width 400 }
}
Check '-WhatIf, a folder not there, -Continue, Codex, no prompt and no folder queue nothing, and say why' (
    @(Get-ChatqJobs).Count -eq $nwN -and $nwRefused[0] -like '*-WhatIf: nothing queued*' -and $nwRefused[1] -like '*no such folder*' -and
    $nwRefused[2] -like '*nothing to continue*' -and $nwRefused[3] -like '*a Claude chat*' -and $nwRefused[4] -like '*empty prompt*' -and
    $nwRefused[5] -like "*takes the new chat's folder*") ($nwRefused -join ' / ')
# its first run makes the chat; then chatq finds it by its id's first 8
$env:FAKE_NEW_CHAT = '1'
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $nwRel.id)
Remove-Item env:FAKE_NEW_CHAT
Remove-Item -LiteralPath $script:ChatReloadPath -Force -EA SilentlyContinue
$nwPick = (chatq $nwRel.sessionId.Substring(0, 8) -Prompt 'and the docs' -WhatIf 6>&1 | Out-String -Width 400)
Check 'once run, chatq <its id''s first 8> picks the chat it made' ((Find-ChatqJob $nwRel.id).state -eq 'done' -and $nwPick -like '*fix the build*' -and $nwPick -like '*-WhatIf: nothing queued*') $nwPick
$nwEsc = Format-ChatqNewChatTitle "$([char]27)[31mfix it$([char]7)`nmore"
Check 'a first line with an ESC or BEL pasted in names the chat without them' ($nwEsc -eq '[31mfix it' -and $nwEsc -notmatch '[\x00-\x1f]') $nwEsc
Check 'Tab offers no chat''s title as a new chat''s name, and still does without -New' (
    -not @(& $script:ChatTitleCompleter 'chatq' 'Target' 'Deadline' $null @{ New = '.' }).Count -and
    @(& $script:ChatTitleCompleter 'chatq' 'Target' 'Deadline' $null @{}).Count)
foreach ($x in @(Get-ChatqJobs | Where-Object { $_.id -in @($nw.id, $nwRel.id, $nwEd.id, $nwCb.id) })) { chatqrm $x.seq -Force *> $null }
Remove-Item env:FAKE_RECORD
# An image pasted into a prompt tab that was then cancelled: nothing moves it
# into a job, so the watcher sweeps what no prompt links to once a day old -
# by the newer of its two times. Never what is linked, young, a job's folder
# (even with no .json yet), or the queue's own files; a folder VS Code made
# goes once empty and old itself. A prompt that cannot be read stops it all.
$swQ = $script:ChatqQueueDir
$swOld = (Get-Date).AddDays(-2)
$swAge = { param($p, [switch]$KeepCreated) $i = Get-Item -LiteralPath $p -Force; if (-not $KeepCreated) { $i.CreationTime = $swOld }; $i.LastWriteTime = $swOld }
$swFiles = @{ stray = 'stray.png'; young = 'young.png'; linked = 'linked shot.png'; created = 'created-now.png'; cancel = 'sweep-job.cancel'; tmp = '#992 Sweep.md.tmp'; md = '#991 Old prompt.md' }
foreach ($k in $swFiles.Keys) { [System.IO.File]::WriteAllBytes((Join-Path $swQ $swFiles[$k]), [byte[]](0x89, 0x50, 0x4E, 0x47)) }
$swPrompt = Join-Path $swQ '#990 Sweep test.md'
[System.IO.File]::WriteAllText($swPrompt, 'see ![a](<linked shot.png>) and ![b](vsimg/kept.png)', $utf8)
$swVs = Join-Path $swQ 'vsimg'
$swVsNew = Join-Path $swQ 'vsnew'
$swJob = Join-Path $swQ '20260101-000000-5w5w'
foreach ($d in (Join-Path $swVs 'deep'), $swVsNew, $swJob) { $null = New-Item -ItemType Directory -Path $d -Force }
foreach ($f in (Join-Path $swVs 'kept.png'), (Join-Path $swVs 'deep\gone.png'), (Join-Path $swVsNew 'gone2.png'), (Join-Path $swJob 'attached.png')) { [System.IO.File]::WriteAllBytes($f, [byte[]](1, 2)) }
foreach ($k in 'stray', 'linked', 'cancel', 'tmp', 'md') { & $swAge (Join-Path $swQ $swFiles[$k]) }
& $swAge (Join-Path $swQ $swFiles.created) -KeepCreated
foreach ($p in (Join-Path $swVs 'kept.png'), (Join-Path $swVs 'deep\gone.png'), (Join-Path $swVs 'deep'), $swVs, (Join-Path $swVsNew 'gone2.png'), (Join-Path $swJob 'attached.png'), $swJob) { & $swAge $p }
# a prompt held open by another program: nothing goes
$swHold = [System.IO.File]::Open($swPrompt, 'Open', 'ReadWrite', 'None')
try { $sw0 = @(Clear-ChatqStrayFiles) } finally { $swHold.Dispose() }
$sw0Kept = Test-Path -LiteralPath (Join-Path $swQ $swFiles.stray)
$sw1 = @(Clear-ChatqStrayFiles)
$swGone = (@($sw1 | ForEach-Object { $_.Substring($swQ.Length + 1) } | Sort-Object) -join '|')
$swLeft = (@('stray', 'young', 'linked', 'created', 'cancel', 'tmp', 'md' | Where-Object { Test-Path -LiteralPath (Join-Path $swQ $swFiles[$_]) }) -join ',')
Check 'a prompt that cannot be read: nothing swept' (-not $sw0.Count -and $sw0Kept) "$($sw0 -join '|')"
Check 'the sweep: a day-old file no prompt links to, at the root or in a folder VS Code made, goes - and that folder once empty and old; linked, young, a job''s or the queue''s own stay' (
    $swGone -eq 'stray.png|vsimg\deep|vsimg\deep\gone.png|vsnew\gone2.png' -and $swLeft -eq 'young,linked,created,cancel,tmp,md' -and
    (Test-Path -LiteralPath (Join-Path $swVs 'kept.png')) -and (Test-Path -LiteralPath $swVsNew) -and (Test-Path -LiteralPath (Join-Path $swJob 'attached.png'))) "$swGone / $swLeft"
$sw2 = @(Clear-ChatqStrayFiles -Now (Get-Date).AddDays(3))
Remove-Item -LiteralPath $swPrompt -Force
$sw3 = @(Clear-ChatqStrayFiles -Now (Get-Date).AddDays(3))
Check 'a day on, the young ones go too; a prompt''s link keeps its file until the prompt goes' (
    @($sw2 | Where-Object { $_ -like '*young.png' -or $_ -like '*created-now.png' }).Count -eq 2 -and -not @($sw2 | Where-Object { $_ -like '*linked shot.png' -or $_ -like '*kept.png' }).Count -and
    @($sw3 | Where-Object { $_ -like '*linked shot.png' }).Count -eq 1 -and -not (Test-Path -LiteralPath $swVs) -and (Test-Path -LiteralPath (Join-Path $swJob 'attached.png'))) "$($sw2 -join '|') // $($sw3 -join '|')"
foreach ($p in $swJob, (Join-Path $swQ $swFiles.cancel), (Join-Path $swQ $swFiles.tmp), (Join-Path $swQ $swFiles.md)) { Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue }
