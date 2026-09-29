// A new version of this extension, once installed, runs in a window only
// after that window reloads - and a reload ends every claude process the
// Claude extension started under it: a turn in flight, a permission prompt,
// a workflow or a background agent, all gone, in every chat tab of the
// window. Twice on 2026-09-27 a chatq
// VSIX installed from the command line was followed by a reload that did
// just that, to every Claude tab of the window. This extension is the one
// being updated, so it is the one that can make the update safe: the old
// instance notices the new one, says which chats of its window a reload
// would stop, and offers to wait until none is working.
//
// A reload, not the Developer command Restart Extension Host: in the VS Code
// this runs in (1.108.2, read in its workbench.desktop.main.js) that command
// stops the extension hosts and starts them again from the registry it had,
// with nothing added or removed - an extension already registered is not
// scanned again, so a VSIX installed from the command line never loads and
// the old version comes back up. Only the Extensions view's own Restart
// Extensions (updateRunningExtensions, which no command reaches) or a window
// reload loads it. A reload keeps the terminals (their pty host survives it),
// and the wait below has already seen every chat of the window idle.
//
// "Working" is the script's word (Get-ChatHostWork, src/host-work.ps1): the
// chats whose claude runs under this extension host, each one busy, waiting
// on a prompt, with a workflow or background agent out, or with a queued
// run going into it - Test-ChatIdle's judgement, made of one window. The
// reloads chatq itself asks for go through the same word (guardReload).
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const setup = require('./setup');

// lazily: the tests load this file with the vscode module stubbed out
function vs() { return require('vscode'); }
// extension.js, loaded by the time anything here runs: its helpers, and the
// stand-ins the tests put in its exports
function ext() { return require('./extension'); }
function log(s) { ext()._log(s); }

const ID = 'redaechan.charlie-and-the-chat-factory';
const RESTART = 'workbench.action.reloadWindow';
const CANCEL = 'chatManager.cancelRestart';

// Every wait, so the tests can set them.
//   poll      how often the wait for idle chats looks again
//   idleFor   every chat of the window idle this long, straight, before the
//             restart - the transcript's last minute is part of the look, so
//             a turn between two looks is still seen
//   look      one look at most; a slower one counts as not known
//   watch     how often extensions.json is looked at for a new install
const timing = { poll: 25000, idleFor: 60000, look: 20000, watch: 10000 };

const WAIT = 'Reload when they\'re idle';
const NOW = 'Reload now';
const GO = 'Reload the window';
const LATER = 'Later';
const AGAIN = 'Try again';

const WHY = { turn: '', prompt: ' (waiting on you)', background: ' (background work running)', run: ' (a queued prompt running)', '': '' };

const texts = {
    short: v => 'Charlie and the Chat Factory ' + v + ' is installed - reload the window to load it.',
    long: (v, n, names) => 'Charlie and the Chat Factory ' + v + ' is installed. Loading it reloads this window, which stops ' +
        (n === 1 ? 'the chat' : 'the ' + n + ' chats') + ' working here: ' + names + '.',
    unknown: v => 'Charlie and the Chat Factory ' + v + ' is installed. Loading it reloads this window, which stops any chat working here - and which chats work could not be checked.',
    waiting: n => '$(debug-restart) Chat Manager: reloads when ' + (n === 1 ? '1 chat is' : n + ' chats are') + ' idle',
    checking: '$(sync~spin) Chat Manager: checking the chats here before the reload',
    settling: '$(debug-restart) Chat Manager: reloads once the chats here stay idle a minute',
    unchecked: '$(debug-restart) Chat Manager: reload waits - the chats here could not be checked',
    tooOld: '$(debug-restart) Chat Manager: reload waits - the scripts in the tool folder are too old to check the chats here',
    waitTip: v => 'Charlie and the Chat Factory ' + v + ' loads when this window reloads. That waits until no chat here works. Click to cancel.',
    cancelled: v => 'The reload is off. Charlie and the Chat Factory ' + v + ' loads the next time this window reloads.',
    failed: v => 'Charlie and the Chat Factory ' + (v || '') + ' is installed, but this window could not be reloaded to load it. Try again, or reload it yourself (Developer: Reload Window).',
    reloadBusy: (n, names) => 'Reloading this window now would stop ' + (n === 1 ? 'the chat' : 'the ' + n + ' chats') + ' working here: ' +
        names + '. Reload once ' + (n === 1 ? 'it finishes' : 'they finish') + '.',
    reloadUnchecked: 'This window was not reloaded by itself: whether a chat here is working could not be checked, and a reload would stop it.'
};

