# tests/vectors/overlay-panel.ps1: native/vectors/overlay-panel.json, the
# WPF overlay's rules that the Slint panel ports (native/overlay/src/model.rs
# answer reads it): what a row's chip offers and when it shows, where the
# chip, the card and the bar of buttons go, how a drag of an edge counts
# rows, a marker's and the folded line's words, a row's clock, the hotkey's
# parse and the window an open brings forward. input.kind names the
# function; the answer is what it answers, in the shape model.rs writes it.
# Times are epoch ms, said in UTC. The two functions that draw
# (Add-ChatOverlayNotice, New-ChatOverlayDotLine) are stood in for in the
# Expect block, so what their callers hand them is pinned, not WPF.

function Get-NvOverlayPanelMs([string]$At) {
    return [DateTimeOffset]::Parse($At, $script:NvInv).ToUnixTimeMilliseconds()
}

function ConvertTo-NvOverlayPanelTime($Ms) {
    # an epoch ms as the UTC [datetime] the chip's functions take
    if ($null -eq $Ms) { return $null }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms).UtcDateTime
}

function ConvertFrom-NvOverlayPanelTime($When) {
    if ($null -eq $When) { return $null }
    return [int64]([datetime]$When - [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalMilliseconds
}

function ConvertTo-NvOverlayPanelPair($P) {
    # a chip part's offset in its window, or null
    if ($null -eq $P) { return $null }
    return , @([int]$P[0], [int]$P[1])
}

function Join-NvOverlayPanelFields($Base, $Fields) {
    # $Base's keys, then $Fields' over them, as a new [ordered]
    $o = [ordered]@{}
    foreach ($k in @($Base.Keys)) { $o[$k] = $Base[$k] }
    if ($Fields) { foreach ($k in @($Fields.Keys)) { $o[$k] = $Fields[$k] } }
    return $o
}

function New-NvOverlayPanelCase([string]$Kind, [string]$Label, $Fields) {
    return [ordered]@{ name = "$Kind $Label"; input = (Join-NvOverlayPanelFields ([ordered]@{ kind = $Kind }) $Fields) }
}

Register-NvVector -Name 'overlay-panel' -About "The WPF overlay's panel rules the Slint panel ports (native/overlay/src/model.rs): the chip's actions, target and bookkeeping, where the chip, the card and the bar of buttons go, a drag's rows, the head's markers, the folded line, a row's clock and words, the hotkey's parse, the window an open raises; input.kind names the function, times are epoch ms in UTC" -Cases {
    $now = Get-NvOverlayPanelMs '2026-10-15T03:00:00Z'
    $guid = '0b9c6a7e-1f2d-4c3b-8a9e-5d6f7a8b9c0d'
    $scr = [ordered]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
    $sep = " $([char]0x00B7) "
    $vsc = 'Visual Studio Code'
    # --- words --------------------------------------------------------------
    New-NvOverlayPanelCase 'title' 'empty' ([ordered]@{ text = ''; width = 60 })
    New-NvOverlayPanelCase 'title' 'white space folded' ([ordered]@{ text = "  fix`tthe   build  "; width = 60 })
    New-NvOverlayPanelCase 'title' 'cut at the width' ([ordered]@{ text = 'abcdefghij'; width = 5 })
    New-NvOverlayPanelCase 'title' 'cut, its end trimmed' ([ordered]@{ text = 'abcd efgh'; width = 5 })
    New-NvOverlayPanelCase 'title' 'the width exactly' ([ordered]@{ text = 'abcde'; width = 5 })
    $smile = [string][char]0xD83D + [string][char]0xDE00
    New-NvOverlayPanelCase 'limit' 'short enough' ([ordered]@{ text = 'abc'; max = 5; ellipsis = $false })
    New-NvOverlayPanelCase 'limit' 'cut' ([ordered]@{ text = 'abcdef'; max = 4; ellipsis = $false })
    New-NvOverlayPanelCase 'limit' 'cut with an ellipsis' ([ordered]@{ text = 'abc def'; max = 5; ellipsis = $true })
    New-NvOverlayPanelCase 'limit' 'max 1 with an ellipsis' ([ordered]@{ text = 'abc'; max = 1; ellipsis = $true })
    New-NvOverlayPanelCase 'limit' 'max 0 with an ellipsis' ([ordered]@{ text = 'abc'; max = 0; ellipsis = $true })
    New-NvOverlayPanelCase 'limit' 'never between an emoji''s halves' ([ordered]@{ text = "ab$($smile)cd"; max = 3; ellipsis = $false })
    New-NvOverlayPanelCase 'limit' 'an emoji whole before the ellipsis' ([ordered]@{ text = "ab$($smile)cd"; max = 5; ellipsis = $true })
    New-NvOverlayPanelCase 'autoTitle' 'short enough' ([ordered]@{ text = 'fix the build'; max = 40 })
    New-NvOverlayPanelCase 'autoTitle' 'cut to 40' ([ordered]@{ text = ('x' * 45); max = 40 })
    New-NvOverlayPanelCase 'autoTitle' '40 exactly' ([ordered]@{ text = ('y' * 40); max = 40 })
    # --- the reset ask and a reload's ---------------------------------------
    foreach ($p in @(
            @('the limit, no time', [ordered]@{ count = 2; restart = 0 }),
            @('the limit at a time today', [ordered]@{ count = 2; restart = 0; resetsAt = ($now + 7200000) }),
            @('the limit on another day', [ordered]@{ count = 1; restart = 0; resetsAt = ($now + 172800000) }),
            @('the limit, its time passed', [ordered]@{ count = 1; restart = 0; resetsAt = ($now - 3600000) }),
            @('a reset of 0 says no time', [ordered]@{ count = 1; resetsAt = 0 }),
            @('a restart alone', [ordered]@{ count = 2; restart = 2; cause = 'oom' }),
            @('a restart, no cause', [ordered]@{ count = 1; restart = 1 }),
            @('both, a crash', [ordered]@{ count = 3; restart = 1; cause = 'crash'; resetsAt = ($now + 3600000) }),
            @('counts as strings', [ordered]@{ count = '2'; restart = '1'; cause = 'OOM' }))) {
        New-NvOverlayPanelCase 'askHead' $p[0] ([ordered]@{ ask = $p[1]; now = $now })
    }
    foreach ($p in @(@('one', [ordered]@{ count = 1 }), @('three, one a restart', [ordered]@{ count = 3; restart = 1 }), @('two restarts', [ordered]@{ count = 2; restart = 2 }))) {
        New-NvOverlayPanelCase 'askCount' $p[0] ([ordered]@{ ask = $p[1] })
        New-NvOverlayPanelCase 'askLeave' $p[0] ([ordered]@{ ask = $p[1] })
    }
    New-NvOverlayPanelCase 'reloadText' 'a window and why' ([ordered]@{ reload = [ordered]@{ window = 'proj'; say = 'an extension changed' } })
    New-NvOverlayPanelCase 'reloadText' 'neither' ([ordered]@{ reload = [ordered]@{ pid = 5 } })
    # --- the chip -----------------------------------------------------------
    $open = [ordered]@{ kind = 'session'; provider = 'claude'; sessionId = $guid; cwd = 'C:\work\proj'; status = 'idle'; where = 'vscode'; title = 'fix the build' }
    foreach ($p in @(
            @('a reload ask', [ordered]@{ kind = 'reload'; window = 'proj'; state = 'ask'; pid = 7 }),
            @('a reload that stops a chat', [ordered]@{ kind = 'reload'; state = 'anyway' }),
            @('the limit''s ask', [ordered]@{ kind = 'ask'; count = 2; restart = 0; titles = @('fix the build', 'write the docs') }),
            @('a restart''s ask', [ordered]@{ kind = 'ask'; count = 1; restart = 1; titles = @('fix the build') }),
            @('an ask of both, no titles', [ordered]@{ kind = 'ask'; count = 3; restart = 1; titles = @() }),
            @('an open chat', $open),
            @('a chat at work', (Join-NvOverlayPanelFields $open ([ordered]@{ status = 'busy' }))),
            @('a chat in a terminal', (Join-NvOverlayPanelFields $open ([ordered]@{ where = 'terminal' }))),
            @('a chat whose job runs', (Join-NvOverlayPanelFields $open ([ordered]@{ job = [ordered]@{ state = 'running' } }))),
            @('a job queued, not running', (Join-NvOverlayPanelFields $open ([ordered]@{ job = [ordered]@{ state = 'queued' } }))),
            @('a cut-off armed to continue', (Join-NvOverlayPanelFields $open ([ordered]@{ kind = 'cutoff'; status = 'cutoff'; auto = [ordered]@{ state = 'armed'; long = 'Continues at 13:00' } }))),
            @('a 529 due, no folder', [ordered]@{ kind = 'cutoff'; provider = 'claude'; sessionId = $guid; title = ('z' * 50); auto = [ordered]@{ state = 'due'; cutWhy = 'overloaded' } }),
            @('a cut-off with auto off', (Join-NvOverlayPanelFields $open ([ordered]@{ kind = 'cutoff'; auto = [ordered]@{ state = 'off' } }))),
            @('a 529 ready', [ordered]@{ kind = 'cutoff'; title = 'x'; auto = [ordered]@{ state = 'Ready'; cutWhy = 'overloaded'; long = 'Claude was overloaded' } }),
            @('a continue running', (Join-NvOverlayPanelFields $open ([ordered]@{ kind = 'cutoff'; auto = [ordered]@{ state = 'running' } }))),
            @('a Codex chat', (Join-NvOverlayPanelFields $open ([ordered]@{ provider = 'codex' }))),
            @('an id that is not one', (Join-NvOverlayPanelFields $open ([ordered]@{ sessionId = 'abc' }))),
            @('no row', $null))) {
        New-NvOverlayPanelCase 'chipActions' $p[0] ([ordered]@{ row = $p[1] })
    }
    New-NvOverlayPanelCase 'openable' 'an upper-case id, Claude' ([ordered]@{ row = (Join-NvOverlayPanelFields $open ([ordered]@{ provider = 'Claude'; sessionId = $guid.ToUpperInvariant() })) })
    New-NvOverlayPanelCase 'openable' 'no folder' ([ordered]@{ row = (Join-NvOverlayPanelFields $open ([ordered]@{ cwd = '' })) })
    New-NvOverlayPanelCase 'openable' 'an id in braces' ([ordered]@{ row = (Join-NvOverlayPanelFields $open ([ordered]@{ sessionId = "{$guid}" })) })
    foreach ($p in @(
            @('waiting', [ordered]@{ kind = 'session'; status = 'waiting' }),
            @('a queued prompt''s run', [ordered]@{ kind = 'session'; status = 'idle'; where = 'run' }),
            @('a job', [ordered]@{ kind = 'job'; status = 'busy' }),
            @('idle in VS Code', [ordered]@{ kind = 'Session'; status = 'Idle'; where = 'vscode' }),
            @('busy, any case', [ordered]@{ kind = 'session'; status = 'BUSY' }))) {
        New-NvOverlayPanelCase 'deletable' $p[0] ([ordered]@{ row = $p[1] })
    }
    foreach ($p in @(
            @('the second click', 's:1', ($now - 1000), 's:1'),
            @('4 s on', 's:1', ($now - 4000), 's:1'),
            @('another row', 's:1', ($now - 1000), 's:2'),
            @('never armed', 's:1', $null, 's:1'),
            @('no key armed', '', ($now - 1000), ''),
            @('a key in another case', 'S:1', ($now - 1000), 's:1'))) {
        New-NvOverlayPanelCase 'deleteArmed' $p[0] ([ordered]@{ armedKey = $p[1]; armedAt = $p[2]; key = $p[3]; now = $now })
    }
    foreach ($p in @(@('no chip shown', $null, 5000), @('299 ms on', 1000, 1299), @('300 ms on', 1000, 1300),
            @('stamped before it showed', 1000, 900), @('across the tick''s wrap', 2147483000, -2147483000))) {
        New-NvOverlayPanelCase 'pressCounts' $p[0] ([ordered]@{ shown = $p[1]; press = $p[2] })
    }
    $aim = [ordered]@{ shown = ''; under = ''; rested = 0; onChip = $false; sinceOver = 0; down = $false; blocked = $false; spent = ''; delay = 400 }
    foreach ($p in @(
            @('blocked', [ordered]@{ shown = 's:1'; under = 's:1'; blocked = $true }),
            @('shown, over its row', [ordered]@{ shown = 's:1'; under = 'S:1' }),
            @('shown, over the chip', [ordered]@{ shown = 's:1'; under = 's:2'; onChip = $true }),
            @('shown, over another row', [ordered]@{ shown = 's:1'; under = 's:2' }),
            @('shown, just off', [ordered]@{ shown = 's:1'; sinceOver = 299 }),
            @('shown, 300 ms off', [ordered]@{ shown = 's:1'; sinceOver = 300 }),
            @('rested the delay', [ordered]@{ under = 's:1'; rested = 400 }),
            @('not rested yet', [ordered]@{ under = 's:1'; rested = 399.5 }),
            @('spent on this row', [ordered]@{ under = 's:1'; rested = 900; spent = 's:1' }),
            @('a button held', [ordered]@{ under = 's:1'; rested = 900; down = $true }),
            @('a delay of its own', [ordered]@{ under = 's:1'; rested = 150; delay = 100 }))) {
        New-NvOverlayPanelCase 'chipTarget' $p[0] (Join-NvOverlayPanelFields $aim $p[1])
    }
    $t0 = $now - 500
    $bare = [ordered]@{ under = ''; underAt = $null; lastPos = '1,1'; key = ''; overAt = $null; spent = ''; armed = $false }
    foreach ($p in @(
            @('moved onto a row', [ordered]@{}, 's:1', '2,2', $false),
            @('rows redrawn under a still pointer', [ordered]@{ lastPos = '2,2' }, 's:1', '2,2', $false),
            @('still, then moved', [ordered]@{ under = 's:1'; lastPos = '2,2' }, 's:1', '3,3', $false),
            @('rested on, no move', [ordered]@{ under = 's:1'; underAt = $t0; lastPos = '3,3' }, 's:1', '3,3', $false),
            @('the chip up, over its row', [ordered]@{ under = 's:1'; underAt = $t0; lastPos = '3,3'; key = 's:1'; overAt = $t0 }, 's:1', '3,3', $false),
            @('over the chip', [ordered]@{ under = 's:1'; underAt = $t0; lastPos = '3,3'; key = 's:1'; overAt = $t0 }, '', '9,9', $true),
            @('off its row, spent cleared', [ordered]@{ under = 's:1'; underAt = $t0; lastPos = '3,3'; spent = 's:1' }, 's:2', '4,4', $false),
            @('off the panel', [ordered]@{ under = 's:1'; underAt = $t0; lastPos = '3,3'; key = 's:1'; overAt = $t0; armed = $true }, '', '50,50', $false))) {
        New-NvOverlayPanelCase 'step' $p[0] ([ordered]@{ state = (Join-NvOverlayPanelFields $bare $p[1]); under = $p[2]; pos = $p[3]; onChip = $p[4]; now = $now })
    }
    # --- where the chip, the card and the bar go ----------------------------
    foreach ($p in @(@('on the right of its screen', @(1500, 100, 300, 400)), @('on the left', @(10, 100, 300, 400)), @('a tie goes left', @(810, 0, 300, 100)))) {
        New-NvOverlayPanelCase 'cardLeft' $p[0] ([ordered]@{ panel = $p[1]; screen = $scr })
    }
    $lay = [ordered]@{ row = @(100, 200, 300, 36); line = @(100, 200, 300, 36); icons = @(40, 20); words = @(80, 22); screen = $scr
        name = @(, @(104, 200, 292, 36)); panel = @(100, 50, 300, 600); gap = 4; wordsX = $null
    }
    foreach ($p in @(
            @('a tile, its icons and words on the right', [ordered]@{}),
            @('on the left of the panel', [ordered]@{ row = @(1500, 200, 300, 36); line = @(1500, 200, 300, 36); name = @(, @(1504, 200, 292, 36)); panel = @(1500, 50, 300, 600) }),
            @('no tile: the icons on the row', [ordered]@{ name = @() }),
            @('no words', [ordered]@{ words = @(0, 0) }),
            @('words where a reload says', [ordered]@{ wordsX = 380 }),
            @('words at a place, on the left', [ordered]@{ row = @(1500, 200, 300, 36); line = @(1500, 200, 300, 36); name = @(); panel = @(1500, 50, 300, 600); wordsX = 1540 }),
            @('nothing to show', [ordered]@{ icons = @(0, 0); words = @(0, 0); name = @() }),
            @('held off the screen''s top and left', [ordered]@{ row = @(-30, -8, 300, 24); line = @(-30, -8, 300, 24); name = @(, @(-26, -8, 292, 24)); panel = @(-30, -20, 300, 600) }),
            @('a narrow tile''s icons past the panel', [ordered]@{ row = @(1500, 300, 300, 24); line = @(1500, 300, 300, 24); name = @(, @(1510, 302, 30, 20)); icons = @(60, 20); panel = @(1500, 50, 300, 600) }),
            @('no panel given: the row', [ordered]@{ panel = $null }),
            @('two name parts', [ordered]@{ name = @(@(104, 200, 100, 36), @(210, 202, 50, 30)) }),
            @('a half centres to even', [ordered]@{ icons = @(40, 21); words = @(80, 23) }))) {
        New-NvOverlayPanelCase 'chipLayout' $p[0] (Join-NvOverlayPanelFields $lay $p[1])
    }
    $card = [ordered]@{ panel = @(100, 50, 300, 600); row = @(100, 200, 300, 36); size = @(337, 150); screen = $scr; gap = 5; push = 0; below = $false }
    foreach ($p in @(
            @('right of the panel', [ordered]@{}),
            @('left of the panel, past the chip', [ordered]@{ panel = @(1500, 50, 300, 600); row = @(1500, 200, 300, 36); push = 84 }),
            @('held up off the screen''s foot', [ordered]@{ row = @(100, 1000, 300, 36) }),
            @('held on the screen''s right', [ordered]@{ panel = @(10, 50, 1650, 600); row = @(10, 200, 1650, 36) }),
            @('under a gauge', [ordered]@{ row = @(120, 60, 280, 10); size = @(337, 120); below = $true }),
            @('over a gauge at the foot', [ordered]@{ row = @(120, 950, 280, 10); size = @(337, 120); below = $true }),
            @('under a gauge at the right', [ordered]@{ row = @(1800, 60, 100, 10); size = @(337, 120); below = $true }),
            @('a tip on a half rounds to even', [ordered]@{ row = @(100, 60, 281, 10); size = @(337, 120); below = $true }),
            @('no room either side of a gauge', [ordered]@{ row = @(120, 100, 280, 10); size = @(337, 1000); below = $true }))) {
        New-NvOverlayPanelCase 'cardPlace' $p[0] (Join-NvOverlayPanelFields $card $p[1])
    }
    $short = [ordered]@{ X = 0; Y = 0; Width = 1920; Height = 400 }
    $ctl = [ordered]@{ panel = @(1500, 100, 300, 600); size = @(200, 30); screen = $scr; gap = 4; prefer = 'above'; bar = 22; box = 0; inset = 4; indent = 8 }
    foreach ($p in @(
            @('the box shut', [ordered]@{}),
            @('the box above', [ordered]@{ panel = @(1500, 400, 300, 600); box = 200 }),
            @('no room above: below', [ordered]@{ box = 200 }),
            @('below, as it was', [ordered]@{ panel = @(1500, 400, 300, 600); box = 200; prefer = 'below' }),
            @('below wanted, no room', [ordered]@{ panel = @(1500, 900, 300, 100); box = 300; prefer = 'below' }),
            @('room on neither side: the more', [ordered]@{ panel = @(1500, 150, 300, 200); box = 300; screen = $short }),
            @('room on neither side: above', [ordered]@{ panel = @(1500, 250, 300, 100); box = 300; screen = $short }),
            @('wider than the room to the left', [ordered]@{ panel = @(0, 100, 150, 600); size = @(250, 30) }),
            @('a screen left of the main', [ordered]@{ panel = @(-1700, 300, 300, 600); size = @(260, 30); box = 150; screen = [ordered]@{ X = -1920; Y = 0; Width = 1920; Height = 1040 } }))) {
        New-NvOverlayPanelCase 'controlsPlace' $p[0] (Join-NvOverlayPanelFields $ctl $p[1])
    }
    $show = [ordered]@{ shown = $false; onPanel = $false; onControls = $false; dragging = $false; down = $false; rested = 0; sinceOver = 0 }
    foreach ($p in @(
            @('mid-drag', [ordered]@{ dragging = $true }),
            @('rested on the panel', [ordered]@{ onPanel = $true; rested = 350 }),
            @('not rested yet', [ordered]@{ onPanel = $true; rested = 349 }),
            @('a button held', [ordered]@{ onPanel = $true; rested = 900; down = $true }),
            @('rested on the buttons', [ordered]@{ onControls = $true; rested = 600 }),
            @('up, just left', [ordered]@{ shown = $true; sinceOver = 699 }),
            @('up, 700 ms gone', [ordered]@{ shown = $true; sinceOver = 700 }),
            @('up, a button held off it', [ordered]@{ shown = $true; sinceOver = 5000; down = $true }))) {
        New-NvOverlayPanelCase 'controlsShown' $p[0] (Join-NvOverlayPanelFields $show $p[1])
    }
    # --- a drag of an edge, the height cap, the panel's place ----------------
    $drag = [ordered]@{ rows = 1; dy = 0; rowHeight = 0; scale = 1; collapsed = $false; kept = 0; edge = 's'; open = 30
        recentDrawn = 0; recentPool = 0; recentKept = -1; recentHeight = 0; headHeight = 0
    }
    foreach ($p in @(
            @('the foot down two rows', [ordered]@{ rows = 3; dy = 90; rowHeight = 42; open = 10 }),
            @('the top up two rows', [ordered]@{ rows = 3; dy = -90; rowHeight = 42; open = 10; edge = 'n' }),
            @('the top down takes them', [ordered]@{ rows = 4; dy = 90; rowHeight = 42; open = 10; edge = 'n' }),
            @('within the first row', [ordered]@{ rows = 3; dy = 30; rowHeight = 42; open = 10 }),
            @('no travel keeps the saved', [ordered]@{ rows = 3; dy = 10; rowHeight = 42; kept = 8; open = 3 }),
            @('outward never under the saved', [ordered]@{ rows = 3; dy = 90; rowHeight = 42; kept = 8; open = 4 }),
            @('inward from the saved', [ordered]@{ rows = 3; dy = -50; rowHeight = 42; kept = 8; open = 3 }),
            @('past the open rows into Recent', [ordered]@{ rows = 3; dy = 130; rowHeight = 42; open = 3; recentPool = 5; recentHeight = 20; headHeight = 18 }),
            @('Recent as far as there is', [ordered]@{ rows = 3; dy = 900; rowHeight = 42; open = 3; recentDrawn = 2; recentPool = 4; recentHeight = 20; headHeight = 18 }),
            @('inward takes Recent first', [ordered]@{ rows = 3; dy = -50; rowHeight = 42; open = 5; recentDrawn = 3; recentHeight = 20; headHeight = 18 }),
            @('inward past Recent into rows', [ordered]@{ rows = 4; dy = -150; rowHeight = 42; open = 5; recentDrawn = 2; recentHeight = 20; headHeight = 18 }),
            @('collapsed: nothing', [ordered]@{ rows = 3; dy = 300; rowHeight = 42; collapsed = $true; open = 10 }),
            @('at 1.5 x', [ordered]@{ rows = 2; dy = 130; rowHeight = 63; scale = 1.5 }),
            @('no row height known', [ordered]@{ rows = 2; dy = 110; scale = 1.25 }),
            @('a grow with a fraction', [ordered]@{ rows = 2; dy = 110; rowHeight = 51; scale = 1.25 }),
            @('Recent kept with no line moved', [ordered]@{ rows = 2; dy = 5; rowHeight = 42; open = 2; recentDrawn = 2; recentPool = 6; recentKept = 4 }),
            @('Recent outward never under its saved', [ordered]@{ rows = 2; dy = 25; rowHeight = 42; open = 2; recentDrawn = 2; recentPool = 6; recentKept = 5; recentHeight = 20 }),
            @('no open row to take', [ordered]@{ rows = 8; dy = -100; rowHeight = 42; open = 0 }),
            @('never past 30', [ordered]@{ rows = 29; dy = 900; rowHeight = 42; open = 40 }),
            @('a scale of 0 is 1', [ordered]@{ rows = 2; dy = 84; rowHeight = 42; scale = 0 }))) {
        New-NvOverlayPanelCase 'resize' $p[0] (Join-NvOverlayPanelFields $drag $p[1])
    }
    $area = [ordered]@{ X = 0; Y = 40; Width = 1920; Height = 1000 }
    foreach ($p in @(
            @('down to the foot', 100, 1, 42, $null),
            @('at 1.5 x', 100, 1.5, 42, $null),
            @('never under the floor', 1030, 1, 41.5, $null),
            @('the foot held: up to the top', 100, 1.25, 42, 800),
            @('a scale of 0 is 1', 100, 0, 0, $null))) {
        New-NvOverlayPanelCase 'heightCap' $p[0] ([ordered]@{ top = $p[1]; area = $area; scale = $p[2]; floor = $p[3]; bottom = $p[4] })
    }
    $main = [ordered]@{ X = 0; Y = 0; Width = 1920; Height = 1040; Primary = $true }
    $side = [ordered]@{ X = 1920; Y = 0; Width = 1280; Height = 1000; Primary = $false }
    $west = [ordered]@{ X = -1280; Y = 0; Width = 1280; Height = 1000; Primary = $false }
    foreach ($p in @(
            @('where it was left', 100, 100, @($main)),
            @('off every screen', 3000, 100, @($main)),
            @('a 48 x 24 corner shows', 1872, 1016, @($main)),
            @('47 wide shows not', 1873, 100, @($main)),
            @('on the second screen', 2000, 50, @($main, $side)),
            @('no place kept', $null, $null, @($main, $side)),
            @('the main screen second', $null, $null, @($west, $main)),
            @('no main screen named', 5000, 5000, @($west)),
            @('no screens', 10, 10, @()))) {
        New-NvOverlayPanelCase 'placement' $p[0] ([ordered]@{ x = $p[1]; y = $p[2]; w = 300; h = 200; screens = $p[3] })
    }
    New-NvOverlayPanelCase 'edgesRect' 'six out' ([ordered]@{ panel = @(100, 200, 300, 400); out = 6 })
    New-NvOverlayPanelCase 'edgesRect' 'none out' ([ordered]@{ panel = @(-50, 0, 10, 10); out = 0 })
    # --- an open's window ---------------------------------------------------
    foreach ($c in 0, 10, 15, 16, 20, 21, 25, 26, 30, 40, 41, 42, 43, 50, 1) {
        New-NvOverlayPanelCase 'raisePlan' "code $c" ([ordered]@{ code = $c })
    }
    foreach ($p in @(
            @('a folder', "proj - $vsc", 'proj', @()),
            @('a file in it', "main.rs - proj - $vsc", 'proj', @()),
            @('Insiders', "proj - $vsc - Insiders", 'proj', @()),
            @('run as admin', "proj - $vsc [Administrator]", 'proj', @()),
            @('a profile', "proj - Work - $vsc", 'proj', @('Work')),
            @('a profile not known', "proj - Work - $vsc", 'proj', @()),
            @('a folder of a longer name', "projX - $vsc", 'proj', @()),
            @('any case', 'PROJ - visual studio code', 'proj', @()),
            @('no root', "proj - $vsc", '', @()),
            @('no name of VS Code', 'proj', 'proj', @()),
            @('a dash with no space', "proj-$vsc", 'proj', @()),
            @('a workspace', "Team (Workspace) - $vsc", 'Team (Workspace)', @()))) {
        New-NvOverlayPanelCase 'titleOn' $p[0] ([ordered]@{ title = $p[1]; root = $p[2]; profiles = $p[3] })
    }
    $w1 = [ordered]@{ Handle = 101; Title = "proj - $vsc" }
    $w2 = [ordered]@{ Handle = 202; Title = "other - $vsc" }
    foreach ($p in @(
            @('by its folder', 'C:\work\proj', @($w1, $w2), ''),
            @('a slash at the end', 'C:\work\proj\', @($w2, $w1), ''),
            @('forward slashes', 'D:/a/b/proj', @($w1, $w2), ''),
            @('two on a folder of that name', 'C:\work\proj', @($w1, [ordered]@{ Handle = 303; Title = "main.rs - proj - $vsc" }), ''),
            @('none on it', 'C:\work\gone', @($w1, $w2), ''),
            @('by the name its tab gives', 'C:\work\proj', @($w1, [ordered]@{ Handle = 404; Title = "Team (Workspace) - $vsc" }), 'Team'),
            @('a window with no handle', 'C:\work\proj', @([ordered]@{ Handle = 0; Title = "proj - $vsc" }, [ordered]@{ Handle = 505; Title = "proj - $vsc" }), ''),
            @('no folder', '', @($w1), ''))) {
        New-NvOverlayPanelCase 'selectWindow' $p[0] ([ordered]@{ cwd = $p[1]; windows = $p[2]; profiles = @(); name = $p[3] })
    }
    foreach ($p in @(
            @('none set', ''), @('none said', 'None'), @('the default', 'Ctrl+Alt+Shift+O'), @('Win and a function key', 'Ctrl+Win+F9'),
            @('spaces and any case', ' control + Shift + 5 '), @('F24', 'Alt+F24'), @('F25 is not one', 'Alt+F25'), @('F01 is not one', 'Alt+F01'),
            @('no key', 'Ctrl+Alt'), @('no modifier', 'O'), @('the last key named', 'Ctrl+A+B'), @('an empty part', 'Ctrl++O'),
            @('Windows spelled out', 'windows+shift+z'))) {
        New-NvOverlayPanelCase 'hotkey' $p[0] ([ordered]@{ text = $p[1] })
    }
    # --- a row's clock and words --------------------------------------------
    foreach ($p in @(
            @('idle 5 min', [ordered]@{ status = 'idle'; since = ($now - 300000) }, $false),
            @('at work 12 h', [ordered]@{ status = 'busy'; since = ($now - 43200000) }, $false),
            @('live, under an hour', [ordered]@{ status = 'busy'; since = ($now - 125000) }, $true),
            @('live, past an hour', [ordered]@{ status = 'busy'; since = ($now - 3700000) }, $true),
            @('queued, sends in 90 s', [ordered]@{ status = 'queued'; since = ($now - 5000); sendAt = ($now + 90000) }, $false),
            @('queued, its time passed', [ordered]@{ status = 'queued'; since = ($now - 5000); sendAt = ($now - 1000) }, $false),
            @('cut off, the reset ahead', [ordered]@{ status = 'cutoff'; since = ($now - 600000); resetsAt = ($now + 10800000) }, $false),
            @('cut off, the reset passed', [ordered]@{ status = 'cutoff'; since = ($now - 600000); resetsAt = ($now - 1) }, $false),
            @('a minute and a bit to go', [ordered]@{ status = 'cutoff'; resetsAt = ($now + 60001) }, $false),
            @('101 hours: days', [ordered]@{ status = 'idle'; since = ($now - 363600000) }, $false),
            @('300 days: held at 99', [ordered]@{ status = 'idle'; since = ($now - 25920000000) }, $false),
            @('no since', [ordered]@{ status = 'idle' }, $false),
            @('a since ahead', [ordered]@{ status = 'idle'; since = ($now + 5000) }, $false))) {
        New-NvOverlayPanelCase 'rowClock' $p[0] ([ordered]@{ row = $p[1]; live = $p[2]; now = $now })
    }
    foreach ($p in @(
            @('a Recent line says its age', [ordered]@{ kind = 'recent'; stateText = '5m ago'; stateWords = 'idle' }),
            @('idle alone says nothing', [ordered]@{ kind = 'session'; stateWords = 'idle' }),
            @('needs you, any case', [ordered]@{ kind = 'session'; stateWords = 'Needs You' }),
            @('a plain word after the dot', [ordered]@{ kind = 'session'; stateWords = "resets 13:00$($sep)working" }),
            @('a detail kept', [ordered]@{ kind = 'session'; stateWords = "2nd in the queue$($sep)queued" }),
            @('no words: the state text', [ordered]@{ kind = 'job'; stateText = 'sends 14:00' }),
            @('a dot first', [ordered]@{ kind = 'session'; stateWords = "$($sep)idle" }))) {
        New-NvOverlayPanelCase 'rowWords' $p[0] ([ordered]@{ row = $p[1] })
    }
    foreach ($p in @(
            @('the card says nothing like it', [ordered]@{ kind = 'session'; stateWords = "2nd in the queue$($sep)queued" }, 'WAITING'),
            @('the card says it', [ordered]@{ kind = 'cutoff'; stateWords = 'resets 13:00' }, 'resets 13:00'),
            @('the card says more', [ordered]@{ kind = 'cutoff'; stateWords = '13:00' }, 'resets 13:00'),
            @('a Recent line', [ordered]@{ kind = 'recent'; stateText = '5m ago' }, ''),
            @('nothing to say', [ordered]@{ kind = 'session'; stateWords = 'idle' }, 'IDLE'))) {
        New-NvOverlayPanelCase 'cardWords' $p[0] ([ordered]@{ row = $p[1]; what = $p[2] })
    }
    # --- the markers and the folded line ------------------------------------
    $notes = @(
        [ordered]@{ kind = 'memory'; tone = 'warn'; text = 'memory: 90% used' },
        [ordered]@{ kind = 'leak'; tone = 'warn'; text = 'Code.exe grows' },
        [ordered]@{ kind = 'leak'; tone = 'error'; text = 'node.exe grows' },
        [ordered]@{ kind = 'ask'; tone = 'cutoff'; text = 'the ask' },
        [ordered]@{ kind = 'reload'; tone = 'dim'; text = 'a reload' },
        [ordered]@{ kind = 'usage'; tone = 'warn'; text = 'usage: Codex is not answering' },
        [ordered]@{ kind = 'watcher'; tone = 'error'; text = 'the watcher stopped - see its log' },
        [ordered]@{ kind = 'next'; tone = 'dim'; text = 'next queued prompt: 14:00' },
        [ordered]@{ kind = 'error'; tone = 'error'; text = 'the collector failed' },
        [ordered]@{ kind = 'note'; tone = 'dim'; text = 'something to say' },
        [ordered]@{ kind = 'note'; tone = 'warn'; text = 'Something else' })
    $ask = [ordered]@{ count = 2; resetsAt = ($now - 1800000); restart = 0; keys = @('s:1', 's:2'); titles = @('fix the build', 'write the docs')
        left = @('a chat - open in a terminal; its own claude continues it')
    }
    New-NvOverlayPanelCase 'headNotices' 'every kind of note, then the ask' ([ordered]@{ snap = [ordered]@{ header = [ordered]@{ notes = $notes; ask = $ask } }; now = $now })
    New-NvOverlayPanelCase 'headNotices' 'no notes, no ask' ([ordered]@{ snap = [ordered]@{ header = [ordered]@{ notes = @() } }; now = $now })
    New-NvOverlayPanelCase 'headNotices' 'one note, not in a list' ([ordered]@{ snap = [ordered]@{ header = [ordered]@{ notes = [ordered]@{ kind = 'leak'; tone = 'warn'; text = 'x grows' } } }; now = $now })
    New-NvOverlayPanelCase 'headNotices' 'an ask of restarts, no keys' ([ordered]@{ snap = [ordered]@{ header = [ordered]@{ ask = [ordered]@{ count = 1; restart = 1; cause = 'crash'; titles = @('fix the build') } } }; now = $now })
    New-NvOverlayPanelCase 'reloadNotice' 'with the notice''s words' ([ordered]@{ reload = [ordered]@{ pid = 4321; window = 'proj'; id = 'r1'; state = 'ask'; say = 'an extension changed'; text = 'fix the build is working there'; count = 1 } })
    New-NvOverlayPanelCase 'reloadNotice' 'bare' ([ordered]@{ reload = [ordered]@{ pid = 99 } })
    foreach ($p in @(@('busy', 'dim'), @('late', 'warn'), @('nostart', 'warn'), @('delete', 'dim'), @('delete', 'warn'), @('reload', 'dim'), @('done', 'dim'), @('done', 'warn'), @('Busy', 'WARN'))) {
        New-NvOverlayPanelCase 'sayWord' "$($p[0]) $($p[1])" ([ordered]@{ say = $p[0]; tone = $p[1] })
    }
    $counts = [ordered]@{ waiting = 1; busy = 2; idle = 3; running = 1; queued = 4; needsInput = 1; cutOff = 3; unread = 2; auto = 1 }
    $zero = [ordered]@{ waiting = 0; busy = 0; idle = 0; running = 0; queued = 0; needsInput = 0; cutOff = 0; unread = 0 }
    New-NvOverlayPanelCase 'compact' 'every count' ([ordered]@{ snap = [ordered]@{ counts = $counts; header = [ordered]@{ ask = [ordered]@{ count = 1 }; reload = @([ordered]@{ pid = 1 }) } } })
    New-NvOverlayPanelCase 'compact' 'nothing open' ([ordered]@{ snap = [ordered]@{ counts = $zero; header = [ordered]@{} } })
    New-NvOverlayPanelCase 'compact' 'cut off, all can continue' ([ordered]@{ snap = [ordered]@{ counts = [ordered]@{ cutOff = 2; idle = 1 }; header = [ordered]@{ ask = [ordered]@{ count = 2 } } } })
    New-NvOverlayPanelCase 'compact' 'cut off, some auto' ([ordered]@{ snap = [ordered]@{ counts = [ordered]@{ cutOff = 3; auto = 2; busy = 1 }; header = [ordered]@{ reload = @([ordered]@{ pid = 1 }, [ordered]@{ pid = 2 }) } } })
    New-NvOverlayPanelCase 'compact' 'running alone' ([ordered]@{ snap = [ordered]@{ counts = [ordered]@{ running = 2 }; header = [ordered]@{} } })
    New-NvOverlayPanelCase 'compact' 'no counts' ([ordered]@{ snap = [ordered]@{ header = [ordered]@{} } })
    $usage = @([ordered]@{ provider = 'Claude'; windows = @() }, [ordered]@{ provider = 'codex'; windows = @() }, [ordered]@{ provider = 'Copilot'; windows = @() })
    New-NvOverlayPanelCase 'activeUsage' 'a provider a row is open for' ([ordered]@{ snap = [ordered]@{ rows = @([ordered]@{ provider = 'claude' }, [ordered]@{ provider = 'CODEX' }); header = [ordered]@{ usage = $usage } } })
    New-NvOverlayPanelCase 'activeUsage' 'no rows, none' ([ordered]@{ snap = [ordered]@{ rows = @(); header = [ordered]@{ usage = $usage } } })
    New-NvOverlayPanelCase 'activeUsage' 'Copilot alone' ([ordered]@{ snap = [ordered]@{ rows = @([ordered]@{ provider = 'copilot'; kind = 'job' }); header = [ordered]@{ usage = $usage } } })
    New-NvOverlayPanelCase 'openBusy' 'a short title' ([ordered]@{ title = 'fix the build'; seconds = 3 })
    New-NvOverlayPanelCase 'openBusy' 'a long title' ([ordered]@{ title = ('w' * 50); seconds = 12 })
    New-NvOverlayPanelCase 'openBusy' 'no title' ([ordered]@{ title = ''; seconds = 0 })
    foreach ($s in 0, 1, 2, 3, 4, 5, 6, 7) { New-NvOverlayPanelCase 'fullScreen' "state $s" ([ordered]@{ state = $s }) }
    foreach ($k in 'session', 'cutoff', 'recent', 'job', 'usage', 'notice', 'ask', 'reload', 'Session', 'header', '') {
        New-NvOverlayPanelCase 'cardRow' "kind '$k'" ([ordered]@{ row = [ordered]@{ kind = $k } })
    }
    New-NvOverlayPanelCase 'cardRow' 'no row' ([ordered]@{ row = $null })
    New-NvOverlayPanelCase 'unlocked' 'with the hotkey' ([ordered]@{ hotkey = 'Ctrl+Alt+Shift+O' })
    New-NvOverlayPanelCase 'unlocked' 'no hotkey' ([ordered]@{ hotkey = '' })
} -Expect {
    param($In, $Name)
    # what the two drawing functions are handed, kept instead of drawn
    $marks = New-Object System.Collections.Generic.List[object]
    function Add-ChatOverlayNotice {
        param($Panel, $Notice)
        [void]$marks.Add($Notice)
        return [pscustomobject]@{ ToolTip = $null; Margin = $null }
    }
    function New-ChatOverlayDotLine {
        param([string]$Dot, [string]$Right, [string]$RightColor, [string]$Text, [string]$TextColor)
        return [pscustomobject]@{ Dot = $Dot; Text = $Text; Margin = $null }
    }
    $panel = [pscustomobject]@{ Children = (New-Object System.Collections.Generic.List[object]) }
    $now = [int64]$In.now
    switch ([string]$In.kind) {
        'title' { Format-ChatTitle ([string]$In.text) ([int]$In.width) }
        'limit' { Limit-ChatqText ([string]$In.text) ([int]$In.max) -Ellipsis:([bool]$In.ellipsis) }
        'autoTitle' { Format-ChatqAutoTitle ([string]$In.text) ([int]$In.max) }
        'askHead' { Use-NvTimeZone 'UTC' { Format-ChatqAskHead $In.ask ([DateTimeOffset]::FromUnixTimeMilliseconds($now).LocalDateTime) } }
        'askCount' { Format-ChatqAskCount $In.ask }
        'askLeave' { Format-ChatqAskLeaveTip $In.ask }
        'reloadText' { Format-ChatOverlayReloadText $In.reload }
        'chipActions' {
            , @(@(Get-ChatOverlayChipActions $In.row) | Where-Object { $_ } | ForEach-Object {
                    [ordered]@{ id = [string]$_.Id; label = [string]$_.Label; tip = [string]$_.Tip; disabled = [bool]$_.Disabled }
                })
        }
        'openable' { [bool](Test-ChatOverlayRowOpenable $In.row) }
        'deletable' { [bool](Test-ChatOverlayRowDeletable $In.row) }
        'deleteArmed' { [bool](Test-ChatOverlayDeleteArmed ([string]$In.armedKey) (ConvertTo-NvOverlayPanelTime $In.armedAt) ([string]$In.key) (ConvertTo-NvOverlayPanelTime $now)) }
        'pressCounts' { [bool](Test-ChatOverlayChipPressCounts $In.shown ([int64]$In.press)) }
        'chipTarget' {
            Get-ChatOverlayChipTarget ([string]$In.shown) ([string]$In.under) ([double]$In.rested) ([bool]$In.onChip) ([double]$In.sinceOver) ([bool]$In.down) ([bool]$In.blocked) ([string]$In.spent) ([double]$In.delay)
        }
        'step' {
            $st = $In.state
            $s = @{ ChipUnder = [string]$st.under; ChipUnderAt = (ConvertTo-NvOverlayPanelTime $st.underAt); ChipLastPos = [string]$st.lastPos
                ChipKey = [string]$st.key; ChipOverAt = (ConvertTo-NvOverlayPanelTime $st.overAt); ChipSpent = [string]$st.spent; ChipArmed = [bool]$st.armed
            }
            Step-ChatOverlayChipState $s ([string]$In.under) ([string]$In.pos) ([bool]$In.onChip) (ConvertTo-NvOverlayPanelTime $now)
            [ordered]@{ under = [string]$s.ChipUnder; underAt = (ConvertFrom-NvOverlayPanelTime $s.ChipUnderAt); lastPos = [string]$s.ChipLastPos; key = [string]$s.ChipKey
                overAt = (ConvertFrom-NvOverlayPanelTime $s.ChipOverAt); spent = [string]$s.ChipSpent; armed = [bool]$s.ChipArmed
            }
        }
        'cardLeft' { [bool](Test-ChatOverlayCardLeft @($In.panel) $In.screen) }
        'chipLayout' {
            $pn = if ($null -ne $In.panel) { @($In.panel) } else { $null }
            $r = Get-ChatOverlayChipLayout -Row @($In.row) -Line @($In.line) -Icons @($In.icons) -Words @($In.words) -Screen $In.screen -Name @($In.name) -Panel $pn -Gap ([int]$In.gap) -WordsX $In.wordsX
            if ($null -eq $r) { $null }
            else {
                [ordered]@{ X = [int]$r.X; Y = [int]$r.Y; IconsAt = (ConvertTo-NvOverlayPanelPair $r.IconsAt); WordsAt = (ConvertTo-NvOverlayPanelPair $r.WordsAt)
                    NameAt = (ConvertTo-NvOverlayPanelPair $r.NameAt); Left = [bool]$r.Left; Out = [int]$r.Out
                }
            }
        }
        'cardPlace' {
            $r = Get-ChatOverlayCardPlacement -Panel @($In.panel) -Row @($In.row) -Size @($In.size) -Screen $In.screen -Gap ([int]$In.gap) -Push ([int]$In.push) -Below:([bool]$In.below)
            [ordered]@{ X = [int]$r.X; Y = [int]$r.Y; Left = [bool]$r.Left; Below = [bool]$r.Below; Above = [bool]$r.Above; TipX = [int]$r.TipX }
        }
        'controlsPlace' {
            $r = Get-ChatOverlayControlsPlacement -Panel @($In.panel) -Size @($In.size) -Screen $In.screen -Gap ([int]$In.gap) -Prefer ([string]$In.prefer) -Bar ([int]$In.bar) -Box ([int]$In.box) -Inset ([int]$In.inset) -Indent ([int]$In.indent)
            [ordered]@{ X = [int]$r.X; Y = [int]$r.Y; Side = [string]$r.Side; Align = [string]$r.Align }
        }
        'controlsShown' {
            [bool](Get-ChatOverlayControlsShown ([bool]$In.shown) ([bool]$In.onPanel) ([bool]$In.onControls) ([bool]$In.dragging) ([bool]$In.down) ([double]$In.rested) ([double]$In.sinceOver))
        }
        'resize' {
            $r = Get-ChatOverlayResize -Rows ([int]$In.rows) -Dy ([double]$In.dy) -RowHeight ([double]$In.rowHeight) -Scale ([double]$In.scale) -Collapsed:([bool]$In.collapsed) -Kept ([int]$In.kept) -Edge ([string]$In.edge) `
                -Open ([int]$In.open) -RecentDrawn ([int]$In.recentDrawn) -RecentPool ([int]$In.recentPool) -RecentKept ([int]$In.recentKept) -RecentHeight ([double]$In.recentHeight) -HeadHeight ([double]$In.headHeight)
            [ordered]@{ Rows = [int]$r.Rows; Recent = [int]$r.Recent; Steps = [int]$r.Steps; RecentSteps = [int]$r.RecentSteps; Grow = [double]$r.Grow }
        }
        'heightCap' { [double](Get-ChatOverlayHeightCap ([int]$In.top) $In.area ([double]$In.scale) ([double]$In.floor) $In.bottom) }
        'placement' {
            $r = Get-ChatOverlayPlacement $In.x $In.y ([int]$In.w) ([int]$In.h) @($In.screens)
            [ordered]@{ X = [int]$r.X; Y = [int]$r.Y; Moved = [bool]$r.Moved }
        }
        'edgesRect' { , @(Get-ChatOverlayEdgesRect @($In.panel) ([int]$In.out) | ForEach-Object { [int]$_ }) }
        'raisePlan' {
            $r = Get-ChatOverlayRaisePlan ([int]$In.code)
            if ($null -eq $r) { $null } else { [ordered]@{ By = [string]$r.By; Seconds = [int]$r.Seconds; Words = [int]$r.Words } }
        }
        'titleOn' { [bool](Test-ChatWindowTitleOn ([string]$In.title) ([string]$In.root) @($In.profiles)) }
        'selectWindow' {
            $w = Select-ChatCodeWindow -Cwd ([string]$In.cwd) -Windows @($In.windows) -Profiles @($In.profiles) -Name ([string]$In.name)
            if ($null -eq $w) { $null } else { [int64]$w.Handle }
        }
        'hotkey' {
            try {
                $h = ConvertFrom-ChatOverlayHotkey ([string]$In.text)
                if ($null -eq $h) { $null } else { [ordered]@{ Mods = [int]$h.Mods; Vk = [int]$h.Vk; Text = [string]$h.Text } }
            }
            catch { [ordered]@{ error = $_.Exception.Message } }
        }
        'rowClock' {
            $spec = Get-ChatOverlayRowClock $In.row
            $spec | Add-Member -NotePropertyName Live -NotePropertyValue ([bool]$In.live)
            Format-ChatOverlayRowClock $spec $now
        }
        'rowWords' { Get-ChatOverlayRowWords $In.row }
        'cardWords' { Get-ChatOverlayCardWords $In.row @{ What = [string]$In.what } }
        'headNotices' {
            $stamp = [DateTimeOffset]::FromUnixTimeMilliseconds($now).ToString('o', $script:NvInv)
            Use-NvTimeZone 'UTC' { Use-NvClock $stamp { [void](Add-ChatOverlayHeadNotices $null $panel $In.snap) } }
            # not , @($marks): 5.1 throws 'Argument types do not match' on
            # @() round a List[object] local
            , $marks.ToArray()
        }
        'reloadNotice' {
            [void](Add-ChatOverlayReload $null $panel $In.reload)
            $marks[0]
        }
        'sayWord' { Get-ChatOverlaySayWord @{ Kind = [string]$In.say; Tone = [string]$In.tone } }
        'compact' {
            [void](Add-ChatOverlayCompact $panel $In.snap @())
            $l = $panel.Children[0]
            [ordered]@{ dot = [string]$l.Dot; text = [string]$l.Text }
        }
        'activeUsage' { , @(Select-ChatOverlayActiveUsage $In.snap | ForEach-Object { [string]$_.provider }) }
        'openBusy' { (Get-ChatOverlayOpenSay -Title ([string]$In.title) -State busy -Seconds ([int]$In.seconds)).Text }
        'fullScreen' { [bool](Test-ChatOverlayFullScreenState ([int]$In.state)) }
        'cardRow' { [bool](Test-ChatOverlayCardRow $In.row) }
        'unlocked' { New-ChatOverlayUnlockedHint @{ Hotkey = [bool][string]$In.hotkey; HotkeyText = [string]$In.hotkey } }
        default { throw "a case of kind '$($In.kind)'" }
    }
}
