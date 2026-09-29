# Charlie-and-the-chat-factory, src/overlay-mac.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region overlay: macOS panel ---------------------------------------------------
# UNTESTED - nothing here has run on a Mac yet; TESTING.md has the checklist.
# JavaScript for Automation, run by osascript, which every Mac has: a
# borderless floating NSPanel that never activates, and a menu bar item. It
# draws data/overlay.json, which the pwsh host beside it rewrites. The pure
# part (CO) is checked under node by tests/overlay-mac-check.js; everything
# that touches Cocoa is inside run(). ASCII only, and no ?. or ?? - older
# JavaScriptCore reads neither.

$script:ChatOverlayJxa = @'
var CO = {
  clamp: function (v, lo, hi) { return Math.max(lo, Math.min(hi, v)); },
  pad: function (n) { return (n < 10 ? '0' : '') + n; },
  // English whatever the Mac's language, as the Windows panel's are
  days: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
  until: function (ms, now) {
    if (!ms) { return ''; }
    var s = (ms - now) / 1000;
    if (s <= 0) { return 'reset'; }
    if (s >= 86400) {
      var d = new Date(ms);
      return CO.days[d.getDay()] + ' ' + CO.pad(d.getHours()) + ':' + CO.pad(d.getMinutes());
    }
    var m = Math.floor(s / 60);
    if (m >= 60) { return Math.floor(m / 60) + 'h ' + (m % 60) + 'm'; }
    if (m >= 1) { return m + 'm'; }
    return Math.ceil(s) + 's';
  },
  // the clock time a limit is over: HH:mm today, with the weekday after;
  // nothing once it has passed. Format-ChatOverlayResetAt's twin.
  at: function (ms, now) {
    if (!ms || ms <= now) { return ''; }
    var d = new Date(ms), n = new Date(now);
    var hm = CO.pad(d.getHours()) + ':' + CO.pad(d.getMinutes());
    if (d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()) { return hm; }
    return CO.days[d.getDay()] + ' ' + hm;
  },
  // the label of the one window whose reset a usage line shows, or null: of
  // the limited ones, the latest reset - you are blocked until then - else
  // the 5h window's. Get-ChatOverlayResetWindow's twin.
  resetFor: function (windows, now) {
    var best = null, i, w;
    for (i = 0; i < (windows || []).length; i++) {
      w = windows[i];
      if (w.limited && w.resetsAt > now && (!best || w.resetsAt > best.resetsAt)) { best = w; }
    }
    if (best) { return best.label; }
    for (i = 0; i < (windows || []).length; i++) {
      w = windows[i];
      if (w.label === '5h' && w.resetsAt > now) { return w.label; }
    }
    return null;
  },
  colors: {
    waiting: [0.96, 0.73, 0.26], 'needs-input': [0.96, 0.73, 0.26], busy: [0.30, 0.76, 0.54],
    running: [0.31, 0.63, 1.0], idle: [0.50, 0.53, 0.56], queued: [0.71, 0.55, 1.0], cutoff: [1.0, 0.54, 0.30],
    text: [0.91, 0.92, 0.93], dim: [0.60, 0.63, 0.65], faint: [0.42, 0.44, 0.47], project: [0.54, 0.72, 1.0],
    normal: [0.35, 0.66, 0.90], warning: [0.96, 0.73, 0.26], critical: [1.0, 0.36, 0.36],
    warn: [0.96, 0.73, 0.26], error: [1.0, 0.48, 0.45], unlocked: [0.31, 0.63, 1.0]
  },
  // the light look: the same meanings, darker to read on white
  light: {
    waiting: [0.79, 0.54, 0.0], 'needs-input': [0.79, 0.54, 0.0], busy: [0.10, 0.56, 0.30],
    running: [0.12, 0.44, 0.92], idle: [0.55, 0.58, 0.62], queued: [0.51, 0.31, 0.87], cutoff: [0.74, 0.30, 0.0],
    text: [0.12, 0.14, 0.16], dim: [0.34, 0.38, 0.42], faint: [0.55, 0.58, 0.62], project: [0.04, 0.41, 0.85],
    normal: [0.04, 0.41, 0.85], warning: [0.75, 0.53, 0.0], critical: [0.81, 0.13, 0.18],
    warn: [0.60, 0.40, 0.0], error: [0.81, 0.13, 0.18], unlocked: [0.04, 0.41, 0.85]
  },
  // config.theme - dark, light or system - to the look drawn
  themeOf: function (config, systemDark) {
    var t = (config && config.theme) || 'dark';
    if (t === 'system') { return systemDark ? 'dark' : 'light'; }
    return t === 'light' ? 'light' : 'dark';
  },
  opacityOf: function (config) { return CO.clamp((config && config.opacity) || 0.94, 0.3, 1); },
  color: function (name, theme) {
    var p = theme === 'light' ? CO.light : CO.colors;
    return p[name] || p.text;
  },
  bar: function (pct) {
    var n = Math.round(CO.clamp(pct, 0, 100) / 10);
    return new Array(n + 1).join('\u2588') + new Array(11 - n).join('\u2591');
  },
  stale: function (snap, now, ms) { return !snap || !snap.at || (now - snap.at) > ms; },
  // the panel as lines of runs: [[text, colour name, bold], ...]
  lines: function (snap, now, locked, hotkey) {
    var out = [], i, j;
    var usage = (snap && snap.header && snap.header.usage) || [];
    var bars = !!(snap && snap.config && snap.config.usageView === 'bars');
    for (i = 0; i < usage.length; i++) {
      var u = usage[i];
      if (!bars) {
        // one line a provider, when its figure is from at the end
        var line = [[(u.provider + '        ').slice(0, 8), u.stale ? 'faint' : 'text', true]];
        // one reset time a line: the window you wait on, not every one
        var rw = CO.resetFor(u.windows, now), told = false;
        for (j = 0; j < u.windows.length; j++) {
          var v = u.windows[j];
          if (j) { line.push([' \u00B7 ', 'faint', false]); }
          line.push([v.label + ' ', 'dim', false]);
          line.push([v.percent + '%', u.stale ? 'faint' : (v.limited ? 'critical' : (v.severity === 'warning' || v.severity === 'critical' ? v.severity : 'text')), true]);
          var t = !told && rw !== null && v.label === rw ? CO.at(v.resetsAt, now) : '';
          if (t) { told = true; line.push([' resets ' + t, v.limited ? 'critical' : 'dim', false]); }
        }
        if (u.status) { line.push(['   ' + u.status, 'faint', false]); }
        out.push(line);
        continue;
      }
      for (j = 0; j < u.windows.length; j++) {
        var w = u.windows[j];
        var name = j === 0 ? u.provider : '';
        out.push([[(name + '       ').slice(0, 7), u.stale ? 'faint' : 'text', true],
          [(w.label + '            ').slice(0, 12), 'dim', false],
          [CO.bar(w.percent), u.stale ? 'faint' : w.severity, false],
          [('    ' + w.percent + '%').slice(-5), w.limited ? 'critical' : 'text', true],
          ['  ' + CO.until(w.resetsAt, now), 'dim', false],
          // when the figure is from, on the provider's first row
          [j === 0 && u.status ? '   ' + u.status : '', 'faint', false]]);
      }
    }
    var notes = (snap && snap.header && snap.header.notes) || [];
    for (i = 0; i < notes.length; i++) { out.push([[notes[i].text, notes[i].tone === 'dim' ? 'faint' : notes[i].tone, false]]); }
    if (usage.length || notes.length) { out.push([['', 'faint', false]]); }
    var rows = (snap && snap.rows) || [];
    var max = (snap && snap.config && snap.config.maxRows) || 8;
    for (i = 0; i < rows.length && i < max; i++) {
      var r = rows[i];
      // a terminal's chat marked >_, one a queued prompt runs in a play
      // triangle, as the Windows panel draws them; VS Code's unmarked
      out.push([[r.status === 'queued' ? '\u25CB ' : '\u25CF ', r.status, false],
        [r.project ? r.project + '  ' : '', 'project', true],
        [(r.where === 'terminal' ? '>_ ' : r.where === 'run' ? '\u25B7 ' : '') + r.title + '   ', 'text', false],
        [r.stateText, r.rank === 0 ? 'warn' : 'dim', false]]);
      if (r.prompt && (!snap.config || snap.config.prompts !== false)) { out.push([['    ' + r.prompt, 'dim', false]]); }
    }
    if (rows.length > max) { out.push([['+' + (rows.length - max) + ' more', 'faint', false]]); }
    if (!rows.length) { out.push([['no chats open', 'faint', false]]); }
    if (!locked) { out.push([['unlocked - drag to move, Lock in the menu bar item', 'unlocked', false]]); }
    return out;
  },
  // verbs meant for this panel: newer than its start, each only once
  applyCommands: function (cmds, startedAt, seen) {
    var out = [];
    for (var i = 0; i < (cmds || []).length; i++) {
      var c = cmds[i];
      if (c.at > startedAt && !seen[c.id]) { seen[c.id] = true; out.push(c.verb); }
    }
    return out;
  },
  menuTitle: function (snap) {
    var c = (snap && snap.counts) || {};
    var need = (c.waiting || 0) + (c.needsInput || 0);
    return need ? 'CQ ' + need : 'CQ';
  },
  // the menu's continue item while the snapshot asks about cut-off chats;
  // '' hides it and Leave them
  askTitle: function (snap) {
    var a = snap && snap.header && snap.header.ask;
    if (!a || !a.count) { return ''; }
    return 'Continue ' + a.count + ' cut-off chat' + (a.count === 1 ? '' : 's');
  },
  // the cut-offs the menu's items stand for, as the snapshot they were
  // drawn from named them - a key is id_uuid, nothing else goes in
  askKeys: function (snap) {
    var a = snap && snap.header && snap.header.ask;
    var ks = (a && a.keys) || [];
    return ks.map(String).filter(function (k) { return /^[0-9A-Za-z-]+_[0-9A-Za-z-]+$/.test(k); }).join(',');
  },
  // the line an answer writes to overlay-cmd: the verb and the keys it
  // showed. The item's title is set on a timer that does not fire while the
  // menu is open, so the host answers these, never its newer snapshot's;
  // none drawn is "none", which answers nothing
  askLine: function (verb, keys) {
    return verb + ' ' + (keys || 'none');
  },
  // auto-continue's automatic mode as the snapshot has it: on only when it
  // says so - the default, ask, and off are not
  autoOn: function (snap) {
    var h = snap && snap.header;
    return !!(h && (h.autoContinue === 'on' || (h.autoContinue === undefined && h.autoOn === true)));
  },
  // the verb a click on the menu item writes: on, or back to the default
  autoVerb: function (snap) {
    return CO.autoOn(snap) ? 'auto-ask' : 'auto-on';
  }
};