// What this instance runs as - its id, version, and the installedTimestamp
// VS Code wrote for its folder - and where the installed extensions are
// listed. Set at activation.
let running = null;
// installs already said, by installKey: once each, for this instance's life
const said = new Set();
// the wait for idle chats, while there is one
let wait = null;
// why the last look gave nothing: 'old' when the tool folder's scripts have
// no Get-ChatHostWork, 'failed' otherwise, '' after one that answered
let lookWhy = '';

// ~/.vscode/extensions/extensions.json - VS Code's own list of what is
// installed, rewritten on every install - as an array, else null
function readInstalled(dir) {
    if (!dir) return null;
    try {
        let raw = fs.readFileSync(path.join(dir, 'extensions.json'), 'utf8');
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        const a = JSON.parse(raw);
        return Array.isArray(a) ? a : null;
    } catch (e) { return null; }
}

function idOf(e) { return String((e && e.identifier && e.identifier.id) || '').toLowerCase(); }
function stampOf(e) { const t = e && e.metadata && e.metadata.installedTimestamp; return Number.isFinite(t) ? t : null; }

// This extension's entry in that list: the one of its id - the newest, if
// VS Code ever left two. Pure.
function entryOf(list, id) {
    const mine = (list || []).filter(e => idOf(e) === String(id).toLowerCase());
    mine.sort((a, b) => (stampOf(b) || 0) - (stampOf(a) || 0));
    return mine[0] || null;
}

// What was installed over the running instance, as the key it is said once
// by, else ''. Another version - newer, or older - is its version; the same
// version installed again, with other files, is told by the install time
// VS Code stamps on it, and keyed by it. Pure.
function installKey(run, found) {
    if (!run || !found || !found.version) return '';
    if (found.version !== run.version) return found.version;
    if (Number.isFinite(found.stamp) && Number.isFinite(run.stamp) && found.stamp !== run.stamp) return found.version + '@' + found.stamp;
    return '';
}