function run(argv) {
  ObjC.import('Cocoa');
  var dataDir = argv[0];
  var snapPath = dataDir + '/overlay.json', statePath = dataDir + '/overlay-state.json', cmdPath = dataDir + '/overlay-cmd';
  var startedAt = Date.now(), seen = {}, snap = null, shownKey = '';
  // Cocoa's enum values as numbers: the names the bridge knows vary with
  // the macOS version, the values never do
  var UTF8 = 4, ACCESSORY = 1, BORDERLESS = 0, NONACTIVATING = 128, BUFFERED = 2, FLOATING = 3, TRUNCATE_TAIL = 4;
  var app = $.NSApplication.sharedApplication;
  // no Dock icon and no menu of its own; the first thing, or the icon flashes
  app.setActivationPolicy(ACCESSORY);
  // App Nap would slow the 1 s timer to a crawl while the panel is hidden
  $.NSProcessInfo.processInfo.beginActivityWithOptionsReason(0x00EFFFFF, 'chatoverlay keeps its panel current');

  var read = function (path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, UTF8, null);
    if (!s || s.isNil()) { return null; }
    try { return JSON.parse(s.js); } catch (e) { return null; }
  };
  var write = function (path, text) {
    $.NSString.alloc.initWithUTF8String(text).writeToFileAtomicallyEncodingError(path, true, UTF8, null);
  };
  var append = function (path, text) {
    var fm = $.NSFileManager.defaultManager;
    if (!fm.fileExistsAtPath(path)) { fm.createFileAtPathContentsAttributes(path, $.NSData.data, $()); }
    var fh = $.NSFileHandle.fileHandleForWritingAtPath(path);
    if (!fh || fh.isNil()) { return; }
    fh.seekToEndOfFile;
    fh.writeData($.NSString.alloc.initWithUTF8String(text).dataUsingEncoding(UTF8));
    fh.closeFile;
  };
  var st = read(statePath) || {};
  var locked = st.locked !== false, hidden = st.hidden === true;
  var saveState = function () {
    var f = panel.frame;
    write(statePath, JSON.stringify({ x: f.origin.x, y: f.origin.y + f.size.height, locked: locked, hidden: hidden }));
  };

  var width = Math.min(800, Math.max(260, Number(((read(snapPath) || {}).config || {}).width) || 380));
  var screen = $.NSScreen.mainScreen.visibleFrame;
  var panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, width, 60), BORDERLESS | NONACTIVATING, BUFFERED, false);
  panel.setLevel(FLOATING);
  // every Space, stays put through Expose, and over full-screen apps
  panel.setCollectionBehavior(1 | 16 | 256);
  panel.setHidesOnDeactivate(false);
  panel.setOpaque(false);
  panel.setBackgroundColor($.NSColor.clearColor);
  panel.setHasShadow(true);
  panel.setIgnoresMouseEvents(locked);
  panel.setMovableByWindowBackground(true);
  var fx = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, width, 60));
  fx.setMaterial(13);
  fx.setBlendingMode(0);
  fx.setState(1);
  fx.setWantsLayer(true);
  fx.layer.setCornerRadius(8);
  fx.layer.setMasksToBounds(true);
  var label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(11, 8, width - 22, 44));
  label.setEditable(false);
  label.setSelectable(false);
  label.setBordered(false);
  label.setDrawsBackground(false);
  label.cell.setLineBreakMode(TRUNCATE_TAIL);
  fx.addSubview(label);
  panel.setContentView(fx);

  var top = (typeof st.y === 'number') ? st.y : screen.origin.y + screen.size.height - 16;
  var left = (typeof st.x === 'number') ? st.x : screen.origin.x + screen.size.width - width - 16;

  var font = $.NSFont.monospacedDigitSystemFontOfSizeWeight(12, 0);
  var bold = $.NSFont.monospacedDigitSystemFontOfSizeWeight(12, 0.3);
  // macOS's own light or dark setting, for theme: system
  var systemDark = function () {
    var s = $.NSUserDefaults.standardUserDefaults.stringForKey('AppleInterfaceStyle');
    return !!(s && !s.isNil() && s.js === 'Dark');
  };
  var look = '';
  var applyLook = function (theme, opacity) {
    var key = theme + '|' + opacity;
    if (key === look) { return; }
    look = key;
    // HUD material for dark; the popover one follows the appearance given
    fx.setMaterial(theme === 'light' ? 6 : 13);
    fx.setAppearance($.NSAppearance.appearanceNamed(theme === 'light' ? 'NSAppearanceNameVibrantLight' : 'NSAppearanceNameVibrantDark'));
    panel.setAlphaValue(opacity);
  };
  var paint = function (now) {
    var cfg = snap && snap.config;
    var theme = CO.themeOf(cfg, cfg && cfg.theme === 'system' ? systemDark() : false);
    applyLook(theme, CO.opacityOf(cfg));
    var lines = CO.lines(snap, now, locked);
    var text = $.NSMutableAttributedString.alloc.init;
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < lines[i].length; j++) {
        var seg = lines[i][j], c = CO.color(seg[1], theme);
        // the values of NSForegroundColorAttributeName and NSFontAttributeName
        var attrs = $.NSDictionary.dictionaryWithObjectsForKeys(
          [$.NSColor.colorWithSRGBRedGreenBlueAlpha(c[0], c[1], c[2], 1), seg[2] ? bold : font],
          ['NSColor', 'NSFont']);
        text.appendAttributedString($.NSAttributedString.alloc.initWithStringAttributes(seg[0], attrs));
      }
      if (i < lines.length - 1) { text.appendAttributedString($.NSAttributedString.alloc.initWithString('\n')); }
    }
    label.setAttributedStringValue(text);
    var h = Math.ceil(label.cell.cellSizeForBounds($.NSMakeRect(0, 0, width - 22, 10000)).height) + 16;
    var f = panel.frame;
    // keep the top edge where it is, as the rows come and go
    var t = f.size.height > 0 && f.origin.y ? f.origin.y + f.size.height : top;
    panel.setFrameDisplay($.NSMakeRect(f.origin.x || left, t - h, width, h), true);
    fx.setFrame($.NSMakeRect(0, 0, width, h));
    label.setFrame($.NSMakeRect(11, 8, width - 22, h - 16));
  };

  var item = $.NSStatusBar.systemStatusBar.statusItemWithLength(-1);
  item.button.setTitle('CQ');
  var menu = $.NSMenu.alloc.init;
  var add = function (title, sel) {
    var m = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(title, sel, '');
    if (sel) { m.setTarget(target); }
    menu.addItem(m);
    return m;
  };
  var apply = function (verb) {
    if (verb === 'lock' || verb === 'unlock' || verb === 'toggle') {
      locked = verb === 'lock' ? true : (verb === 'unlock' ? false : !locked);
      panel.setIgnoresMouseEvents(locked);
    } else if (verb === 'hide' || verb === 'show') {
      hidden = verb === 'hide';
      if (hidden) { panel.orderOut(null); } else { panel.orderFrontRegardless; }
    } else if (verb === 'reset') {
      var s = $.NSScreen.mainScreen.visibleFrame, f = panel.frame;
      panel.setFrameOrigin($.NSMakePoint(s.origin.x + s.size.width - width - 16, s.origin.y + s.size.height - 16 - f.size.height));
    }
    lockItem.setTitle(locked ? 'Unlock to move' : 'Lock');
    hideItem.setTitle(hidden ? 'Show' : 'Hide');
    shownKey = '';
    saveState();
  };
  var lastFrame = '';
  var tick = function () {
    var now = Date.now();
    var s = read(snapPath);
    if (s) { snap = s; }
    // the host that feeds it is gone - never leave a panel behind
    if (now - startedAt > 20000 && CO.stale(snap, now, 20000)) { app.terminate(null); return; }
    var verbs = CO.applyCommands(snap && snap.commands, startedAt, seen);
    for (var i = 0; i < verbs.length; i++) { apply(verbs[i]); }
    item.button.setTitle(CO.menuTitle(snap));
    stepAsk();
    try { autoItem.setState(CO.autoOn(snap) ? 1 : 0); } catch (e) {}
    if (!hidden) { paint(now); }
    var f = panel.frame, key = f.origin.x + ',' + f.origin.y;
    if (lastFrame && key !== lastFrame) { saveState(); }
    lastFrame = key;
  };

  ObjC.registerSubclass({
    name: 'ChatOverlayTarget',
    methods: {
      'tick:': { types: ['void', ['id']], implementation: function (t) { tick(); } },
      'toggleLock:': { types: ['void', ['id']], implementation: function (m) { apply('toggle'); } },
      'toggleHide:': { types: ['void', ['id']], implementation: function (m) { apply(hidden ? 'show' : 'hide'); } },
      'moveHome:': { types: ['void', ['id']], implementation: function (m) { apply('reset'); } },
      // the collector sets it (Set-ChatqAutoContinue), and the next
      // snapshot's autoContinue moves the check
      'toggleAuto:': { types: ['void', ['id']], implementation: function (m) { try { append(cmdPath, new Date().toISOString() + ' ' + CO.autoVerb(snap) + '\n'); } catch (e) {} } },
      'quit:': { types: ['void', ['id']], implementation: function (m) { append(cmdPath, new Date().toISOString() + ' stop\n'); app.terminate(null); } },
      // the host answers, as it does a stop: it holds the ask and the jobs
      'askGo:': { types: ['void', ['id']], implementation: function (m) { try { append(cmdPath, new Date().toISOString() + ' ' + CO.askLine('ask-go', askKeys) + '\n'); } catch (e) {} } },
      'askLeave:': { types: ['void', ['id']], implementation: function (m) { try { append(cmdPath, new Date().toISOString() + ' ' + CO.askLine('ask-leave', askKeys) + '\n'); } catch (e) {} } }
    }
  });
  var target = $.ChatOverlayTarget.alloc.init;
  // at the very top, as on Windows, and only while the snapshot asks. None
  // of this has run on a Mac, so a bridge call that fails costs the ask
  // items, never the panel.
  // askKeys: what the items stand for, as last drawn - an answer names them
  var askGo = null, askLeave = null, askSep = null, askShown = null, askKeys = '';
  try {
    askGo = add('Continue cut-off chats', 'askGo:');
    askLeave = add('Leave them', 'askLeave:');
    askSep = $.NSMenuItem.separatorItem;
    menu.addItem(askSep);
  } catch (e) {}
  var stepAsk = function () {
    var t = CO.askTitle(snap), a = snap && snap.header && snap.header.ask;
    var tip = ((a && a.titles) || []).join('\n');
    var keys = t ? CO.askKeys(snap) : '';
    if (t + '|' + tip + '|' + keys === askShown) { return; }
    askShown = t + '|' + tip + '|' + keys;
    askKeys = keys;
    try {
      if (askGo) {
        askGo.setTitle(t || 'Continue cut-off chats');
        askGo.setToolTip(tip);
        askGo.setHidden(!t);
      }
      if (askLeave) { askLeave.setHidden(!t); }
      if (askSep) { askSep.setHidden(!t); }
    } catch (e) {}
  };
  stepAsk();
  add('Charlie-and-the-chat-factory overlay', null);
  menu.addItem($.NSMenuItem.separatorItem);
  var lockItem = add(locked ? 'Unlock to move' : 'Lock', 'toggleLock:');
  var hideItem = add(hidden ? 'Show' : 'Hide', 'toggleHide:');
  add('Move to top right', 'moveHome:');
  var autoItem = add('Auto-continue cut-off chats', 'toggleAuto:');
  try { autoItem.setState(CO.autoOn(read(snapPath)) ? 1 : 0); } catch (e) {}
  menu.addItem($.NSMenuItem.separatorItem);
  add('Quit', 'quit:');
  item.setMenu(menu);

  snap = read(snapPath);
  stepAsk();
  paint(Date.now());
  if (!hidden) { panel.orderFrontRegardless; }
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(1.0, target, 'tick:', $(), true);
  app.run;
}