// At activation: what runs here, and the install time of this very folder.
function noteRunning(context) {
    const pj = (context.extension && context.extension.packageJSON) || {};
    let version = String(pj.version || '');
    if (!version) {
        try { version = String(JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8')).version || ''); } catch (e) { }
    }
    const id = (context.extension && context.extension.id) || ID;
    const dir = context.extensionPath ? path.dirname(context.extensionPath) : null;
    const e = entryOf(readInstalled(dir), id);
    // an entry for another folder is not this instance's install
    const folder = context.extensionPath ? path.basename(context.extensionPath).toLowerCase() : '';
    const same = e && String(e.relativeLocation || '').toLowerCase() === folder;
    running = { id, version, stamp: same ? stampOf(e) : null, dir };
    log('running ' + id + ' ' + version + (running.stamp ? ', installed ' + new Date(running.stamp).toISOString() : ''));
    return running;
}

// What is installed now: VS Code's list first, which a new install rewrites
// at once; else - no list, as in an Extension Development Host - what VS
// Code's API says, which may keep the running version until the restart.
function installedNow() {
    const e = entryOf(readInstalled(running && running.dir), running ? running.id : ID);
    if (e && e.version) return { version: String(e.version), stamp: stampOf(e) };
    return apiNow();
}

function apiNow() {
    const x = vs().extensions && vs().extensions.getExtension && vs().extensions.getExtension(running ? running.id : ID);
    return x && x.packageJSON && x.packageJSON.version ? { version: String(x.packageJSON.version), stamp: null } : null;
}

// What the look runs after the loader: Get-ChatHostWork for this host, in
// the Claude home this window's Claude extension uses, printed as one line.
// Scripts older than 0.9.0 have no Get-ChatHostWork, and PowerShell would
// only say so on stderr and exit 0: they say so on stdout instead.
const TOO_OLD = 'chatq: no Get-ChatHostWork';
function hostWorkCommand(hostPid, home) {
    return 'if (-not (Get-Command Get-ChatHostWork -EA SilentlyContinue)) { [Console]::Out.WriteLine(\'' + TOO_OLD + '\') } else { ' +
        'Remove-Variable r -EA SilentlyContinue; $r = Get-ChatHostWork -HostPid ' + Math.trunc(hostPid) +
        (home ? ' -ConfigDir ' + ext()._psQuote(home) : '') + '; [Console]::Out.WriteLine((ConvertTo-ChatHostWorkJson $r)) }';
}

// Why a look gave nothing, for the log and the status bar: the tool
// folder's scripts too old to have Get-ChatHostWork - one set up before
// 0.9.0, or a git checkout, which setup never copies into - else the error
// and the first line PowerShell wrote to stderr. Pure.
function lookFailure(err, stdout, stderr) {
    if (String(stdout || '').split(/\r?\n/).some(l => l.trim() === TOO_OLD)) {
        return { old: true, text: 'the scripts in the tool folder are older than 0.9.0 (no Get-ChatHostWork) - set the tool folder up again, or update it' };
    }
    const first = String(stderr || '').split(/\r?\n/).map(l => l.trim()).find(l => l) || '';
    return { old: false, text: (err ? err.message : 'no answer') + (first ? ' - ' + first : '') };
}

const WHYS = ['', 'turn', 'prompt', 'run', 'background'];
// The last line that is JSON, every field the right type - else null. Pure.
function parseHostWork(stdout) {
    const lines = String(stdout || '').split(/\r?\n/).map(s => s.trim()).filter(s => s.startsWith('{'));
    if (!lines.length) return null;
    let o;
    try { o = JSON.parse(lines[lines.length - 1]); } catch (e) { return null; }
    if (!o || !Number.isInteger(o.hostPid) || typeof o.known !== 'boolean' || !Array.isArray(o.chats)) return null;
    for (const c of o.chats) {
        if (!c || typeof c.sessionId !== 'string' || !WHYS.includes(c.why) || typeof c.written !== 'boolean') return null;
        if (!(c.file === null || typeof c.file === 'string')) return null;
    }
    return o;
}

// One look at this window's chats: the script's verdict, parsed, or null
// when it could not be had - no scripts in the tool folder, no PowerShell,
// or no answer within timing.look. Through the tool folder's loader, as
// Show it's check is; replaced by the tests through the exports.
function hostWork(hostPid) {
    const io = ext()._overlayIo;
    const loader = path.join(ext()._toolFolder(), setup.LOADER);
    if (!io.exists(loader)) { log('the chats here cannot be checked: no ' + loader); return Promise.resolve(null); }
    const exe = io.powershell(io.platform());
    if (!exe) { log('the chats here cannot be checked: no PowerShell found'); return Promise.resolve(null); }
    const args = setup._psArgs(loader, hostWorkCommand(hostPid, ext()._claudeHome()));
    return new Promise(resolve => {
        cp.execFile(exe, args, { timeout: timing.look, windowsHide: true, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
            const v = parseHostWork(stdout);
            if (err || !v) {
                const f = lookFailure(err, stdout, stderr);
                lookWhy = f.old ? 'old' : 'failed';
                log('checking the chats here failed: ' + f.text);
            }
            else lookWhy = '';
            resolve(v);
        });
    });
}

// The chats of a look that are working, the chat a queued run has just
// written (except) left out of the last minute's writes alone. Pure.
function workingOf(v, except) {
    const skip = String(except || '').toLowerCase();
    return ((v && v.chats) || []).filter(c => c.why || (c.written && c.sessionId.toLowerCase() !== skip));
}

// Their titles, as the picker reads them, each with what keeps it working:
// three at most, then how many more.
async function namesOf(chats) {
    const x = ext();
    const one = async (c) => {
        let title = '';
        try {
            if (c.file) {
                const st = await fs.promises.stat(c.file);
                const d = await x._describeChat({ file: c.file, dir: path.dirname(c.file), sid: c.sessionId, size: st.size, mtimeMs: st.mtimeMs });
                title = d && !d.skip ? d.title : '';
            }
        } catch (e) { }
        return (title ? '"' + x._formatTitle(title, 40) + '"' : 'a chat (' + c.sessionId.slice(0, 8) + ')') + (WHY[c.why] || '');
    };
    const shown = await Promise.all(chats.slice(0, 3).map(one));
    const more = chats.length - shown.length;
    if (more > 0) return shown.join(', ') + ' and ' + more + ' more';
    return shown.length > 1 ? shown.slice(0, -1).join(', ') + ' and ' + shown[shown.length - 1] : shown.join('');
}

// The window reloaded, which loads the version installed. Never rejects. One
// that works ends this extension host, and this with it; one that failed -
// refused, or no answer within the command's time - is said, with a try
// again, not only logged: the wait is over by then, and the user would take
// the new version for loaded. The question is not waited on.
async function restart(why, v) {
    log('reloading this window to load the new version: ' + why);
    try { await ext()._command(RESTART); return 'restarted'; }
    catch (e) {
        log('reloading the window failed: ' + (e && e.message));
        Promise.resolve(vs().window.showWarningMessage(texts.failed(v), AGAIN, LATER))
            .then(pick => { if (pick === AGAIN) return restart('asked again after it failed', v); })
            .catch(err => log('the reload question failed: ' + (err && err.message)));
        return 'failed';
    }
}

// A new install noticed - by VS Code's event, or its list on disk changing.
// Said once per install; a wait already going just takes the new version.
async function checkInstall() {
    if (!running) return 'none';
    const found = installedNow();
    const api = apiNow();
    const key = installKey(running, found) || installKey(running, api);
    if (!key || said.has(key)) return 'none';
    said.add(key);
    const v = key.split('@')[0];
    log('installed: ' + v + (key.includes('@') ? ' again, with other files' : '') + ' - this window still runs ' + running.version);
    if (wait) { wait.version = v; if (wait.item) wait.item.tooltip = texts.waitTip(v); return 'waiting'; }
    return notice(v);
}

// The notice: what a restart would stop, and when to have it.
async function notice(v) {
    const win = vs().window;
    const look = await module.exports._hostWork(process.pid);
    let busy = look ? workingOf(look) : null;
    if (busy && !busy.length) {
        const pick = await win.showInformationMessage(texts.short(v), GO, LATER);
        if (pick !== GO) { log('restart for ' + v + ': later'); return 'later'; }
        // the notice may have sat for hours: looked at again
        const again = await module.exports._hostWork(process.pid);
        busy = again ? workingOf(again) : null;
        if (busy && !busy.length) return restart('asked, nothing working', v);
    }
    const msg = busy ? texts.long(v, busy.length, await namesOf(busy)) : texts.unknown(v);
    const pick = await win.showWarningMessage(msg, WAIT, NOW, LATER);
    if (pick === NOW) return restart('asked now, ' + (busy ? busy.length + ' working' : 'not checked'), v);
    if (pick === WAIT) return startWait(v);
    log('restart for ' + v + ': later');
    return 'later';
}

function setText(t) { if (wait && wait.item) wait.item.text = t; }

// Restart when they're idle: a status-bar item that cancels it, and a look
// every poll. Kept in memory only - the window closing ends it, and nothing
// happens then.
function startWait(v) {
    stopWait();
    const win = vs().window;
    let item = null;
    if (win.createStatusBarItem) {
        const left = vs().StatusBarAlignment ? vs().StatusBarAlignment.Left : 1;
        item = win.createStatusBarItem(left, 0);
        item.text = texts.checking;
        item.tooltip = texts.waitTip(v);
        item.command = CANCEL;
        item.show();
    }
    wait = { version: v, item, since: null, busy: -1, looking: false, timer: null };
    wait.timer = setInterval(() => { poll().catch(e => log('the restart\'s look failed: ' + (e && e.message))); }, timing.poll);
    log('restart for ' + v + ': when the chats here are idle');
    poll().catch(e => log('the restart\'s look failed: ' + (e && e.message)));
    return 'waiting';
}

function stopWait() {
    const w = wait;
    wait = null;
    if (!w) return;
    clearInterval(w.timer);
    try { if (w.item) w.item.dispose(); } catch (e) { }
}

// The last word before the reload, read here and not through a PowerShell:
// the look it follows is seconds old - the scripts load, the registry is
// read, then the processes and the transcripts - and a turn begun in that
// time would be cut off. The registry read again: a chat of the look that
// is busy or waiting now, or a claude of VS Code's started since the look
// began, or a transcript of the look written since - and it is not idle.
// What moved, as a few words, or ''. Replaced by the tests.
function movedSince(v, since) {
    const x = ext();
    let reg;
    try { reg = x._readRegistry(x._claudeHome(), Date.now()); } catch (e) { return 'the registry could not be read'; }
    const mine = new Set(((v && v.chats) || []).map(c => c.sessionId));
    for (const [sid, es] of reg) {
        const on = es.find(e => e.status === 'busy' || e.status === 'waiting');
        if (on && mine.has(sid)) return sid.slice(0, 8) + ' ' + on.status;
        const fresh = es.find(e => Number(e.startedAt) >= since && (!e.entrypoint || e.entrypoint === 'claude-vscode') && (!e.kind || e.kind === 'interactive'));
        if (fresh && !mine.has(sid)) return sid.slice(0, 8) + ' started';
    }
    for (const c of (v && v.chats) || []) {
        if (!c.file) continue;
        try { if (fs.statSync(c.file).mtimeMs > since) return c.sessionId.slice(0, 8) + ' written'; } catch (e) { }
    }
    return '';
}

// One look while waiting. Every chat idle - no turn, no prompt, no
// background work, no queued run going in, nothing written in the last
// minute - for idleFor straight, the registry read once more (movedSince),
// and the window reloads. A look that fails counts as working: the wait
// starts over.
async function poll() {
    const w = wait;
    if (!w || w.looking) return 'skipped';
    w.looking = true;
    const lookAt = Date.now();
    let v;
    try { v = await module.exports._hostWork(process.pid); } finally { w.looking = false; }
    if (wait !== w) return 'cancelled';
    const now = module.exports._now();
    if (!v) { w.since = null; w.busy = -1; setText(lookWhy === 'old' ? texts.tooOld : texts.unchecked); return 'unknown'; }
    const busy = workingOf(v);
    if (busy.length) {
        if (busy.length !== w.busy) log('restart waits: ' + busy.length + ' working here (' + busy.map(c => c.sessionId.slice(0, 8) + ' ' + (c.why || 'written')).join(', ') + ')');
        w.since = null;
        w.busy = busy.length;
        setText(texts.waiting(busy.length));
        return 'working';
    }
    w.busy = 0;
    if (w.since === null) w.since = now;
    if (now - w.since >= timing.idleFor) {
        const moved = module.exports._movedSince(v, lookAt);
        if (moved) {
            log('reload waits: ' + moved + ' since the look');
            w.since = null;
            setText(texts.settling);
            return 'working';
        }
        const ver = w.version;
        const idle = Math.round((now - w.since) / 1000);
        stopWait();
        return restart('every chat here idle for ' + idle + ' s', ver);
    }
    setText(texts.settling);
    return 'idle';
}

function cancel() {
    if (!wait) return 'none';
    const v = wait.version;
    stopWait();
    log('restart for ' + v + ': cancelled');
    vs().window.showInformationMessage(texts.cancelled(v));
    return 'cancelled';
}

// Before chatq reloads the window - by itself, or on a plain Reload clicked
// on a word that may be minutes old - the chats of this window are looked at
// again: none working, it reloads; some working, it says which, and reloads
// only on Reload anyway. By itself (auto), a look that fails is a no, as
// every unjudged word is; on a click it reloads, as it did before. except:
// the chat a queued run has just written, which reads live for a minute.
// named: a chat an earlier warning named, whose work the Reload anyway
// clicked on it accepted - left out whatever it does; any other chat
// working is asked about again.
// The question is not waited on: it may sit unanswered for hours, and a
// caller on the show queue would hold every show behind it. Never rejects:
// 'reloaded', or 'asked' - Reload anyway reloads later.
async function guardReload(auto, except, named) {
    const x = ext();
    const v = await module.exports._hostWork(process.pid);
    const skip = String(named || '').toLowerCase();
    const busy = v ? workingOf(v, except).filter(c => !skip || c.sessionId.toLowerCase() !== skip) : null;
    if ((busy && !busy.length) || (!busy && !auto)) { await x._reloadWindow(); return 'reloaded'; }
    let msg = texts.reloadUnchecked;
    try { if (busy) msg = texts.reloadBusy(busy.length, await namesOf(busy)); } catch (e) { }
    log('reload ' + (auto ? 'by itself' : 'asked for') + ': ' + (busy ? busy.length + ' chats working here' : 'the chats here not checked') + ' - asking');
    const go = 'Reload anyway';
    Promise.resolve(vs().window.showWarningMessage(msg, go, 'Not now'))
        .then(pick => { if (pick === go) return x._reloadWindow(); log('reload: not now'); })
        .catch(e => log('the reload question failed: ' + (e && e.message)));
    return 'asked';
}

// At activation: what runs, the command the status bar's item runs, and the
// two ways a new install is noticed - VS Code's event, and its list on disk,
// which a command-line install rewrites whether or not the event comes.
function activate(context) {
    noteRunning(context);
    const vscode = vs();
    const sub = (d) => { if (d && context.subscriptions) context.subscriptions.push(d); };
    if (vscode.commands && vscode.commands.registerCommand) sub(vscode.commands.registerCommand(CANCEL, () => cancel()));
    const go = () => { checkInstall().catch(e => log('the new install check failed: ' + (e && e.message))); };
    if (vscode.extensions && typeof vscode.extensions.onDidChange === 'function') sub(vscode.extensions.onDidChange(go));
    if (running.dir && fs.existsSync(path.join(running.dir, 'extensions.json'))) {
        const f = path.join(running.dir, 'extensions.json');
        fs.watchFile(f, { interval: timing.watch }, go);
        sub({ dispose: () => fs.unwatchFile(f, go) });
    }
    sub({ dispose: () => stopWait() });
}

module.exports = {
    activate, texts, timing, ID, WAIT, NOW, GO, LATER, AGAIN, CANCEL, RESTART, TOO_OLD,
    _readInstalled: readInstalled, _entryOf: entryOf, _installKey: installKey, _noteRunning: noteRunning,
    _parseHostWork: parseHostWork, _hostWorkCommand: hostWorkCommand, _lookFailure: lookFailure, _workingOf: workingOf, _namesOf: namesOf,
    _checkInstall: checkInstall, _notice: notice, _startWait: startWait, _stopWait: stopWait, _poll: poll, _cancel: cancel,
    _guardReload: guardReload, _said: said, _wait: () => wait, _running: () => running,
    // replaced by the tests, which start no PowerShell and keep their own clock
    _hostWork: hostWork, _movedSince: movedSince, _now: () => Date.now()
};