if (typeof module !== 'undefined') { module.exports = CO; }
'@

# a notification (Show-ChatOverlayMacNotice), handed here instead of to
# osascript - tests
$script:ChatOverlayMacNotifySeam = $null

function Show-ChatOverlayMacNotice {
    # A macOS notification through osascript. The script goes in on stdin,
    # so no argument quoting stands between the text and AppleScript; the
    # text is escaped for an AppleScript string. Never throws.
    param([string]$Text, [string]$Title = 'chatq')
    $q = { param($s) '"' + (($s -replace '[\r\n]+', ' ') -replace '\\', '\\' -replace '"', '\"') + '"' }
    $as = "display notification $(& $q $Text) with title $(& $q $Title)"
    if ($script:ChatOverlayMacNotifySeam) { $null = & $script:ChatOverlayMacNotifySeam ([pscustomobject]@{ Title = $Title; Text = $Text; Script = $as }); return }   # tests
    try { $null = $as | & osascript 2>$null }
    catch { Write-ChatOverlayLog "notice: $($_.Exception.Message)" }
}

function Update-ChatOverlayMacAsk {
    # After each pass: the ask the collector just found news of, and what an
    # answer from the menu did, as notifications - then both are cleared,
    # so each is said once. A click on one does nothing useful on macOS
    # (it opens Script Editor), so the text points at the menu instead.
    param($Ctx)
    if ($Ctx.AskNews) {
        $a = $Ctx.AskNews.Ask
        $Ctx.AskNews = $null
        try {
            $n = [int]$a.Count
            $titles = @(@($a.Items) | Select-Object -First 3 | ForEach-Object { Format-ChatTitle $_.Title 40 })
            $list = $titles -join ', '
            if ($n -gt $titles.Count) { $list += " and $($n - $titles.Count) more" }
            # the day too once it is not today, as the note and the Windows balloon say it
            $at = Format-ChatOverlayAskAt $a.ResetsAt
            $chats = if ($n -eq 1) { '1 chat' } else { "$n chats" }
            $head = if ($at) { "limit over at $at - " } else { '' }
            Show-ChatOverlayMacNotice "$head$chats it cut off can continue: $list. Continue or leave them from the CQ menu."
        }
        catch { Write-ChatOverlayLog "ask: $($_.Exception.Message)" }
    }
    if ($Ctx.AskSaid) {
        $t = [string]$Ctx.AskSaid
        $Ctx.AskSaid = $null
        Show-ChatOverlayMacNotice $t
    }
}

function Start-ChatOverlayMacHost {
    <#
    UNTESTED. The macOS overlay: this pwsh collects every 2 s and a JXA child
    draws the panel and menu bar item from overlay.json. A child that dies
    without a stop is started again, three times in ten minutes at most; the
    child quits by itself when the snapshot goes 20 s stale, so a host killed
    outright leaves no panel behind.
    #>
    Set-StrictMode -Off
    New-ChatqDir $script:ChatqData
    $lock = Lock-ChatOverlay
    if (-not $lock) { Write-ChatOverlayLog "overlay $PID found one already running"; return }
    $S = @{ Child = $null; Starts = [System.Collections.Generic.List[datetime]]::new() }
    $why = $null
    try {
        Set-Content -LiteralPath $script:ChatOverlayPidPath -Value $PID -Encoding ASCII
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID started ($script:ChatVersion, macOS)"
        $js = $script:ChatOverlayJxa
        $old = if (Test-Path -LiteralPath $script:ChatOverlayMacJsPath) { [System.IO.File]::ReadAllText($script:ChatOverlayMacJsPath) } else { '' }
        if ($old -ne $js) { Save-ChatqText $script:ChatOverlayMacJsPath $js }
        $ctx = New-ChatOverlayContext
        # the panel here draws rows alone: a Recent list would be built, and
        # its transcripts listed and read, for nothing
        $ctx.WantRecent = $false
        # this host announces the reset ask and takes the menu's answer
        $ctx.WantAsk = $true
        # and its passes queue continues while the switch is on (src/auto-continue.ps1)
        $ctx.WantAuto = $true
        Restore-ChatOverlayUsage $ctx
        # a snapshot on disk before the panel first looks for one
        [void](Invoke-ChatOverlayCycle $ctx)
        # the first pass marks what it found as announced: say it now
        Update-ChatOverlayMacAsk $ctx
        $launch = {
            # quoted by hand: Start-Process joins these with spaces as they are
            $S.Child = Start-Process -FilePath 'osascript' -PassThru -ArgumentList @('-l', 'JavaScript',
                "`"$($script:ChatOverlayMacJsPath)`"", "`"$($script:ChatqData)`"")
            $S.Starts.Add((Get-Date))
        }
        # a stop or restart that came in while this was starting, taken by
        # that first pass
        $why = @(@($ctx.Verbs) | Where-Object { $_ -in 'stop', 'restart' })[0]
        if (-not $why) {
            & $launch
            $why = Invoke-ChatOverlayCollectLoop $ctx -OnCycle {
                param($snap)
                Update-ChatOverlayMacAsk $ctx
                if ($S.Child -and $S.Child.HasExited) {
                    $recent = @($S.Starts | Where-Object { $_ -gt (Get-Date).AddMinutes(-10) })
                    if ($recent.Count -ge 3) { Write-ChatOverlayLog 'the panel keeps exiting - stopping; see data/logs/overlay.err'; return 'panel' }
                    Write-ChatOverlayLog "the panel exited ($($S.Child.ExitCode)) - starting it again"
                    & $launch
                }
                return $null
            }
        }
    }
    catch { Write-ChatOverlayLog "overlay failed: $($_.Exception.Message)" }
    finally {
        try { if ($S.Child -and -not $S.Child.HasExited) { $S.Child.Kill() } } catch {}
        try { $lock.Dispose() } catch {}
        Remove-Item -LiteralPath $script:ChatOverlayPidPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID stopped ($why)"
    }
    if ($why -eq 'restart') { [void](Start-ChatOverlayProcess) }
}

#endregion
