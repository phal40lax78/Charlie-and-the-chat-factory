const vscode = require('vscode');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const cp = require('child_process');
const setup = require('./setup');
// a new version installed, and every reload chatq asks for, held to the
// chats this window runs (safe-restart.js)
const safe = require('./safe-restart');
// a queued run's live view: its rows, and the page they go into
const watch = require('./watch');

const SEEN_KEY = 'chatManagerReload.lastSeenId';
const OPEN_SEEN_KEY = 'chatManagerReload.lastOpenId';
const GUID = /^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/;

// Every wait, in one place, so the tests can set them all to nothing.
//   retry          before asking the Claude extension a second time
//   tabSettle      for an editor tab to appear, or to go
//   tabRecount     a second look, for a tab slow to appear
//   startupOpen    a window just opened: the Claude extension starting
//   openMaxAge     an open request older than this is not acted on
//   judgedMaxAge   the script's away and busy verdict older than this is not
//                  trusted for acting without asking
//   verdictTimeout Show it's check, at most
//   commandTimeout a command run from the show queue, at most; 0 is no limit
//   pickBudget     the picker's titles read before it lists the chats; the
//                  rest are filled in as they come
//   labelBudget    labelShared's read of the folders' chats, at most; one
//                  not done by then answers shared. 0 is no limit
//   anywayFresh    a Reload anyway clicked within this of its warning reloads
//                  at once; later, the window's chats are looked at again
//   runPoll        data/run-state, and a watch panel's log and job file,
//                  looked at this often
//   runCheck       a handover's job looked at this often besides, for a
//                  watcher that died mid-run and wrote nothing more
//   graceSeconds   Show it's second check waits this long for the chat's
//                  process to leave by itself, its tab closed, before it
//                  ends it; the check itself gets 20 s more
//   ackWindow      a handover answered later than this after run-state's
//                  write is not answered at all: the watcher reads answers
//                  for ChatHandoverAckSeconds (3 s), and this keeps within it
//   restoreHold    a window just started puts no chat back for this long
//                  where the watch panel of its run is not here yet: the
//                  serializer may still bring it back
//   tabHold        ... and at most this long, from the first look past
//                  restoreHold that finds the run over, where a watch tab of
//                  its run is kept but not brought back (viewComing)
//   carryWait      a chat chatq opens again takes Ultracode and its session's
//                  level only into a launch of it within this (armCarry)
//   putBackWait    a chat whose run ended with it not opened again - asked,
//                  or its live view left up - takes them into a launch of it
//                  within this, however it is opened (armPutBack)
//   restartHold    after an extension-host restart, Show it's second check
//                  ends nothing on a new tab for this long: Claude Code
//                  reopens most tabs it lost by itself then, though not
//                  all (restartHeld, tabGrew)
//   procFresh      a registry entry's process start and parent, once read
//                  (procFacts), kept this long
//   procTimeout    that read, at most; one not done by then knows nothing
const timing = {
    retry: 2500, tabSettle: 400, tabRecount: 1500, startupOpen: 2000,
    openMaxAge: 120000, judgedMaxAge: 20000, verdictTimeout: 20000,
    commandTimeout: 15000, pickBudget: 250, labelBudget: 1500, anywayFresh: 60000,
    runPoll: 1000, runCheck: 5000, graceSeconds: 8, ackWindow: 2750, restoreHold: 4000,
    tabHold: 600000, carryWait: 60000, putBackWait: 30 * 60000, restartHold: 30000,
    procFresh: 10000, procTimeout: 5000
};

// chatManager.* first. For one release the old extension's chatManagerReload.*
// is read where the new one is unset, so nobody's settings are lost in the move.
function isSet(i) { return !!i && [i.globalValue, i.workspaceValue, i.workspaceFolderValue].some(v => v !== undefined); }
function setting(key) {
    const now = vscode.workspace.getConfiguration('chatManager');
    if (isSet(now.inspect && now.inspect(key))) return now.get(key);
    const old = vscode.workspace.getConfiguration('chatManagerReload');
    if (isSet(old.inspect && old.inspect(key))) return old.get(key);
    return now.get(key);
}

const DEFAULT_FOLDER = () => path.join(os.homedir(), 'Tools', 'Charlie-and-the-chat-factory');
function expandHome(p) { return path.normalize(String(p).replace(/^~(?=$|[\\/])/, os.homedir())); }

// the old extension's signalFile, as it was set, else ''
function oldSignalFile() {
    const old = vscode.workspace.getConfiguration('chatManagerReload');
    return isSet(old.inspect && old.inspect('signalFile')) ? String(old.get('signalFile') || '').trim() : '';
}

// The tool folder: the scripts, and data/ beside them - and where setup.js
// writes, so only a full path is taken. chatManager.folder; else the folder
// whose data/reload-request the old signalFile named, and only a path of
// that shape; else ~/Tools/Charlie-and-the-chat-factory. What is set and refused is
// logged once.
let refusedLogged = false;
function toolFolder() {
    const refuse = (what) => {
        if (!refusedLogged) { refusedLogged = true; log(what + ' - using ' + DEFAULT_FOLDER()); }
        return DEFAULT_FOLDER();
    };
    const set = String(setting('folder') || '').trim();
    if (set) {
        const f = expandHome(set);
        return path.isAbsolute(f) ? f : refuse('chatManager.folder is not a full path: ' + set);
    }
    const sig = oldSignalFile();
    if (sig) {
        const f = expandHome(sig);
        if (path.isAbsolute(f) && /[\\/]data[\\/]reload-request$/i.test(f)) return path.dirname(path.dirname(f));
        return refuse('chatManagerReload.signalFile does not name a data/reload-request: ' + sig);
    }
    return DEFAULT_FOLDER();
}

// Charlie-and-the-chat-factory writes data/reload-request after chatrm deletes a chat,
// and after chatq runs a queued prompt into a chat this window still holds;
// data/open-request when the overlay's open chip is clicked. A chat is shown
// in an editor tab of its own where the Claude Code extension can do it - its
// open command, which no outside process can run - and otherwise a run's
// window reloads, as it did before.
function signalFiles() {
    return [path.join(toolFolder(), 'data', 'reload-request')];
}

// open-request sits beside reload-request, in the same data/
function openFiles() {
    return signalFiles().map(f => path.join(path.dirname(f), 'open-request'));
}

let channel = null;
function log(s) {
    try {
        if (!channel && vscode.window.createOutputChannel) channel = vscode.window.createOutputChannel('Charlie and the Chat Factory - Claude Code & Codex');
        if (channel) channel.appendLine(new Date().toISOString() + '  ' + s);
    } catch (e) { }
}

function readRequest(file) {
    let raw;
    try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { return null; }
    // PowerShell's Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell
    // and JSON.parse rejects it outright. The script writes without one, but a
    // file edited by hand may well have it.
    if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
    try { return JSON.parse(raw); } catch (e) { return null; }
}

// A signal file's requests, oldest first. The file is one request, the
// newest, as it always was - an older extension, or the old
// chatManagerReload one, reads it so and misses only what it always missed -
// and the script carries the few it wrote just before under earlier
// (Save-ChatRequest, src/chatrm.ps1): two requests inside one poll, a
// delete right after a queued run, used to leave the first overwritten
// unseen. A file from an older script has no earlier, and is one request.
function requestsOf(file) {
    const top = readRequest(file);
    if (!top || typeof top !== 'object' || Array.isArray(top)) return [];
    const own = Object.assign({}, top);
    delete own.earlier;
    const earlier = Array.isArray(top.earlier) ? top.earlier.filter(r => r && typeof r === 'object' && !Array.isArray(r) && r.id) : [];
    return earlier.concat([own]);
}

// The ids a window has taken, per file. globalState keeps the last few,
// shared by every window and kept over a reload, beside the one id the key
// always held - a window still on an older extension reads that one. And
// this host's own, which no other window's write of the list can drop.
const SEEN_LIST = { [SEEN_KEY]: 'chatManager.seenIds', [OPEN_SEEN_KEY]: 'chatManager.openSeenIds' };
const SEEN_KEEP = 16;
const seenHere = new WeakMap();
function seenSet(context) {
    let s = seenHere.get(context);
    if (!s) { s = new Set(); seenHere.set(context, s); }
    return s;
}
function wasSeen(context, key, id) {
    if (seenSet(context).has(key + ' ' + id) || context.globalState.get(key) === id) return true;
    const list = context.globalState.get(SEEN_LIST[key]);
    return Array.isArray(list) && list.includes(id);
}
// marked here at once, before any await: a poll that fires meanwhile finds it
function markSeen(context, key, id) {
    seenSet(context).add(key + ' ' + id);
    const list = context.globalState.get(SEEN_LIST[key]);
    const next = (Array.isArray(list) ? list.filter(x => x !== id) : []).concat([id]).slice(-SEEN_KEEP);
    return Promise.all([context.globalState.update(key, id), context.globalState.update(SEEN_LIST[key], next)]);
}
// The first look after an update from an extension that kept the one id:
// no list yet, and a request carried under that id's was the old
// extension's to take - it took it, a poll before, or missed it as it
// always did. Taken as seen, every request up to that id, which the file
// holds in the order they were written; without this a request acted on
// just before the update, carried under a later one, was asked again - a
// delete under 10 minutes old, an open under openMaxAge. An id the file no
// longer holds is older than all it does, so nothing in it was seen.
function seedSeen(context, key, reqs) {
    if (context.globalState.get(SEEN_LIST[key]) !== undefined) return;
    const legacy = context.globalState.get(key);
    const i = legacy ? reqs.findIndex(r => r.id === legacy) : -1;
    if (i < 0) return;
    const ids = reqs.slice(0, i + 1).map(r => r.id).filter(Boolean);
    for (const id of ids) seenSet(context).add(key + ' ' + id);
    context.globalState.update(SEEN_LIST[key], ids.slice(-SEEN_KEEP));
}

function isGuid(s) { return typeof s === 'string' && GUID.test(s); }

// Every window watches the same file, so each decides for itself whether the
// request was for its own workspace. This is what makes the prompt land in the
// right window - something an outside process could not work out at all.
function isMine(req) {
    if (!req.cwd) return true;                  // nothing to match on
    const folders = vscode.workspace.workspaceFolders || [];
    if (!folders.length) return false;
    const want = path.resolve(req.cwd).toLowerCase();
    return folders.some(f => {
        const have = path.resolve(f.uri.fsPath).toLowerCase();
        return want === have || want.startsWith(have + path.sep);
    });
}

// The script judges one folder's chats, the job's own. A window whose only
// folder is that one holds nothing it did not judge; a multi-root window, or
// one opened on a parent folder, may hold a chat elsewhere mid-answer - so
// only the first may reload without asking.
function isExactlyMine(req) {
    const folders = vscode.workspace.workspaceFolders || [];
    if (!req.cwd || folders.length !== 1) return false;
    return path.resolve(req.cwd).toLowerCase() === path.resolve(folders[0].uri.fsPath).toLowerCase();
}

// Is that process still there? A window that closed took its pid with it.
function alive(pid) {
    try { process.kill(pid, 0); return true; } catch (e) { return !!e && e.code === 'EPERM'; }
}

// Which windows a request is for. The script names the Code.exe each window's
// claude process of the chat runs under (hostPids) - this extension host is
// that process, as the Claude extension's is - so a window that held the chat
// knows it for certain. Failing that, by folder: the window on it for a run,
// and for an open only one on exactly it, since an open always gets a window.
function isTarget(req, aliveFn) {
    const check = aliveFn || (p => module.exports._alive(p));
    const hp = (Array.isArray(req.hostPids) ? req.hostPids : []).filter(p => Number.isInteger(p) && p > 0).filter(check);
    if (hp.length) return hp.includes(process.pid);
    // the chip's watch is an open too: it always gets a window
    return req.kind === 'open' || req.kind === 'watch' ? isExactlyMine(req) : isMine(req);
}

function hasClaude() {
    return !!(vscode.extensions && vscode.extensions.getExtension && vscode.extensions.getExtension('anthropic.claude-code'));
}

// on unless turned off: unset reads as on
function showFresh() {
    return setting('showFresh') !== false;
}

function ageOf(req) {
    const at = Date.parse(req.at || '');
    return at ? Date.now() - at : Infinity;
}

function name(req) { return req.title ? '"' + req.title + '"' : 'a chat'; }

const texts = {
    terminal: req => name(req) + ' is also open in a terminal, so it was not shown here. Type there, or close it first.',
    couldNotEnd: req => 'chatq could not end the old process of ' + name(req) + ', so only a reload shows the run.',
    staleTab: req => name(req) + ' is already open in a tab that could not be refreshed. Close that tab and open the chat again.',
    noClaude: req => 'The Claude Code extension is not in this window, so ' + name(req) + ' cannot be opened here.',
    notOpened: req => name(req) + ' could not be opened. Chat Manager: Show log has the details.',
    twoPlaces: req => name(req) + ' was also open in this window outside its tabs - most likely the side bar - so it now runs in two places. ' +
        (req.oldProcess === 'live' ? 'Type in the tab, and close the side bar\'s copy, which is idle.' : 'Type in the tab, and close the other.'),
    working: req => name(req) + ' is working outside the tabs here - most likely in the side bar - so it was not opened as a tab: that would start a second copy of it mid-answer. Click open again once it finishes.',
    pickTerminal: req => name(req) + ' is open in a terminal, so it was not opened here. Type there, or close it first.',
    pickWorking: req => name(req) + ' is working elsewhere in VS Code - another window or the side bar - so it was not opened here: a second copy would start mid-answer. Open it once it finishes.',
    pickElsewhere: req => name(req) + ' is open elsewhere in VS Code - another window or the side bar. A second copy here splits the chat: each copy answers on its own.',
    // the picker, where the chat's process tells its window (whereOf)
    pickWorkingHere: req => name(req) + ' is working in this window outside its tabs - most likely the side bar - so it was not opened as a tab: a second copy would start mid-answer. Open it once it finishes.',
    pickSideBar: req => name(req) + ' is open in this window outside its tabs - most likely the side bar. A second copy in a tab splits the chat: each copy answers on its own.',
    pickThere: req => name(req) + ' is open in another VS Code window. A second copy here splits the chat: each copy answers on its own.',
    pickHanded: req => name(req) + ' is in another VS Code window, so it was handed to that window, which brings its tab forward - or says why not. Switch to that window: it cannot be raised from here.',
    pickNotHanded: req => name(req) + ' is in another VS Code window, and could not be handed to it. Chat Manager: Show log has the details.',
    noBoard: 'chatq has not written its queue board (data/queue.md) yet. chatqlist -Board in a terminal writes it.',
    pickMoved: req => name(req) + ' is no longer only in that other window, so nothing was done. Pick it again to see where it is now.',
    sideBarStale: req => name(req) + ' was also open in this window outside its tabs - most likely the side bar. That copy is stale now and can be closed: the tab shows the run.',
    // Show it's new tab moments after an extension-host restart: maybe one
    // Claude Code reopened by itself, so nothing was ended (restartHeld)
    restartNew: req => name(req) + ' is in a new tab. VS Code restarted its extensions a moment ago, and Claude Code reopens the tabs it lost then, so nothing of the chat was ended. If a copy of it is also open outside the tabs - the side bar - that copy is stale and can be closed.',
    unlistable: req => name(req) + ' was started by a claude -p run, and Claude Code leaves such chats out of its lists, so no tab can show it. Open it in a terminal instead?',
    hiddenBusy: req => name(req) + ' is out of Claude Code\'s chat list for now, and working somewhere, so a tab here would open blank. Open it once it finishes: it is listed again then.',
    unmended: req => name(req) + ' is out of Claude Code\'s chat list, and could not be put back, so a tab here would open blank. Chat Manager: Show log has the details.',
    terminalBusy: req => name(req) + ' began to run meanwhile - in a terminal, VS Code or a queued prompt - so it was not opened in a terminal too. Try again once it is closed or finished.',
    // Either kind of print-mode run reads the same to the check and to the
    // registry, and only a queued one's end brings a request that offers
    // the chat again - so no such offer is promised
    running: req => 'A print-mode run (a queued prompt, or claude -p) is going into ' + name(req) + ' right now, so it was left as it is. Open it once that run finishes.',
    pickRunning: req => 'A print-mode run (a queued prompt, or claude -p) is going into ' + name(req) + ' right now, so it was not opened here: a second copy would start mid-run. Open it once that run finishes.',
    // Show it's check found another chat of the workspace working, this one
    // not: the reload that shows the run would cut the other one off
    ranBusy: req => 'A queued prompt ran in ' + name(req) + ', which this window still has open, but another chat in this workspace is still working and reloading now would cut it off. Reload once it finishes to show the run.',
    checking: '$(sync~spin) Checking the chats in this window...',
    oldThere: 'The old "VS Code chat manager - reload" extension is still installed. Both would act on the same requests, so this one waits until the old one is gone.',
    oldGone: 'The old extension is uninstalled. Reload the window to finish.',
    oldStuck: 'The old extension could not be uninstalled from here. Uninstall "VS Code chat manager - reload" in the Extensions view.',
    autoStartAsk: 'Start the overlay by itself, with every shell and VS Code window?',
    autoStartOn: 'The overlay now starts by itself with every shell and VS Code window.',
    autoStartOff: stopped => 'The overlay no longer starts by itself' + (stopped === 'closed' ? ', and was closed.' :
        stopped === 'not yet' ? '. It was asked to close and has not yet - data/logs/overlay.log may say why.' : '.'),
    autoStartNoPanel: 'The overlay is Windows and macOS only, so there is nothing to start here.',
    autoStartNoLoader: folder => 'The overlay\'s scripts are not in ' + folder + ', so its start could not be set. Chat Manager: Install terminal commands puts them there.',
    autoStartFailed: 'The overlay\'s start could not be set. Chat Manager: Show log has the details.'
};
// the offer after a run auto-continue made - "auto": true in the request -
// Show it, or where the chat cannot be shown fresh, a reload
texts.ranAuto = (req, reload) => 'chatq continued ' + name(req) + ' after the usage limit reset, and this window still has it open. ' +
    (reload ? 'Reload to show it?' : 'Show it?');
// a queued run and the chat's tab here (the handover): rs is data/run-state,
// which names the job's seq and the chat's title
const seqOf = rs => '#' + (rs && rs.seq !== undefined && rs.seq !== null ? rs.seq : '?');
Object.assign(texts, {
    handoverStale: rs => 'A queued prompt (' + seqOf(rs) + ') is running in ' + name(rs) + ', and its old view here is stale - do not type there until the run ends. Its live view is open beside it.',
    besideStale: rs => 'A queued prompt (' + seqOf(rs) + ') is running in ' + name(rs) + ' beside its tab here, which was left open: a background command it started still runs there. That view is stale - do not type there until the run ends.',
    inUse: rs => seqOf(rs) + ' is waiting to go into ' + name(rs) + ' - it goes once you leave that tab.',
    handedBack: rs => seqOf(rs) + ' is running in ' + name(rs) + ' - its tab was closed so nothing forks. It opens again when the run ends.',
    // Show it's first check: idle in a process of another window, opened
    // there after the run - so it shows the run already
    liveElsewhere: req => name(req) + ' is open in another VS Code window, so it was not shown here: a second copy would split the chat. Look there, or close it there first.',
    ranClosed: rs => seqOf(rs) + ' ended in ' + name(rs) + ', whose tab it had closed. Open it again?',
    noRun: 'No queued prompt is running right now.',
    cancelAsk: rs => 'Stop ' + seqOf(rs) + ' in ' + name(rs) + '? What it has done so far stays in the chat.',
    cancelFailed: rs => seqOf(rs) + ' could not be stopped from here. Chat Manager: Show log has the details.',
    // a chat chatq closed and opened again, and what the old process had
    // that the new one lacks (lostByReopen): Ultracode, a session-only
    // level, or both. prefilled: the new tab's input box holds lost.prefill
    // - else, where no pre-fill could go, or a carry into the new process
    // (armCarry) missed, the commands are named to type.
    // /effort takes one setting at a time, so with both lost the level is
    // left for after, typed: typed, it leaves Ultracode on, where the tab's
    // effort menu would save a level up to xhigh as every new session's
    // default. key: what sends a prompt there (sayLost)
    settingsLost: (req, lost, prefilled, key) => {
        const k = key || 'Enter';
        const lvl = lost.effort ? 'effort ' + lost.effort : '';
        const both = lost.ultracode && !!lvl;
        const then = ' type /effort ' + lost.effort + ' and press ' + k + ': typed, it leaves Ultracode on.';
        const s = name(req) + ' was opened again without ' + (both ? 'Ultracode and ' + lvl : lost.ultracode ? 'Ultracode' : lvl) +
            ': Claude Code keeps ' + (both ? 'them' : 'it') + ' only in the process that ended with the old tab. ';
        const to = lost.ultracode ? 'switch Ultracode back on' : 'set ' + lvl + ' again';
        if (prefilled) return s + 'Its input box holds ' + lost.prefill + ' - press ' + k + ' there to ' + to + '.' + (both ? ' Then' + then : '');
        return s + 'Type ' + lost.prefill + ' in its input box and press ' + k + ' to ' + to + (both ? ', then' + then : '.');
    }
});

// What to say, by what happened. A request written before 'kind' existed is a
// delete - that was the only thing that wrote one. 'busy' is the script's
// judgement, made as it wrote the request, that a chat in this workspace was
// still working - a turn in flight, a permission prompt, or a workflow or
// background agent that has not reported back. A reload now would cut it off.
// A run's chat that can be shown fresh (fresh) is offered Show it; one held
// working, a reload for later; otherwise the reload, as before.
function message(req, fresh) {
    const what = name(req);
    if (req.kind === 'ran') {
        if (fresh === undefined) fresh = canShowFresh(req);
        if (fresh && req.oldProcess === 'other') return texts.terminal(req);
        if (fresh && req.oldProcess === 'held') {
            return 'A queued prompt ran in ' + what + ' while that chat was working in this window. Reload once it finishes to show the run.';
        }
        if (req.auto === true) return texts.ranAuto(req, !fresh);
        if (fresh) return 'A queued prompt ran in ' + what + ', which this window still has open. Show it?';
        return 'A queued prompt ran in ' + what + ', which this window still has open. Reload to show it?';
    }
    // Claude Code lists no chat claude -p started (S37): a reload would cut
    // off whatever works here and show nothing, so none is offered
    if (req.kind === 'new') {
        return 'A new chat, ' + what + ', was started in this folder by chatq. Claude Code leaves chats a claude -p run started out of its list, so no reload shows it: the overlay\'s open chip offers it in a terminal.';
    }
    const done = (req.kind === 'archived' ? 'Archived ' : 'Deleted ') + what + '.';
    if (req.busy === true) {
        return done + ' A chat in this workspace is still working, and reloading now would cut it off - reload once it finishes.';
    }
    return done + ' Reload to refresh the chat list?';
}

// a request from a script that names the chat, with the Claude extension here
// to show it, and the setting on
function canShowFresh(req) {
    return !!req.sessionId && showFresh() && hasClaude();
}

// A queued run can finish at 3 a.m. with another chat in this window
// mid-answer, and a reload would lose that answer - or while you are typing
// in it; and a tab that opens by itself lands under someone's cursor. So it
// acts by itself only on the script's word, given as the run ended, that
// nobody had used the PC for a while (away) and no other chat in the folder
// was working (busy false), only in a window that is exactly that folder, and
// only while that word is fresh (ageMs). Unjudged is a no. The new chat a
// queued run started is never reloaded for by itself: the script judges
// neither for it. A delete reloads by itself only with autoReload, and never
// while a chat works.
function reloadsItself(req, autoReload, afterRun, exact, ageMs) {
    if (req.kind === 'ran') {
        return afterRun !== false && req.away === true && req.busy === false && exact === true &&
            !(ageMs > timing.judgedMaxAge);
    }
    if (req.kind === 'new') return false;
    return req.busy !== true && !!autoReload;
}

// After a run, what this window does by itself for a chat it can show fresh,
// on top of reloadsItself:
//   'show it'  the chat is open here on an idle process (live): Show it, as
//              if clicked - its check ends that process, and the chat's tab
//              is closed and opened again from disk. At the PC too, and while
//              other chats work: it touches this chat's tab alone. Left
//              stale, a message typed into that tab went on from the tab's
//              own memory, and the chat forked - the run's turn on a branch
//              the tab never showed (2026-09-27, a reply from the phone).
//   'tab'      nobody at the PC, and nothing holds the chat now (the run's
//              check ended its process, or none had it): a tab, even while
//              another chat works, since a tab cuts none off.
// null for the rest: a chat held working, a terminal's, one whose window
// cannot be told (no host pids, as on a Mac), a word past judgedMaxAge,
// autoReloadAfterRun off, or - for 'tab' - a window not exactly its folder.
function showsItself(req, afterRun, exact, ageMs) {
    if (req.kind !== 'ran' || afterRun === false || ageMs > timing.judgedMaxAge) return null;
    if (req.oldProcess === 'live' && hostPidsOf(req).includes(process.pid)) return 'show it';
    if (req.away === true && exact === true && (req.oldProcess === 'ended' || req.oldProcess === 'none')) return 'tab';
    return null;
}

// How to show a run's chat, from the script's verdict on it. The overlay's
// open chip does not come here: it always opens a tab (openTab).
//   tab       a fresh editor tab of its own, which touches no other chat -
//             Reload Webviews once did it where you read it, and left two
//             views each resuming the chat with a process of its own
//   reload    the whole window - its process is still there (held working,
//             left running, or not checked), or the chat cannot be shown
//             fresh here at all
//   none      a terminal holds it: nothing, or there would be two writers
function plan(req, verdict, ctx) {
    if (!ctx.fresh || !ctx.claude || !req.sessionId) return 'reload';
    const v = verdict || {};
    if (v.oldProcess === 'other') return 'none';
    if (v.oldProcess === 'held' || v.oldProcess === 'live' || v.oldProcess === 'kept') return 'reload';
    // no process holds it: the tab loads it from disk
    return 'tab';
}

// The label VS Code shows on a Claude tab, from the chat's title, as the
// Claude extension shortens it: no title is "Claude Code", and one over 25
// characters is cut to 24 and an ellipsis. Pure.
function claudeTabLabel(title) {
    const t = String(title || '');
    if (!t) return 'Claude Code';
    return t.length > 25 ? t.substring(0, 24) + '\u2026' : t;
}

// Does a tab's label read as the chat of that title - as it is, or as the
// Claude extension shortens it? A chat of no title never does: every untitled
// Claude tab reads "Claude Code". Pure.
function labelIsChat(title, label) {
    return !!title && (label === title || label === claudeTabLabel(title));
}

// The one tab among tabs that reads as the chat, else undefined. Two that
// do may be two chats whose titles share their first 24 characters, and a
// chat of no title reads as none: neither is taken for the chat. Pure.
function oneTabOf(title, tabs) {
    const hits = (tabs || []).filter(t => labelIsChat(title, t.label));
    return hits.length === 1 ? hits[0] : undefined;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// A command of another extension that never settles would hold the show
// queue - and every show after it - for good. So what the queue waits on is
// given timing.commandTimeout (0: no limit), then logged and taken as failed,
// and the chain always moves on.
function bounded(p, what) {
    const ms = timing.commandTimeout;
    if (!(ms > 0)) return Promise.resolve(p);
    let timer;
    const late = new Promise((resolve, reject) => {
        timer = setTimeout(() => {
            log(what + ' timed out after ' + ms + ' ms');
            const e = new Error(what + ' timed out');
            e.timedOut = true;
            reject(e);
        }, ms);
    });
    return Promise.race([Promise.resolve(p), late]).finally(() => clearTimeout(timer));
}

function command(c, ...args) { return bounded(vscode.commands.executeCommand(c, ...args), c); }

// A chat is opened with the Claude extension's editor.open, not its
// primaryEditor.open. That one makes every panel a "full editor"
// (createPanel's fullEditor, IS_FULL_EDITOR in its webview): no header - no
// title, no Session history, no New session - and an edit to approve shown
// without its diff; the tab keeps it through a reload. editor.open with
// fullEditor false makes the ordinary tab, as a Claude tab's own New
// session does (its new_conversation_tab). Its arguments, 2.1.281 to
// 2.1.284: sessionId, prompt, viewColumn, group, fullEditor, options.
// Given the column primaryEditor.open would pick (claudeColumn) it makes no
// group and locks none, and programmatic 'pin-to-panel' keeps it in a tab
// and leaves claudeCode.preferredLocation alone, which a plain editor.open
// rewrites. An older Claude extension, whose editor.open is not known to
// take them, still gets primaryEditor.open - and so does a later one that
// refuses them (openOnce).
const OPEN = 'claude-vscode.editor.open';
const OPEN_FULL = 'claude-vscode.primaryEditor.open';
const OPEN_SINCE = '2.1.281';

// The Claude extension's version, or '' when it cannot be read.
function claudeVersion() {
    const ext = vscode.extensions && vscode.extensions.getExtension && vscode.extensions.getExtension('anthropic.claude-code');
    return String((ext && ext.packageJSON && ext.packageJSON.version) || '');
}

// Is v at least min? Major, minor and patch compared as numbers; what is no
// version is not. Pure.
function versionAtLeast(v, min) {
    const a = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v || '')), b = /^(\d+)\.(\d+)\.(\d+)/.exec(String(min || ''));
    if (!a || !b) return false;
    for (let i = 1; i <= 3; i++) if (+a[i] !== +b[i]) return +a[i] > +b[i];
    return true;
}

// The column primaryEditor.open picks (pr() in the Claude extension): a
// group of Claude tabs alone, the active one first; else the active group
// when it holds a Claude tab; else the active group, whatever it holds.
function claudeColumn() {
    const g = vscode.window.tabGroups;
    const all = (g && g.all) || [];
    const act = g && g.activeTabGroup;
    const isAct = x => x === act || x.isActive === true;
    const only = all.find(x => isAct(x) && claudeOnly(x.tabs)) || all.find(x => claudeOnly(x.tabs));
    if (only) return only.viewColumn;
    if (act && (act.tabs || []).some(isClaudeTab)) return act.viewColumn;
    return vscode.ViewColumn && vscode.ViewColumn.Active !== undefined ? vscode.ViewColumn.Active : -1;
}

// The command that opens a chat, and its arguments - worked out each time,
// since the groups change between two opens. viewColumn: where it goes, for
// a chat put back where its tab or its watch panel was; else claudeColumn's.
// primaryEditor.open takes no column, and picks its own. prompt: text for
// the new panel's input box - put there, never sent, the focus not taken
// (setInputText in its webview) - given only where the open is sure to make
// a new panel: for a chat that has one, Claude Code only reveals it, and
// says "Your prompt was not applied".
function openCall(sessionId, viewColumn, prompt) {
    if (!versionAtLeast(claudeVersion(), OPEN_SINCE)) return prompt ? [OPEN_FULL, sessionId, prompt] : [OPEN_FULL, sessionId];
    const col = viewColumn !== undefined && viewColumn !== null ? viewColumn : claudeColumn();
    return [OPEN, sessionId, prompt || undefined, col, undefined, false, { programmatic: 'pin-to-panel' }];
}

// The Claude extension's own panel, and nothing else: its viewType holds
// claudeVSCodePanel. Other extensions' names hold "claude" too - Cline's
// claude-dev.TabPanelProvider - and one of theirs is never closed, nor
// taken for a chat.
let tabLogged = false;
function isClaudeTab(tab) {
    const ok = !!(tab && tab.input && vscode.TabInputWebview && tab.input instanceof vscode.TabInputWebview &&
        /claudeVSCodePanel/.test(String(tab.input.viewType || '')));
    if (ok && !tabLogged) {
        tabLogged = true;
        log('a Claude tab: viewType ' + tab.input.viewType + ', label ' + tab.label);
    }
    return ok;
}

// This extension's own watch panel. Never a Claude tab - it is never closed
// by a label, nor taken for a chat - but Claude-like for the groups: one
// standing in a group of Claude tabs keeps it theirs (claudeOnly).
function isWatchTab(tab) {
    return !!(tab && tab.input && vscode.TabInputWebview && tab.input instanceof vscode.TabInputWebview &&
        /chatManager\.watch/.test(String(tab.input.viewType || '')));
}

function allTabs() {
    const g = vscode.window.tabGroups;
    if (!g || !g.all) return [];
    return [].concat(...g.all.map(x => x.tabs || []));
}

function activeTab() {
    const g = vscode.window.tabGroups;
    return g && g.activeTabGroup ? g.activeTabGroup.activeTab : undefined;
}

// One open of the chat, as openCall has it now. An editor.open refused -
// not timed out - is followed by primaryEditor.open, as before 0.8.1: a tab
// without its header beats none, should a later Claude extension take
// editor.open's arguments otherwise. Throws what the last command threw.
// viewColumn, prompt: as openCall takes them.
async function openOnce(sessionId, viewColumn, prompt) {
    const [c, ...args] = openCall(sessionId, viewColumn, prompt);
    try { await command(c, ...args); }
    catch (e) {
        log(c + ' failed: ' + (e && e.message));
        if (c !== OPEN || (e && e.timedOut)) throw e;
        try { await (prompt ? command(OPEN_FULL, sessionId, prompt) : command(OPEN_FULL, sessionId)); }
        catch (e2) { log(OPEN_FULL + ' failed: ' + (e2 && e2.message)); throw e2; }
        log('opened with ' + OPEN_FULL + ' instead - that tab has no header');
    }
}

// Asked twice at most: the Claude extension may still be starting. One that
// timed out is not asked again - the first may yet land, and a second would
// only wait behind it. Each try works the column out again. A prompt goes
// with the retry too: a first try refused made no panel.
async function openWith(sessionId, viewColumn, prompt) {
    for (let i = 0; i < 2; i++) {
        try { await openOnce(sessionId, viewColumn, prompt); return true; }
        catch (e) {
            if (e && e.timedOut) return false;
            if (i === 0) await sleep(timing.retry);
        }
    }
    return false;
}

// Did a Claude tab appear that was not among before? Not always ours: from
// Claude Code 2.1.284, after an extension-host restart (not a window
// reload), it reopens a tab it lost by itself. Such a tab comes with the
// default label, as ours would, so it cannot be told apart - Show it ends
// nothing on a new tab within restartHold of a restart (restartHeld).
// Claude Code's watch for lost tabs (2.1.286) has no deadline of its own,
// though: a lost tab is replaced only once it is the selected tab of its
// group, 5 s (10 s on a first start) after that, and one whose chat is
// still held elsewhere is tried again, while the window is focused, up to
// every 60 s for as long as it is held. A reopen past restartHold is left
// (FUTURE_WORK.md: "A tab Claude Code reopens late").
function tabGrew(before) {
    const now = allTabs().filter(isClaudeTab);
    return now.length > before.length || now.some(t => !before.includes(t));
}

// What started this extension host, by the test Claude Code itself makes
// (2.1.285: its workspaceState's lastActivationSessionId):
// vscode.env.sessionId is new with each window start and reload, and kept
// by an extension-host restart - Developer: Restart Extension Host, or the
// Extensions view's Restart Extensions after an update. saved: the id the
// last activation here wrote. 'restart' (the same id), 'reload' (another:
// a reload, or the window's start), 'unknown' (none saved - this
// extension's first start in the workspace, which an update's restart may
// be) or 'untracked' (VS Code gives the placeholder, telemetry off: Claude
// Code then reopens nothing either). Pure.
const HOST_KEY = 'chatManager.lastActivationSessionId';
function hostStartOf(saved, now) {
    if (typeof now !== 'string' || !now || now === 'someValue.sessionId') return 'untracked';
    if (typeof saved !== 'string' || !saved) return 'unknown';
    return saved === now ? 'restart' : 'reload';
}

// This activation's start, as hostStartOf reads it, into runClock - and
// its id written for the next. A workspaceState that cannot be written
// leaves the next start 'reload' or 'unknown': said, nothing more.
function noteHostStart(context) {
    const ws = context && context.workspaceState;
    const now = vscode.env ? vscode.env.sessionId : undefined;
    runClock.hostStart = hostStartOf(ws && ws.get ? ws.get(HOST_KEY) : undefined, now);
    log('this extension host: ' + runClock.hostStart);
    if (!ws || !ws.update || runClock.hostStart === 'untracked') return runClock.hostStart;
    try { Promise.resolve(ws.update(HOST_KEY, now)).catch(e => log('the window\'s session id could not be kept: ' + (e && e.message))); }
    catch (e) { log('the window\'s session id could not be kept: ' + (e && e.message)); }
    return runClock.hostStart;
}

// Within restartHold of an activation that may be a restart - 'unknown'
// too, as Claude Code itself counts it: a tab that comes up now may be one
// it reopened by itself, not the one an open made. Most such reopens come
// then, a lost tab in front being replaced 5-10 s after the start; one
// behind others, or held elsewhere, can come later, and is not covered
// (tabGrew).
function restartHeld(now) {
    return (runClock.hostStart === 'restart' || runClock.hostStart === 'unknown') && runClock.activatedAt > 0 &&
        (now === undefined ? Date.now() : now) - runClock.activatedAt < timing.restartHold;
}

// Looked at twice, after tabSettle and again after tabRecount: a new panel
// can be slow to show.
async function tabAppeared(before) {
    if (tabGrew(before)) return true;
    await sleep(timing.tabRecount);
    return tabGrew(before);
}

// A group of Claude tabs alone. One holding any other editor is the user's
// own arrangement. A watch panel counts as a Claude tab here: it stands in
// for one while a queued prompt runs, and the group stays Claude's - where
// the next chat opens, and what may be unlocked. Pure.
function claudeOnly(tabs) {
    const all = Array.isArray(tabs) ? tabs : [];
    return all.length > 0 && all.every(t => isClaudeTab(t) || isWatchTab(t));
}

// claudeCode.lockEditorGroups set true on purpose, in any scope: the lock is
// then the user's own choice. Unset, it is on by default, and only that is
// undone.
function lockChosen() {
    const c = vscode.workspace.getConfiguration('claudeCode');
    const i = c && c.inspect ? c.inspect('lockEditorGroups') : null;
    return !!i && [i.globalValue, i.workspaceValue, i.workspaceFolderValue,
        i.globalLanguageValue, i.workspaceLanguageValue, i.workspaceFolderLanguageValue].some(v => v === true);
}

// The chat's tab once shown: a Claude tab that was not among before, for a
// new or reopened one - the one of its label where more came - else the one
// in front when it reads as the chat. Undefined when none is sure.
function chatTab(title, before, how) {
    const a = activeTab();
    const front = a && isClaudeTab(a) && labelIsChat(title, a.label) ? a : undefined;
    if (how === 'revealed') return front;
    const grew = allTabs().filter(isClaudeTab).filter(t => !(before || []).includes(t));
    if (grew.length === 1) return grew[0];
    return oneTabOf(title, grew) || (grew.includes(a) ? a : front);
}

function sameGroup(a, b) {
    return !!a && !!b && (a === b || (a.viewColumn !== undefined && a.viewColumn === b.viewColumn));
}

// The Claude extension locks the group it makes for its tabs
// (claudeCode.lockEditorGroups, on by default), and a chat opened here lands
// in such a group - so the next file opened goes to another group, or a new
// one. The group unlocked is the one holding the chat's tab, and only while
// it is the active group - the command acts on that one, whichever it is -
// and holds Claude tabs alone; a mixed one is the user's own arrangement.
// The lock set true on purpose is left too. Unlocking a group that is not
// locked does nothing. Never throws.
async function unlockClaudeGroup(title, before, how) {
    try {
        if (lockChosen()) { log('group left locked: claudeCode.lockEditorGroups is set true'); return 'chosen'; }
        const g = vscode.window.tabGroups && vscode.window.tabGroups.activeTabGroup;
        if (!g) { log('group left as it is: no active group'); return 'no group'; }
        const t = chatTab(title, before, how);
        if (!t) { log('group left as it is: no tab here is surely the chat\'s'); return 'no tab'; }
        if (!sameGroup(t.group, g)) { log('group left as it is: the chat\'s tab is not in the active group'); return 'not active'; }
        if (!claudeOnly(g.tabs)) { log('group left as it is: it holds other editors'); return 'mixed'; }
        await command('workbench.action.unlockEditorGroup');
        return 'unlocked';
    } catch (e) {
        log('unlocking the group failed: ' + (e && e.message));
        return 'failed';
    }
}

// The chat in an editor tab of its own. The Claude extension makes a new
// panel, loaded from disk, when the chat has none - but only reveals one it
// has, stale. So a tab that was there already, came to the front and carries
// the chat's title - as it is, or as the Claude extension shortens it - is
// closed and opened again; anything less certain is left alone, and you are
// told. Two chats whose titles share their first 24 characters carry the
// same shortened label, so a tab with a twin among the Claude tabs is never
// taken as sure: closing the wrong one would cut off the other chat, maybe
// mid-answer.
async function showTab(req) {
    // listed first, as any open is; one never listed is offered a terminal,
    // and one out of the list while it works is left for later
    const listed = await ensureListed(req);
    if (listed === 'unlistable') {
        offerTerminal(req).catch(e => log('the terminal offer failed: ' + (e && e.message)));
        return 'unlistable';
    }
    if (listed === 'held' || listed === 'unmended') {
        vscode.window.showInformationMessage((listed === 'held' ? texts.hiddenBusy : texts.unmended)(req));
        return listed;
    }
    const before = allTabs().filter(isClaudeTab);
    const beforeActive = activeTab();
    const up = async (how) => { await unlockClaudeGroup(req.title, before, how); return how; };
    await openOnce(req.sessionId);
    await sleep(timing.tabSettle);
    if (await tabAppeared(before)) return up('new');
    let t = activeTab();
    // The front tab did not change: the chat's tab was in front already, or
    // its new one is slow to come. One more look before anything is closed.
    if (t && t === beforeActive) {
        await sleep(timing.tabRecount);
        if (tabGrew(before)) return up('new');
        t = activeTab();
    }
    const label = req.title;
    const twin = !!t && before.some(x => x !== t && x.label === t.label);
    const sure = t && before.includes(t) && isClaudeTab(t) && labelIsChat(label, t.label) && !twin;
    // a lone tab of the label may still be another chat's, of the same title
    // or the same first 24 characters, with no tab of this one here at all
    const shared = !!sure && await labelShared(label, req.cwd, req.sessionId, req.home);
    if (!sure || shared) {
        log('not closed: active tab ' + (t ? t.label : '(none)') + (twin ? ', another Claude tab of that label' : '') +
            (shared ? ', another chat of its folder has that label' : '') + ', chat ' + label);
        vscode.window.showInformationMessage(texts.staleTab(req));
        return 'stale';
    }
    // the last look, right before anything is closed: a tab that came
    // meanwhile is the chat's new one, and the one in front is not its
    if (tabGrew(before)) return up('new');
    await bounded(vscode.window.tabGroups.close(t), 'closing the tab');
    await sleep(timing.tabSettle);
    // its tab closed, so this open makes a new panel: what the old process
    // alone had goes into its new process, or else its input box
    const lost = await lostByReopen(req);
    const carrying = carryFor(req, lost);
    await openOnce(req.sessionId, undefined, (lost && lost.prefill) || undefined);
    // for the new tab to be there when its group is looked for
    await sleep(timing.tabSettle);
    await up('reopened');
    sayLost(req, lost, true, carrying);
    return 'reopened';
}

function hostPidsOf(req) { return Array.isArray(req.hostPids) ? req.hostPids : []; }

// --- chats Claude Code leaves out of its lists -----------------------------
// Claude Code (2.1.281 to 2.1.283 at least: _j in its extension, v5o in its
// CLI) takes a chat for one an SDK started, and leaves it out of every
// session list, when the first "entrypoint" in the transcript's first 64 KB -
// else, with none there, the last one in its last 64 KB - is sdk-cli, sdk-ts
// or sdk-py. Such a chat cannot be restored into a tab either: its webview
// declines, and starts a blank chat. chatq's runs were claude -p, which
// writes sdk-cli, so a chat whose first prompt was a pasted screenshot - 64
// KB of base64 and no entrypoint - fell out of the list after one queued
// prompt or phone reply, and a new chat chatq started was never in it. The
// watcher mends a chat as its run ends (Repair-ChatListed in
// src/live-chats.ps1, the same rule and the same line); these mend what is
// still out as a chat is opened - one hidden before, or whose run was cut
// short.
const CLAUDE_SPAN = 65536;
const SDK_ENTRYPOINTS = new Set(['sdk-cli', 'sdk-ts', 'sdk-py']);

// A JSON string's text from from, the index after its opening quote: [text,
// the index of its closing quote], or null where the text ends first. Pure.
function jsonStringAt(text, from) {
    for (let i = from; i < text.length; i++) {
        if (text[i] === '\\') { i++; continue; }
        if (text[i] !== '"') continue;
        let v = text.slice(from, i);
        if (v.includes('\\')) { try { v = JSON.parse('"' + v + '"'); } catch (e) { } }
        return [v, i];
    }
    return null;
}

// The first "entrypoint" value in text, or with last the last one, found as
// Claude Code finds it: by its key, with or without a space after the
// colon - where the first is wanted, the form without one is looked for
// first, wherever the other stands. Undefined for none. Pure.
function entrypointIn(text, last) {
    const keys = ['"entrypoint":"', '"entrypoint": "'];
    let found, at = -1;
    for (const k of keys) {
        for (let from = 0; ;) {
            const i = text.indexOf(k, from);
            if (i < 0) break;
            const v = jsonStringAt(text, i + k.length);
            if (!v) break;
            if (!last) return v[0];
            if (i > at) { found = v[0]; at = i; }
            from = v[1] + 1;
        }
    }
    return found;
}

// Why Claude Code leaves a chat out of its lists, by its transcript's first
// and last 64 KB: 'head' - its head says an SDK started it, which nothing
// added at the end changes; 'tail' - its head names no entrypoint and its
// tail's last is an SDK's, which one line more mends; '' - it is listed.
// Claude Code's other test, a daemon's sessionKind, is none of chatq's
// doing and left out. Pure.
function unlistedWhy(head, tail) {
    const h = entrypointIn(head, false);
    if (h !== undefined) return SDK_ENTRYPOINTS.has(h) ? 'head' : '';
    const t = entrypointIn(tail, true);
    return t !== undefined && SDK_ENTRYPOINTS.has(t) ? 'tail' : '';
}

// A transcript's first and last 64 KB, read as Claude Code reads them - the
// tail is the head where the file is no bigger - else null.
async function headAndTail(file) {
    let fh;
    try { fh = await fsp.open(file, 'r'); } catch (e) { return null; }
    try {
        const size = (await fh.stat()).size;
        const head = await readSpan(fh, 0, CLAUDE_SPAN);
        const tail = size > CLAUDE_SPAN ? await readSpan(fh, size - CLAUDE_SPAN, CLAUDE_SPAN) : head;
        return { head, tail };
    } catch (e) {
        return null;
    } finally {
        try { await fh.close(); } catch (e) { }
    }
}

// The line that lists a chat again: a record of chatq's own type, which
// Claude Code's loaders pass over as they pass over any type they do not
// know (spike S37), carrying the entrypoint of a VS Code panel - the one
// about to open it. No timestamp: chatq's index takes a chat's last
// activity from the last one in its tail, and this line is none. Byte for
// byte Get-ChatListedLine's (src/live-chats.ps1). Pure.
function listedLine(sid) {
    return JSON.stringify({ type: 'chatq-listed', entrypoint: 'claude-vscode', sessionId: sid }) + '\n';
}

// A chat's transcript: the one the picker listed, or the script found -
// taken only as <id>.jsonl, so a request names no other file to write to -
// else <id>.jsonl in its folder's project folder of its Claude home. Null
// when there is none.
async function transcriptOf(req) {
    if (req.file && path.basename(String(req.file)).toLowerCase() === String(req.sessionId).toLowerCase() + '.jsonl') return String(req.file);
    const dir = req.cwd ? await projectDir(req.home || claudeHome(), req.cwd) : null;
    return dir ? path.join(dir, req.sessionId + '.jsonl') : null;
}

// Before a chat is opened in a tab. One Claude Code leaves out by its tail
// alone is listed again by a line at its end, as Claude Code's own rename
// adds a custom-title line there, beside a process or not - but not while
// one may be writing to it: busy or waiting - a claude -p going into it
// reads busy, its registry kind interactive as Claude Code 2.1.283 writes
// it - or of a kind that is not interactive ('held'). An idle one writes
// nothing. The file keeps its write time: the line is no activity, and
// chatq judges a chat written in the last minute as working - unless
// something else wrote meanwhile, whose time is never taken back. One its
// head leaves out can never be listed ('unlistable'), and one whose line
// could not be written stays out ('unmended'). None of the three is
// opened: each would only make a blank tab. Where the transcript is not
// found or not read, the open goes ahead as it would have. 'listed',
// 'relisted', 'unlistable', 'held', 'unmended' or 'unknown'. Never throws.
async function ensureListed(req) {
    const sid = String(req.sessionId || '');
    let file, ht, why;
    try {
        file = await transcriptOf(req);
        ht = file ? await headAndTail(file) : null;
        if (!ht) return 'unknown';
        why = unlistedWhy(ht.head, ht.tail);
    } catch (e) {
        log('open ' + sid.slice(0, 8) + ': its transcript could not be read: ' + (e && e.message));
        return 'unknown';
    }
    if (!why) return 'listed';
    if (why === 'head') { log('open ' + sid.slice(0, 8) + ': Claude Code leaves it out of its lists - its first record is an SDK\'s'); return 'unlistable'; }
    try {
        const writing = (readRegistry(req.home || claudeHome(), Date.now()).get(sid) || [])
            .some(e => (e.kind && e.kind !== 'interactive') || e.status === 'busy' || e.status === 'waiting');
        if (writing) {
            log('open ' + sid.slice(0, 8) + ': left out of Claude Code\'s lists, and a process is writing to it - not mended, not opened');
            return 'held';
        }
        // Opened as Claude Code's rename opens it: to append, never to make
        // a file - one gone meanwhile is not written back as a stub - and
        // an empty one left alone. A line of its own, even where the last
        // one lacks its end.
        const line = Buffer.from((ht.tail.endsWith('\n') ? '' : '\n') + listedLine(sid), 'utf8');
        const fh = await fsp.open(file, fs.constants.O_WRONLY | fs.constants.O_APPEND);
        let was;
        try {
            was = await fh.stat();
            if (!was.isFile() || was.size === 0) throw new Error('not a transcript to write to');
            await fh.appendFile(line);
        } finally {
            try { await fh.close(); } catch (e) { }
        }
        // nothing else wrote meanwhile: its write time as it was - and
        // looked at once more, so a write in that instant keeps a time of now
        try {
            const size = async () => (await fsp.stat(file)).size;
            if (await size() === was.size + line.length) {
                await fsp.utimes(file, was.atime, was.mtime);
                if (await size() !== was.size + line.length) await fsp.utimes(file, new Date(), new Date());
            }
        } catch (e) { log('open ' + sid.slice(0, 8) + ': its write time not put back: ' + (e && e.message)); }
        log('open ' + sid.slice(0, 8) + ': listed again - Claude Code had left it out, an SDK run\'s record last in it');
        return 'relisted';
    } catch (e) {
        log('open ' + sid.slice(0, 8) + ': left out of Claude Code\'s lists, and mending it failed: ' + (e && e.message) + ' - not opened');
        return 'unmended';
    }
}

// --- Ultracode and effort, lost by a reopen ---------------------------------
// Two settings live only in the running claude process, so a tab chatq
// closes and opens again starts without them: Ultracode, which nothing
// saves, and an effort level set for the session only - max always, which
// settings cannot hold, and any other level whose /effort said "(this
// session only)". A level the tab's effort menu picked (low to xhigh), or
// one /effort saved, comes back by itself: nothing lost. The transcript
// says which, walked back from its end record by record (effortLine's
// kinds). A subagent's records are never the chat's, and a claude -p run's
// - an SDK's entrypoint, chatq's runs among them - count only as notices
// and compactions, for the reason below.
//
// Ultracode. Claude Code writes a notice - an ultra_effort_enter or
// ultra_effort_exit attachment - with a prompt, and only where the state
// differs from the latest notice in the chain it has loaded: an enter where
// Ultracode is on and that notice is no enter, an exit where it is off and
// that notice is an enter. So since the last prompt the user typed, the
// chat's own notice or an /effort answer is the word - a run's there is
// only the run's. That prompt came with no notice, so it had the state of
// the nearest notice before it, a run's too: Claude Code's look back does
// not ask whose a notice is, so the exit a queued run writes as it starts
// is what the chat's next prompt was judged against. The chain starts at
// the last compaction, so a compaction met first means no notice was in
// sight: off - but for a prompt within 5 s after it, queued while /compact
// ran and judged on the chain before, where one typed afresh comes 8 s or
// more after; a second compaction ends it all the same. The file's start
// reached with no notice at all: off where a prompt was found; else, or
// with the budget reached first, unknown.
//
// The level. An assistant record names the level its turn ran at
// ("effort"), and the latest turn a prompt of the user's started ran at the
// session's - by its first record: a skill may change it later on. A turn
// anything else started - a task's notice, say - does not count. max there
// is lost on a reopen, as only a session holds it. A lower one is lost only
// where the last /effort before that turn set that same level for this
// session only; after any other - saved, auto, another level - it came
// back by itself, or the effort menu picked it, which saves it. An /effort
// since that turn began is the word on its own.
//
// What counts may sit far from the end (c303a4d5: line 11 of 756), so the
// file is read backwards in chunks, and given up on past a budget - a 20 MB
// transcript must not hold a show up.
const sessionIo = { chunk: 1024 * 1024, budget: 16 * 1024 * 1024 };
const EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'];

// What an /effort answer says: { ultracode: true|false } where it switched
// Ultracode or named its state, { set: level|null } where it set a level -
// the level where it holds for this session only, null where it was saved,
// is auto or is the environment's: nothing to put back. {} where it says
// neither: a refusal, an error, the help. version: the record's claude. In
// 2.1.284 Ultracode is a switch of its own, which a level set leaves as it
// is - but over a remote transport, which says so at its end - and a status
// names it while on, so one that does not means off. 2.1.283 tied it to
// xhigh: its /effort ultracode set a level, any other level set - auto too
// - switched it off unsaid, and its status named it only as a level. A
// version that cannot be read is taken for neither. Pure.
function effortSaid(text, version) {
    const t = String(text || '').trim();
    const out = {};
    const known = /^\d+\.\d+\.\d+/.test(String(version || '')), newer = versionAtLeast(version, '2.1.284');
    let m, implied = false;
    if (/^Ultracode on\b/.test(t)) out.ultracode = true;
    else if (/^Ultracode off\b/.test(t)) out.ultracode = false;
    else if (/^Set effort level to ultracode\b/.test(t)) { out.ultracode = true; out.set = null; }
    else if ((m = /^Set effort level to (\w+)( \(this session only\))?/.exec(t)) ||
        (m = /^Effort '[^']*' exceeds the cap for [^;]*; set to '(\w+)' instead( \(this session only\))?/.exec(t))) {
        const l = m[1].toLowerCase() === 'med' ? 'medium' : m[1].toLowerCase();
        out.set = m[2] && EFFORT_LEVELS.includes(l) ? l : null;
        implied = true;
    } else if (/^Effort level set to auto\b/.test(t)) { out.set = null; implied = true; }
    // an environment's level over it: nothing set that a reopen loses, and
    // nothing said of Ultracode
    else if (/^(Effort set to auto|Cleared effort from settings|CLAUDE_CODE_EFFORT_LEVEL=\S* overrides|Not applied: CLAUDE_CODE_EFFORT_LEVEL=)/.test(t)) out.set = null;
    else if (/^(Current effort level: |Effort level: auto\b)/.test(t)) {
        if (/Ultracode on\s*$/.test(t) || /^Current effort level: ultracode\b/.test(t)) out.ultracode = true;
        else if (newer) out.ultracode = false;
    }
    if ('set' in out && !('ultracode' in out)) {
        if (/Ultracode off\s*$/.test(t)) out.ultracode = false;
        else if (implied && known && !newer) out.ultracode = false;
    }
    return out;
}

// A transcript line as the two walks take it (sessionSettingsIn), by its
// kind - undefined for a line of none - and ts its time, NaN where it has
// none:
//   H  a prompt the user typed or pasted, its origin human
//   F  any other user record but a tool's result or a meta one: a task's
//      notice, the interrupted marker, another session's prompt, a slash
//      command, the summary a compaction starts with
//   N  an Ultracode notice: on for an enter; own where no claude -p run's
//   B  a compaction's boundary
//   S  an /effort answer that says something: effortSaid's ultracode, set
//   A  an assistant record, and the level its turn ran at: effort
// Nothing of a subagent's is any, and of a run's - an SDK's entrypoint -
// only N and B are. Parsed whole, so no words quoted in a record, nor
// structure nested in one - a tool call's input - pass for a record. Pure.
function effortLine(line) {
    let o;
    try { o = JSON.parse(line); } catch (e) { return undefined; }
    if (!o || typeof o !== 'object' || o.isSidechain === true) return undefined;
    const own = !SDK_ENTRYPOINTS.has(o.entrypoint), ts = Date.parse(o.timestamp);
    if (o.type === 'attachment' && o.attachment && /^ultra_effort_(enter|exit)$/.test(o.attachment.type)) return { k: 'N', on: o.attachment.type === 'ultra_effort_enter', own, ts };
    if (o.type === 'system' && o.subtype === 'compact_boundary') return { k: 'B', ts };
    if (!own) return undefined;
    if (o.type === 'system' && o.subtype === 'local_command' && typeof o.content === 'string') {
        if (o.commandRun && o.commandRun.command !== 'effort') return undefined;
        const m = /<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/.exec(o.content);
        const s = m ? effortSaid(m[1], o.version) : {};
        return 'ultracode' in s || 'set' in s ? Object.assign({ k: 'S', ts }, s) : undefined;
    }
    if (o.type === 'assistant') return typeof o.effort === 'string' && o.effort ? { k: 'A', effort: o.effort, ts } : undefined;
    if (o.type !== 'user') return undefined;
    const c = o.message && o.message.content;
    if (o.isMeta || (Array.isArray(c) && c.some(x => x && x.type === 'tool_result'))) return undefined;
    return o.origin && o.origin.kind === 'human' && !o.isCompactSummary ? { k: 'H', ts } : { k: 'F', ts };
}

// The chat's own session-only settings, by its transcript: { ultracode:
// true|false|null, effort: level|null } - null where it cannot be told, or
// no level is lost. Both walks of the comment above at once, from the end.
// Only the last sessionIo.budget bytes count, a line where it begins within
// them - nothing before the byte ahead of them is read - and a walk the
// budget stops has not reached the file's start. Chunks cut lines, so a
// line's pieces are carried back until its start is found: the chunk's
// size changes nothing. A line that by now cannot matter - none of the
// words of what is still wanted in it - is not parsed. Both null where
// there is no file, or its read failed. Never throws.
//
// start, where given - { at, ultracode, effort }, processStart's - is the
// launch of the process whose settings are asked for: a record from before
// it is an older process's, whose Ultracode and level died with it, and
// the walks end there, with what that launch was given - nothing, but for
// chatq's own carry. A transcript never says a process began: a chat run
// on 2.1.283 with Ultracode, and opened again two days on, reads as on to
// the end without it.
async function sessionSettingsIn(file, start) {
    let ultracode, effort;              // undefined: not known yet
    let prompt = null, passed = false;  // the last prompt typed; a compaction passed over
    let level, turn;                    // the first level of the turn walked through; that of the latest turn a prompt started
    const at = start && Number.isFinite(start.at) ? start.at : null;
    // the walks at the launch: what it was given, where still not known.
    // Its level as an /effort answer's would be: one a later turn ran at
    // another level was changed since - by the menu, which says nothing
    const began = () => {
        if (ultracode === undefined) ultracode = start.ultracode === true;
        if (effort === undefined) {
            const set = start.effort || null;
            effort = turn === undefined || set === turn ? set : null;
        }
        return true;
    };
    // one record by both walks; true once both are known
    const take = (r) => {
        if (at !== null && r.ts < at) return began();
        if (ultracode === undefined) {
            if (!prompt) {
                if (r.k === 'N' && r.own) ultracode = r.on;
                else if (r.k === 'S' && 'ultracode' in r) ultracode = r.ultracode;
                else if (r.k === 'H') prompt = r;
            } else if (r.k === 'N') ultracode = r.on;
            else if (r.k === 'B') {
                if (!passed && prompt.ts - r.ts >= 0 && prompt.ts - r.ts < 5000) passed = true;
                else ultracode = false;
            }
        }
        if (effort === undefined) {
            if (r.k === 'A') level = r.effort;
            else if (r.k === 'F') level = undefined;
            else if (r.k === 'H') {
                if (level !== undefined && turn === undefined) {
                    turn = level;
                    if (turn === 'max') effort = 'max';
                }
                level = undefined;
            } else if (r.k === 'S' && 'set' in r) effort = turn === undefined ? r.set : r.set === turn ? turn : null;
        }
        return ultracode !== undefined && effort !== undefined;
    };
    // a line, its bytes; past the prompt only notices and compactions count
    // for Ultracode, and past the turn only /effort's answers for the level
    const judge = (b) => {
        if (!b.length) return false;
        if (!(ultracode === undefined && !prompt) && !(effort === undefined && turn === undefined) &&
            !(ultracode === undefined && (b.includes('ultra_effort_') || b.includes('compact_boundary'))) &&
            !(effort === undefined && b.includes('local_command'))) return false;
        const r = effortLine(b.toString('utf8'));
        return r ? take(r) : false;
    };
    let fh;
    try { fh = await fsp.open(file, 'r'); } catch (e) { return { ultracode: null, effort: null }; }
    try {
        const size = (await fh.stat()).size;
        const from = Math.max(0, size - sessionIo.budget), low = Math.max(0, from - 1);
        let pos = size, parts = [], done = false;
        while (pos > low && !done) {
            const n = Math.min(sessionIo.chunk, pos - low);
            pos -= n;
            const b = Buffer.alloc(n);
            if ((await fh.read(b, 0, n, pos)).bytesRead !== n) throw new Error('short read');
            // the lines that end in it, the last first: the first of them
            // takes the pieces carried from the chunks after; what is left
            // before its first newline begins in a chunk before
            let end = n;
            for (let i = b.lastIndexOf(0x0A, end - 1); i >= 0 && !done; i = end > 0 ? b.lastIndexOf(0x0A, end - 1) : -1) {
                done = judge(parts.length ? Buffer.concat([b.subarray(i + 1, end)].concat(parts.reverse())) : b.subarray(i + 1, end));
                parts = [];
                end = i;
            }
            parts.push(b.subarray(0, end));
        }
        if (!done && from === 0) done = judge(Buffer.concat(parts.reverse()));
        // the whole file read, and nothing in it from before the launch: the
        // chat's first process, or its records since began after it
        if (!done && from === 0 && at !== null) began();
        return { ultracode: ultracode !== undefined ? ultracode : from === 0 && prompt ? false : null, effort: effort || null };
    } catch (e) {
        return { ultracode: null, effort: null };
    } finally {
        try { await fh.close(); } catch (e) { }
    }
}

// Was Ultracode on in the chat? sessionSettingsIn's word alone.
async function ultracodeIn(file) { return (await sessionSettingsIn(file)).ultracode; }

// What a reopen of the chat loses, read before the open so the new panel's
// input box can take it: { ultracode, effort, prefill } - prefill the one
// /effort that puts the most back, as /effort takes one setting at a time:
// Ultracode where it was on - the tab's effort menu offers it only at max,
// so it is the one hard to reach - else the session-only level. With
// chatManager.keepSessionSettings on, a local window and the spawn hook in
// place, prefill is null: both go into the new process instead (carryFor,
// before the open), and nothing into its input box. null where nothing is
// lost, or nothing is known. Only what the process the reopen replaces had
// counts: start, where it is known better than processStart knows it - a
// handover's, taken as it closed the tab. Never throws.
async function lostByReopen(req, start) {
    let s = null;
    try {
        const file = await transcriptOf(req);
        s = file ? await module.exports._sessionSettingsIn(file, start || processStart(req.sessionId)) : null;
    } catch (e) { s = null; }
    if (!s || (s.ultracode !== true && !s.effort)) return null;
    const ultracode = s.ultracode === true, effort = s.effort || null;
    if (keepSettings() && carryReaches() && installSpawnHook()) return { ultracode, effort, prefill: null };
    return { ultracode, effort, prefill: ultracode ? '/effort ultracode' : '/effort ' + effort };
}

// After chatq itself closed a chat's tab and opened it again - Show it's
// reopen, a chat put back after a handover - a word on what the new process
// lacks (lostByReopen's lost; null says nothing). prefilled: the open took
// lost.prefill into a new panel's input box. True when said. The key it
// names is the one that sends: with claudeCode.useCtrlEnterToSend on, Enter
// only breaks the line, and a later send would take the command along
// with the next prompt. carrying: carryFor's promise, where both were to
// go into the new process - then nothing is said now, and the promise of
// the word is returned (reportCarry).
function sayLost(req, lost, prefilled, carrying) {
    if (!lost) return false;
    if (carrying) return reportCarry(req, lost, carrying);
    let key = 'Enter';
    try {
        if (vscode.workspace.getConfiguration('claudeCode').get('useCtrlEnterToSend') === true) key = process.platform === 'darwin' ? 'Cmd+Enter' : 'Ctrl+Enter';
    } catch (e) { }
    log('reopened ' + String(req.sessionId || '').slice(0, 8) + ': ' + (lost.ultracode ? 'Ultracode ' : '') + (lost.effort ? 'effort ' + lost.effort + ' ' : '') +
        'lost - said' + (prefilled ? ', ' + lost.prefill + ' in its input box' : ''));
    vscode.window.showInformationMessage(texts.settingsLost(req, lost, !!prefilled, key));
    return true;
}

// --- Ultracode and effort, carried into a reopen ----------------------------
// Rather than leave you to type them, chatq hands the new process what the
// old one alone had, as that process starts. Claude Code's SDK (2.1.284)
// starts every chat's claude through require('child_process').spawn, the
// module's property looked up as it calls, with no launcher of its own, and
// names the chat on the command line as --resume=<id>. This extension runs
// in the same extension host, so a spawn put in that module's place sees
// the launch - and, for a chat chatq armed right before its own open, adds
// --settings {"ultracode":true} and --effort <level>. Nothing else is
// touched: a launch of no armed chat, or of none, goes through as it came,
// and so does one where anything here fails. The settings go inline, so
// nothing is written to disk for them. --effort pins nothing: an /effort
// later still sets another level. A flag the launch names already is left
// as it is - chatq does not merge its own over another's - and said.
//
// One launch takes an arm, and no more: a second launch of the chat - Claude
// Code starting the tab's process again, or the chat opened by hand in the
// side bar - is not chatq's reopen, and gets what it would have. An arm
// goes, too, after timing.carryWait: an open that only revealed a panel
// starts nothing, so without it the chat opened by hand an hour on would
// take it; and a Claude Code that starts claude another way is never seen -
// said once the arm goes, the commands to type. A remote window is never
// armed: its claude starts on the remote host, where no hook here reaches,
// so it keeps the pre-fill, at once, as before (carryReaches).
//
// What to carry is read from the transcript, which never says where a
// process began: Ultracode turned on two days ago, in a process a VS Code
// restart ended, reads as on. So the hook also notes when each chat's
// process was launched here, armed or not, and what chatq put into it -
// the walk stops there (processStart). The hook goes in as chatq starts,
// in a local window with the setting on, so it sees the launches of the
// tabs Claude Code brings back - or the first time a carry is planned,
// where the setting came on later - and stays until deactivate, which
// puts the original back only where the hook is still the module's spawn:
// one another extension put over it later is not undone.
const carryArms = new Map();    // session id -> { ultracode, effort, settle, timer }
const launches = new Map();     // session id -> { at, ultracode, effort }: its latest launch here
let putBackLast = Promise.resolve(null);    // the latest armPutBack, for the tests to wait on
let spawnHook = null;           // { mod, original, wrapper } while in
// the module the hook goes into; when this extension host started - every
// process of a tab in this window began after it; the clock a launch is
// noted by: the tests put their own here
const carryIo = { mod: cp, hostStart: Date.now() - process.uptime() * 1000, now: () => Date.now() };

// When the chat's current process began, and what chatq put into it - the
// bound sessionSettingsIn's walks stop at: its launch as the hook saw it,
// else this extension host's start. A chat's process held by another
// window began who knows when: bound here all the same, as a carry
// missed only leaves the old word, and a stale one turns Ultracode on
// that nobody wanted. Never throws.
function processStart(sessionId) {
    const l = launches.get(String(sessionId || '').toLowerCase());
    return l ? Object.assign({}, l) : { at: carryIo.hostStart, ultracode: false, effort: null };
}

// A processStart kept in a record - a handover's - read back: itself, or
// null for one missing or malformed. Pure.
function validStart(s) {
    if (!s || typeof s !== 'object' || !Number.isFinite(s.at)) return null;
    return { at: s.at, ultracode: s.ultracode === true, effort: EFFORT_LEVELS.includes(s.effort) ? s.effort : null };
}

// on unless turned off: unset reads as on
function keepSettings() {
    return setting('keepSessionSettings') !== false;
}

// A launch the hook can see: a local window's. In a remote one - WSL, SSH,
// a container - chatq, a ui extension, runs here and Claude Code on the
// remote host, which starts claude there: an arm would only leave the box
// empty a minute before the word came. Never throws.
function carryReaches() {
    try { return !(vscode.env && vscode.env.remoteName); } catch (e) { return false; }
}

// The hook in mod (carryIo.mod when none is named). True where it is in:
// the module's spawn is the wrapper once set - a frozen module refuses
// it. Never throws.
function installSpawnHook(mod) {
    const m = mod || carryIo.mod;
    if (spawnHook) return spawnHook.mod === m;
    try {
        const original = m && m.spawn;
        if (typeof original !== 'function') { log('spawn hook: no spawn to hook - nothing carried into a reopen'); return false; }
        const wrapper = function spawn() {
            let a = arguments;
            try { a = carryArgs(arguments) || arguments; } catch (e) { a = arguments; log('spawn hook: ' + (e && e.message) + ' - the launch left as it came'); }
            return original.apply(this, a);
        };
        m.spawn = wrapper;
        if (m.spawn !== wrapper) { log('spawn hook: child_process.spawn could not be replaced - nothing carried into a reopen'); return false; }
        spawnHook = { mod: m, original, wrapper };
        log('spawn hook in: Ultracode and a session-only level go into a chat chatq opens again');
        return true;
    } catch (e) {
        log('spawn hook: ' + (e && e.message) + ' - nothing carried into a reopen');
        return false;
    }
}

// The hook out, every arm dropped unsaid: the window is closing. The
// original put back only where the wrapper is still the module's spawn.
function removeSpawnHook() {
    for (const a of carryArms.values()) clearTimeout(a.timer);
    carryArms.clear();
    const h = spawnHook;
    spawnHook = null;
    if (!h) return 'none';
    try {
        if (h.mod.spawn !== h.wrapper) { log('spawn hook: another hook is over it - left in place, carrying nothing'); return 'covered'; }
        h.mod.spawn = h.original;
        log('spawn hook out');
        return 'removed';
    } catch (e) { return 'failed'; }
}

// A launch's arguments (spawn's own arguments object) with what is armed
// for its chat added, taking the arm: a new list, or null for the launch
// as it came. The chat by --resume=<id>, or --resume and <id>; the command
// is not looked at, so a claudeProcessWrapper in front of claude gets the
// flags too. Added before a -- where there is one, which ends the flags.
// Every launch of a chat is noted in launches, with what went in.
function carryArgs(a) {
    const argv = a[1];
    if (!Array.isArray(argv)) return null;
    let sid = null;
    for (let i = 0; i < argv.length && sid === null; i++) {
        const s = argv[i];
        if (typeof s !== 'string') continue;
        if (s.startsWith('--resume=')) sid = s.slice('--resume='.length);
        else if (s === '--resume' && typeof argv[i + 1] === 'string') sid = argv[i + 1];
    }
    const key = sid && sid.toLowerCase();
    if (!key || !isGuid(key)) return null;
    const noted = { at: carryIo.now(), ultracode: false, effort: null };
    launches.delete(key);
    launches.set(key, noted);
    // the oldest let go past a few hundred: one a window never reopens
    if (launches.size > 500) launches.delete(launches.keys().next().value);
    const arm = carryArms.get(key);
    if (!arm) return null;
    const has = f => argv.some(s => typeof s === 'string' && (s === f || s.startsWith(f + '=')));
    const add = [], got = { ultracode: false, effort: null }, left = [];
    if (arm.ultracode) {
        if (has('--settings')) left.push('Ultracode - the launch has --settings of its own');
        else { add.push('--settings', '{"ultracode":true}'); got.ultracode = true; }
    }
    if (arm.effort) {
        if (has('--effort')) left.push('effort ' + arm.effort + ' - the launch has --effort of its own');
        else { add.push('--effort', arm.effort); got.effort = arm.effort; }
    }
    noted.ultracode = got.ultracode;
    noted.effort = got.effort;
    disarm(key, got);
    log('spawn ' + key.slice(0, 8) + ': ' + (add.length ? 'carried ' + carriedText(got) : 'nothing carried') + (left.length ? '; not carried: ' + left.join('; ') : ''));
    if (!add.length) return null;
    const at = argv.indexOf('--');
    const out = Array.prototype.slice.call(a);
    out[1] = at < 0 ? argv.concat(add) : argv.slice(0, at).concat(add, argv.slice(at));
    return out;
}

function carriedText(got) {
    return [got.ultracode ? 'Ultracode' : '', got.effort ? 'effort ' + got.effort : ''].filter(Boolean).join(', ');
}

// the arm of a chat taken off, its promise settled with what went in
function disarm(key, got) {
    const a = carryArms.get(key);
    if (!a) return;
    carryArms.delete(key);
    clearTimeout(a.timer);
    a.settle(got);
}

// Armed for the chat's next launch: { ultracode, effort } to add. A
// promise of what went in - { ultracode: true|false, effort: level|null } -
// nothing where no launch came within timing.carryWait, or the hook is not
// in. null where a newer arm for the chat took its place: that open - Show
// it's after a handover's, say - owns the word, and a nothing here would
// say the carry missed while the newer launch takes it. wait: how long the
// arm waits, timing.carryWait where none is given.
function armCarry(sessionId, what, wait) {
    const none = { ultracode: false, effort: null };
    const key = String(sessionId || '').toLowerCase();
    const ultracode = !!(what && what.ultracode), effort = (what && what.effort) || null;
    if (!isGuid(key) || (!ultracode && !effort) || !installSpawnHook()) return Promise.resolve(none);
    disarm(key, null);
    const ms = Number.isFinite(wait) ? wait : timing.carryWait;
    return new Promise(settle => {
        const arm = { ultracode, effort, settle, timer: null };
        arm.timer = setTimeout(() => {
            if (carryArms.get(key) !== arm) return;
            carryArms.delete(key);
            log('open ' + key.slice(0, 8) + ': no launch of it within ' + Math.round(ms / 1000) + ' s - nothing carried');
            settle(none);
        }, ms);
        if (arm.timer && arm.timer.unref) arm.timer.unref();
        carryArms.set(key, arm);
    });
}

// A chat whose run ended and which chatq did not open again - asked, or its
// live view left up with Open chat - can still be opened another way: from
// Claude Code's Session history in another tab, or its side bar. That
// launch is the tab the handover took coming back all the same, and chatq's
// own arm, set only right before its own open, never sees it: on 2026-09-30
// a run's end asked, the chat was picked from another tab's Session history
// twelve seconds on, and its new process started without the Ultracode the
// run had kept. So the carry is armed as the run ends, for any launch of
// the chat here within timing.putBackWait - quietly: no launch, nothing was
// opened, so nothing to say; spawn's own line logs one that came. An open
// of chatq's later - Open chat, Show it - arms again and takes it over, and
// an arm already waiting for the chat is left alone. A promise, once the
// arm is set, of { carrying: armCarry's promise }, or null where nothing is
// armed. Never throws.
async function armPutBack(req, start) {
    try {
        const lost = await lostByReopen(req, start);
        const key = String(req.sessionId || '').toLowerCase();
        if (!lost || lost.prefill !== null || carryArms.has(key)) return null;
        log('run ' + key.slice(0, 8) + ' ended, the chat not opened again: ' + carriedText(lost) + ' armed for its next launch here, for ' +
            Math.round(timing.putBackWait / 60000) + ' min');
        return { carrying: armCarry(req.sessionId, lost, timing.putBackWait) };
    } catch (e) {
        log('arming the chat put back failed: ' + (e && e.message));
        return null;
    }
}

// Right before an open that may start the chat's new process: armCarry's
// promise where lostByReopen planned the carry, else null - the pre-fill
// and the word as before. An open that only reveals a tab arms as well: a
// tab kept over a reload and not revived yet may start its process as it
// is shown, and take the carry then; one whose process exited starts
// none, and its word waits for the arm to go.
function carryFor(req, lost) {
    return lost && lost.prefill === null ? armCarry(req.sessionId, lost) : null;
}

// The word on a reopen whose carry was armed, once the launch took it or
// the arm went: all of it in - a line in the log alone; else sayLost for
// what did not go in, to be typed, as for a panel given no prompt. Holds
// no caller: the launch may come seconds on, or never. An arm a newer open
// took over says nothing: that open's word is the one. A promise of
// whether anything was said.
function reportCarry(req, lost, carrying) {
    const sid = String(req.sessionId || '').slice(0, 8);
    return Promise.resolve(carrying).then(got => {
        if (got === null) { log('reopened ' + sid + ': armed again by a newer open - its word, not this one'); return false; }
        got = got || {};
        const left = { ultracode: !!lost.ultracode && got.ultracode !== true, effort: lost.effort && got.effort !== lost.effort ? lost.effort : null };
        if (!left.ultracode && !left.effort) { log('reopened ' + sid + ': ' + carriedText(lost) + ' carried'); return false; }
        left.prefill = left.ultracode ? '/effort ultracode' : '/effort ' + left.effort;
        return sayLost(req, left, false);
    }).catch(e => { log('reopened ' + sid + ': the word on what was carried failed: ' + (e && e.message)); return false; });
}

// Where a terminal's claude comes from: the Claude extension's own, which
// is what it runs itself, else the one on PATH.
function claudeExe() {
    const ext = vscode.extensions && vscode.extensions.getExtension && vscode.extensions.getExtension('anthropic.claude-code');
    if (ext && ext.extensionPath) {
        const f = path.join(ext.extensionPath, 'resources', 'native-binary', process.platform === 'win32' ? 'claude.exe' : 'claude');
        if (module.exports._overlayIo.exists(f)) return f;
    }
    return 'claude';
}

// A chat no tab can show, offered in a terminal instead: claude --resume,
// run as the terminal's own process, so no shell has to read its
// arguments. One offer at a time per chat - a second click while one is
// up asks nothing more. The answer may come minutes later, so what runs
// the chat is read again first: anything running it by then - a terminal,
// a VS Code panel, a queued prompt - and a second process would fork it,
// so none is started. 'terminal', 'not now', 'asked' or 'running'.
const terminalOffers = new Set();
async function offerTerminal(req) {
    const sid = String(req.sessionId || '');
    if (terminalOffers.has(sid)) return 'asked';
    terminalOffers.add(sid);
    let pick;
    try { pick = await vscode.window.showInformationMessage(texts.unlistable(req), 'Open in a terminal', 'Not now'); }
    finally { terminalOffers.delete(sid); }
    if (pick !== 'Open in a terminal') return 'not now';
    if (chatState(readRegistry(req.home || claudeHome(), Date.now()).get(sid)) !== 'closed') {
        vscode.window.showInformationMessage(texts.terminalBusy(req));
        log('open ' + sid.slice(0, 8) + ': not in a terminal - it runs somewhere by now');
        return 'running';
    }
    const opts = { name: 'Claude: ' + (req.title ? formatTitle(req.title, 30) : sid.slice(0, 8)),
        shellPath: claudeExe(), shellArgs: ['--resume', sid] };
    if (req.cwd) opts.cwd = req.cwd;
    if (req.home) opts.env = { CLAUDE_CONFIG_DIR: req.home };
    vscode.window.createTerminal(opts).show();
    log('open ' + sid.slice(0, 8) + ': in a terminal');
    return 'terminal';
}

// The open itself, behind the open chip's guards and the picker's: the
// chat listed where it can be, the open (openCall), a look for a new tab,
// the group unlocked, and a line in the log ending in why. 'new',
// 'revealed', 'failed', 'unlistable', 'held' or 'unmended' - said.
// viewColumn, prompt: as openCall takes them - a prompt only from a caller
// sure no panel of the chat is here.
async function openCore(req, before, why, viewColumn, prompt) {
    let how;
    const listed = await ensureListed(req);
    if (listed === 'unlistable') {
        how = 'unlistable';
        offerTerminal(req).catch(e => log('the terminal offer failed: ' + (e && e.message)));
    } else if (listed === 'held' || listed === 'unmended') {
        how = listed;
        vscode.window.showInformationMessage((listed === 'held' ? texts.hiddenBusy : texts.unmended)(req));
    } else if (!(await openWith(req.sessionId, viewColumn, prompt))) {
        vscode.window.showInformationMessage(texts.notOpened(req));
        how = 'failed';
    } else {
        await sleep(timing.tabSettle);
        how = (await tabAppeared(before)) ? 'new' : 'revealed';
        await unlockClaudeGroup(req.title, before, how);
    }
    log('open ' + (req.sessionId || '').slice(0, 8) + ': ' + how + ' ' + why);
    return how;
}

// The overlay's open chip: the chat in a tab, or the tab already showing it
// brought forward. The chip's script ended nothing, so a tab there already
// is up to date and only revealed - one a run went in beside, whose Show it
// was offered here and not taken, goes Show it's way instead while its
// process idles in this window (checkOpenOne). And the open (openCall)
// never rewrites the Claude extension's preferredLocation setting, as a
// plain editor.open does. It does not look at the side bar, though: a chat
// held there gets a second panel and a second process. Held idle, that is said
// once; held working, it is not opened at all, since the second process
// would start mid-turn.
async function openTab(req) {
    const hp = hostPidsOf(req);
    const sid = (req.sessionId || '').slice(0, 8);
    // A queued prompt going into it now: its live view, never the chat - a
    // tab would load it part way through the run, a second writer beside it
    const run = liveRunFor(req.sessionId);
    if (run) {
        log('open ' + sid + ': #' + run.seq + ' runs into it - its live view instead');
        openWatch(run.jobId, { title: run.title });
        return 'watch';
    }
    // Working in a process of this window - or of one that cannot be told,
    // as on a Mac, where hostPids is empty - with no one tab here reading as
    // it: it works outside the tabs, most likely in the side bar. Twin labels,
    // a label another chat of its folder shares, and a chat of no title read
    // as no tab, so they are left too - a second process is the worse mistake.
    if (req.oldProcess === 'held' && (!hp.length || hp.includes(process.pid)) &&
        (!oneTabOf(req.title, allTabs().filter(isClaudeTab)) || await labelShared(req.title, req.cwd, req.sessionId, req.home))) {
        log('open ' + sid + ': not opened - working here outside the tabs (hostPids ' + (hp.join(',') || 'none') + ')');
        vscode.window.showInformationMessage(texts.working(req));
        return 'working';
    }
    // looked at after the guard, which may have read the folder's chats
    const before = allTabs().filter(isClaudeTab);
    const how = await openCore(req, before, '(oldProcess ' + req.oldProcess + ', hostPids ' + (hp.join(',') || 'none') + ')');
    // A new tab for a chat a process of this window held: the tab was not
    // there before, so that process sits outside any tab here.
    if (how === 'new' && hp.includes(process.pid) && ['live', 'held', 'kept'].includes(req.oldProcess)) {
        vscode.window.showInformationMessage(texts.twoPlaces(req));
    }
    return how;
}

// never rejects: a reload that failed or never came is logged
function reloadWindow() {
    return command('workbench.action.reloadWindow').catch(e => log('reloading the window failed: ' + (e && e.message)));
}

// Reload anyway, clicked on a warning that named what a reload would cut
// off. The warning was the script's word of one folder at the time of the
// request, and it is not modal: clicked within a minute, what it said still
// holds and the window reloads; later - an hour on, say - the window's chats
// are looked at again (guardReload), the chat the warning named left out,
// whose work the click accepted, so any other chat working since is asked
// about by name before it is cut off. shownAt: when the warning went up.
function reloadAnyway(shownAt, named, except) {
    if (safe._now() - shownAt < timing.anywayFresh) return reloadWindow();
    log('Reload anyway clicked ' + Math.round((safe._now() - shownAt) / 1000) + ' s after its warning: the chats here looked at again');
    return safe._guardReload(false, except || null, named || null);
}

// --- a reload asked for, on the overlay too ---------------------------------
// A notice slides into the notification centre after a few seconds, and a
// reload a delete asked for was easy to miss there. So every reload this
// window asks about is also listed in data/reload-pending/<this host's
// pid>.json for as long as its notice is unanswered, and the overlay shows it
// as a banner with reload and later (Add-ChatOverlayReload, src/overlay-
// windows.ps1). The overlay's answer comes back in data/reload-answer/<pid>
// .json: reload is the notice's own button - the same guard, the same Reload
// anyway - and later takes it off the overlay alone, the notice still up
// here. The file goes when the last ask is answered, and with the window: a
// reload starts a new host, so one a crash left names a pid no longer alive,
// which the overlay passes by and the next window here sweeps.
const pendingAsks = new Map();
let askSeq = 0;
// dir: the data folder these go in, the tool folder's unless the tests set
// one - every reload they ask about would reach the real overlay otherwise
const reloadIo = { dir: null };
function pendingDir() { return path.join(reloadIo.dir || dataDir(), 'reload-pending'); }
function answerDir() { return path.join(reloadIo.dir || dataDir(), 'reload-answer'); }
function pendingFile() { return path.join(pendingDir(), process.pid + '.json'); }
function answerFile() { return path.join(answerDir(), process.pid + '.json'); }

// what the overlay calls this window: its workspace, else its folder
function windowName() {
    const f = (vscode.workspace.workspaceFolders || [])[0];
    return String(vscode.workspace.name || (f ? path.basename(f.uri.fsPath) : '') || 'VS Code').replace(/ \(Workspace\)$/, '');
}

// The asks still open, newest last, written whole and moved into place; none
// left, the file goes. Never throws.
// When this host started, as the overlay checks the pid against: taken
// once, as the module loads - process.uptime() stands still while the
// machine sleeps, so worked out later it would drift by every sleep since.
const hostStarted = Math.round(Date.now() - process.uptime() * 1000);
let pendingRetry = null;
function writePending(tries = 0) {
    const f = pendingFile();
    if (pendingRetry) { clearTimeout(pendingRetry); pendingRetry = null; }
    try {
        if (!pendingAsks.size) {
            try { fs.unlinkSync(f); } catch (e) { if (e && e.code !== 'ENOENT') throw e; }
            return;
        }
        fs.mkdirSync(path.dirname(f), { recursive: true });
        const asks = [...pendingAsks.values()].map(a => ({ id: a.id, state: a.state, say: a.say, text: a.text, at: a.at }));
        fs.writeFileSync(f + '.tmp', JSON.stringify({ v: 1, pid: process.pid, started: hostStarted, window: windowName(), asks }));
        fs.renameSync(f + '.tmp', f);
    } catch (e) {
        // held a moment - an antivirus scan, a reader that shares no
        // delete: tried again, or the overlay goes on showing an ask
        // answered, whose answer from there would find nothing open
        log('reload-pending: ' + f + ' could not be written: ' + (e && e.message) + (tries < 5 ? ' - trying again' : ''));
        if (tries < 5) {
            pendingRetry = setTimeout(() => { pendingRetry = null; writePending(tries + 1); }, 500);
            if (pendingRetry.unref) pendingRetry.unref();
        }
    }
}

// The overlay's line for a reload asked about. Pure.
function askSay(req) {
    const t = req && req.title ? '"' + formatTitle(String(req.title), 40) + '"' : 'a chat';
    if (!req || !req.kind || req.kind === 'deleted') return t + ' deleted - the chat list still shows it';
    if (req.kind === 'archived') return t + ' archived - the chat list still shows it';
    if (req.kind === 'ran') return 'a queued prompt ran in ' + t + ' - a reload shows it';
    return 'a reload is waiting';
}

// A reload asked about: the notice - a warning, or not - with go and Not
// now, and the same ask on the overlay (say: its line there, anyway: go
// is Reload anyway). Resolves as the notice does, to what was picked; the
// overlay's reload resolves it to go, its later leaves it to the notice.
function askReload(warn, msg, go, say) {
    const seq = ++askSeq;
    const id = process.pid + '-' + seq + '-' + Date.now().toString(36);
    const shown = warn ? vscode.window.showWarningMessage(msg, go, 'Not now') : vscode.window.showInformationMessage(msg, go, 'Not now');
    return new Promise(resolve => {
        let done = false;
        const finish = (pick) => {
            if (done) return;
            done = true;
            if (pendingAsks.delete(id)) writePending();
            resolve(pick);
        };
        pendingAsks.set(id, {
            id, seq, state: go === 'Reload' ? 'offered' : 'anyway', say: say || '', text: msg, at: Date.now(),
            answer: (a) => {
                if (a === 'reload') { log('reload: ' + go + ', from the overlay'); finish(go); return; }
                // this ask and those before it, which the overlay showed
                // this one over - never one asked since, not seen there yet
                log('reload: later, from the overlay - the notices stay here');
                for (const [k, v] of pendingAsks) if (v.seq <= seq) pendingAsks.delete(k);
                writePending();
            }
        });
        writePending();
        Promise.resolve(shown).then(pick => {
            if (!done) return finish(pick);
            // The overlay answered first, and this notice has no way to be
            // taken down: its button still does what it says - Reload
            // looks at the window's chats as ever, Reload anyway reloads
            if (pick !== go) return;
            log('reload: ' + go + ' on a notice the overlay already answered');
            enqueue(() => go === 'Reload' ? safe._guardReload(false, null) : reloadWindow());
        }, () => finish(undefined));
    });
}

// The overlay answered: data/reload-answer/<pid>.json, { id, answer, at },
// read once and removed. An ask no longer open, or an answer over ten
// minutes old, does nothing.
function onReloadAnswer() {
    const f = answerFile();
    const a = readRequest(f);
    if (!a) return 'none';
    try { fs.unlinkSync(f); } catch (e) { }
    const at = Date.parse(a.at || '');
    const ask = pendingAsks.get(String(a.id || ''));
    if (!ask || !(Date.now() - at < 600000) || !['reload', 'later'].includes(a.answer)) {
        log('reload: an answer from the overlay to no open ask (' + String(a.id || '') + ' ' + String(a.answer || '') + ')');
        return 'stale';
    }
    ask.answer(a.answer);
    return a.answer;
}

// At activation: the files of windows gone - their host's pid not alive -
// taken away, so the overlay never shows one a crash left.
function sweepPending() {
    for (const d of [pendingDir(), answerDir()]) {
        let names;
        try { names = fs.readdirSync(d); } catch (e) { continue; }
        for (const n of names) {
            const m = /^(\d+)\.json(\.tmp)?$/.exec(n);
            if (!m || (Number(m[1]) !== process.pid && module.exports._alive(Number(m[1])))) continue;
            try { fs.unlinkSync(path.join(d, n)); } catch (e) { }
        }
    }
}

// A run's Show it this window offered and nobody took - Not now, or the
// notice left unanswered - its request, by chat. Taken, or run by itself,
// or a newer run's request in (offer), or the tab handed over to a run
// (onHandover), and it goes; gone with the host too, as the stale view is:
// a reload loads every chat from disk. The chip's open of that chat goes
// Show it's way meanwhile (checkOpenOne).
const unshown = new Map();
function unshownKey(sid) { return String(sid || '').toLowerCase(); }
// The runs shown already, by request id - by Show it, or by the chip going
// its way. That run's notice stays in the notification centre, and its
// Show it clicked later would close the fresh tab, end its new process
// after the grace and open it once more: it is passed by instead (offer).
const shownRuns = new Set();
function markShown(req) {
    if (!req || !req.id) return;
    shownRuns.add(req.id);
    while (shownRuns.size > 32) shownRuns.delete(shownRuns.values().next().value);
}

// Every show goes through one chain per window, so two never interleave.
let queue = Promise.resolve();
function enqueue(fn) {
    queue = queue.then(fn).catch(e => log('show failed: ' + (e && e.message)));
    return queue;
}

async function perform(how, req) {
    log(req.kind + ' ' + (req.sessionId || '').slice(0, 8) + ': ' + how);
    switch (how) {
        case 'tab': {
            // A new tab where a process of this window held the chat, or
            // the check ended one, starts a new process: what the old one
            // alone had is read, and armed to go into it, before the open.
            // A reopen in showTab arms again for its own open
            const held = hostPidsOf(req).includes(process.pid);
            const lost = held || req.oldProcess === 'ended' ? await lostByReopen(req) : null;
            const carrying = carryFor(req, lost);
            const r = await showTab(req);
            // A new tab for a chat a process of this window held: its view
            // here was outside the tabs, and the process under it has been
            // ended, so that view is dead. Said once, here.
            if (r === 'new' && held) {
                log(req.kind + ' ' + (req.sessionId || '').slice(0, 8) + ': its old view here was outside the tabs');
                vscode.window.showInformationMessage(texts.sideBarStale(req));
                // the new tab's process is not the one Ultracode or a
                // session-only level was set in. Its open could not be
                // sure of a new panel, so nothing went into its input box
                sayLost(req, lost, false, carrying);
            } else if (r === 'new' && req.oldProcess === 'ended') {
                // the process chatq's check ended was another window's:
                // no view of it here, but a new process all the same
                sayLost(req, lost, false, carrying);
            }
            return r;
        }
        case 'none': vscode.window.showInformationMessage(texts.terminal(req)); return 'none';
        // only a reload the window takes by itself comes here: this
        // window's chats are looked at again first (guardReload)
        case 'reload': return safe._guardReload(true, req.sessionId);
    }
    return how;
}

// Windows PowerShell, where Windows keeps it - the host setup's hosts() puts
// first, without its look on PATH for pwsh
function windowsPowerShell() {
    return path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

// ' and the curly quotes doubled: PowerShell reads all four as a quote
function psQuote(s) {
    return "'" + String(s).replace(/['\u2018-\u201B]/g, m => m + m) + "'";
}

// Show it's check: the script's Show-ChatFresh, which judges the chat and
// the folder, printing one line of JSON. o, what it is asked:
//   judgeOnly      judge, and end nothing (-JudgeOnly): the first check, made
//                  before the chat's tab is closed. Scripts older than it
//                  take no such switch - PowerShell drops it unread - and end
//                  the process anyway; they print no "judged":"only"
//   grace          the second check, the tab closed: the process ended only
//                  if it has not left by itself within this many seconds
//   hostPid        ... and only one of this window's
//   startedBefore  ... started before this (ISO): a tab the first open made
//                  has a process of its own, which is never ended
function verdictCommand(script, req, o) {
    if (!isGuid(req.sessionId)) throw new Error('not a session id: ' + req.sessionId);
    const x = o || {};
    let cmd = "$env:CHATQ_OVERLAY='1'; . " + psQuote(script) + '; $r = @(Show-ChatFresh -Via button -SessionId ' +
        psQuote(req.sessionId) + ' -Cwd ' + psQuote(req.cwd || '');
    if (req.home) cmd += ' -ConfigDir ' + psQuote(req.home);
    if (x.judgeOnly) cmd += ' -JudgeOnly';
    if (x.grace > 0) cmd += ' -GraceSeconds ' + Math.floor(x.grace);
    if (Number.isInteger(x.hostPid) && x.hostPid > 0) cmd += ' -HostPid ' + x.hostPid;
    if (x.startedBefore) cmd += ' -StartedBefore ' + psQuote(x.startedBefore);
    cmd += ')[-1]; [Console]::Out.WriteLine((ConvertTo-ChatFreshVerdict $r))';
    const enc = Buffer.from(cmd, 'utf16le').toString('base64');
    const exe = process.platform === 'win32' ? windowsPowerShell() : 'pwsh';
    return [exe, ['-NoProfile', '-NonInteractive', '-EncodedCommand', enc]];
}

const OLD = ['none', 'ended', 'live', 'held', 'other', 'kept'];
// the last line that is JSON, with every field the right type - else null
function parseVerdict(stdout) {
    const lines = String(stdout || '').split(/\r?\n/).map(s => s.trim()).filter(s => s.startsWith('{'));
    if (!lines.length) return null;
    let o;
    try { o = JSON.parse(lines[lines.length - 1]); } catch (e) { return null; }
    if (!o || typeof o !== 'object') return null;
    if (!(o.busy === null || typeof o.busy === 'boolean')) return null;
    if (!OLD.includes(o.oldProcess) || typeof o.outcome !== 'string') return null;
    if (!Array.isArray(o.hostPids) || !o.hostPids.every(Number.isInteger)) return null;
    return o;
}

// o: as verdictCommand takes it. A check given a grace gets it on top of
// its own time.
function getVerdict(req, file, o) {
    const script = path.join(path.dirname(path.dirname(file)), 'Charlie-and-the-chat-factory.ps1');
    let exe, args;
    try { [exe, args] = verdictCommand(script, req, o); } catch (e) { log(e.message); return Promise.resolve(null); }
    const ms = o && o.grace > 0 ? o.grace * 1000 + 20000 : timing.verdictTimeout;
    return new Promise(resolve => {
        cp.execFile(exe, args, { timeout: ms, windowsHide: true }, (err, stdout) => {
            if (err) log('Show it check failed: ' + err.message);
            resolve(parseVerdict(stdout));
        });
    });
}

// The outcomes of a check that judged the chat. Any other - missing, bad -
// returned before looking at its process at all, so what it says of that
// process is nothing to act on.
const JUDGED = ['ok', 'held', 'other', 'running'];

// Show it: the check, then the chat shown by what it found. The check only
// judges (judgeOnly): a chat open here on an idle process of this window
// (live) has its tab closed first, and the process is ended only if it
// outlives the close (showLive). Ended first, as it once was, the Claude
// extension let go of the tab the moment its process died, and the open
// that followed made a second tab beside the dead one - "Claude Code
// process exited with code 1" (2026-09-28). Busy counts for nothing there:
// this touches the chat's own tab alone. A check from scripts too old to
// judge only has ended the process already ("judged":"only" missing), and
// goes on as before - so does every verdict but live, here or in another
// window alone, which is left there and said. A failed check,
// or one that judged nothing, leaves the verdict to the request's own - a
// fresh tab if the process was ended, else a reload offer; never a tab
// beside a process still running. The request's busy goes with it: another
// chat it found working is still a reason to ask the reload only as anyway.
// A queued prompt going into the chat now leaves it alone: showing it would
// load it part way through - its live view is shown, where it is chatq's.
// The chip's open of a chat whose Show it was not taken comes here too,
// as that run's request, with the chip's own as asOpen (checkOpenOne):
// where Show it would offer a reload - the chat held working since, or a
// check that failed - it goes the chip's ordinary way (openTab) instead,
// with what the check found: a chip never asks to reload.
async function showIt(req, file, asOpen) {
    unshown.delete(unshownKey(req.sessionId));
    const bar = vscode.window.setStatusBarMessage ? vscode.window.setStatusBarMessage(texts.checking) : null;
    let v;
    try { v = await module.exports._getVerdict(req, file, { judgeOnly: true }); }
    finally { if (bar && bar.dispose) bar.dispose(); }
    const sid = (req.sessionId || '').slice(0, 8);
    if (v) log('Show it ' + sid + ': busy ' + v.busy + ', oldProcess ' + v.oldProcess + ', outcome ' + v.outcome + (v.judged === 'only' ? ', judged only' : ''));
    else log('Show it ' + sid + ': the check failed; the request\'s oldProcess ' + req.oldProcess);
    if (v && !JUDGED.includes(v.outcome)) { log('Show it check judged nothing: ' + v.outcome); v = null; }
    if (v && v.outcome === 'running') {
        const run = liveRunFor(req.sessionId);
        if (run) { openWatch(run.jobId, { title: run.title }); return 'watch'; }
        vscode.window.showInformationMessage(texts.running(req));
        return 'running';
    }
    if (v && v.judged === 'only' && v.oldProcess === 'live' && hostPidsOf(v).includes(process.pid) && showFresh() && hasClaude() && req.sessionId) {
        markShown(req);
        return enqueue(() => showLive(req, file));
    }
    // Idle in another window only: the request was this window's by its
    // folder, the chat closed as the run ended, and opened there since - so
    // loaded with the run. Scripts that ended it here would kill a tab that
    // is up to date; a tab here would be a second copy of it. With no window
    // to tell (hostPids empty, as on a Mac) the plan's reload offer stands.
    if (v && v.judged === 'only' && v.oldProcess === 'live' && hostPidsOf(v).length && !hostPidsOf(v).includes(process.pid)) {
        log('Show it ' + sid + ': idle in another window (hostPids ' + (hostPidsOf(v).join(',') || 'none') + ') - not shown here');
        vscode.window.showInformationMessage(texts.liveElsewhere(req));
        return 'elsewhere';
    }
    const verdict = v || { busy: req.busy === true ? true : null, oldProcess: req.oldProcess };
    const how = plan(req, verdict, { fresh: showFresh(), claude: hasClaude() });
    if (asOpen && how === 'reload') {
        const now = v ? Object.assign({}, asOpen, { oldProcess: v.oldProcess, busy: v.busy, hostPids: hostPidsOf(v) }) : asOpen;
        log('open ' + sid + ': not shown Show it\'s way (' + (v ? 'oldProcess ' + v.oldProcess : 'the check failed') + ') - opened as ever');
        return enqueue(() => openTab(now));
    }
    // Held working, or another chat of the folder busy: a reload now cuts it
    // off, so it is asked only as anyway - held, as the offer says it; the
    // chat itself not held, as the other chat's work, which is what a reload
    // would cut off.
    if (how === 'reload' && (verdict.oldProcess === 'held' || verdict.busy === true)) {
        const go = 'Reload anyway';
        const said = verdict.oldProcess === 'held' ? message(Object.assign({}, req, { oldProcess: 'held' }), true) : texts.ranBusy(req);
        const shownAt = safe._now();
        const pick = await askReload(true, said, go, askSay(req));
        // held: the warning named this chat; busy: another chat of its folder,
        // which it did not name, so nothing is left out of a later look
        if (pick === go) return enqueue(() => reloadAnyway(shownAt, verdict.oldProcess === 'held' ? req.sessionId : null, req.sessionId));
        return 'asked';
    }
    if (how === 'reload') {
        const go = 'Reload';
        const pick = await askReload(true, texts.couldNotEnd(req), go, askSay(req));
        // a plain Reload, maybe clicked minutes later: looked at again
        if (pick === go) return enqueue(() => safe._guardReload(false, req.sessionId));
        return 'asked';
    }
    // the windows the check found holding the chat, beside the request's:
    // either may name this one, whose old view then needs a word after
    const had = hostPidsOf(req);
    const shown = v ? Object.assign({}, req, { hostPids: had.concat(hostPidsOf(v).filter(p => !had.includes(p))) }) : req;
    markShown(req);
    return enqueue(() => perform(how, shown));
}

// Is the chat busy or waiting now, by the registry? Read right before a tab
// is closed: a turn begun since the check would be cut off with it.
function workingNow(req) {
    return (readRegistry(req.home || claudeHome(), Date.now()).get(String(req.sessionId || '')) || [])
        .some(e => e.status === 'busy' || e.status === 'waiting');
}

// Show it for a chat open here on an idle process of this window: its tab
// closed, then the process ended if it outlived the close, then the tab
// opened again, loaded from disk. The tab is found by the chat's id: the
// open reveals the panel the Claude extension keeps for it - no new tab
// where it has one here. But a remembered tab, one restored by a reload and
// not yet revived, is revealed by its label, later, so the tab in front is
// taken for the chat only where its label reads as the chat, and - where
// the open brought nothing forward - no twin or other chat shares that
// label. The close comes right after the last look at the front tab, with
// the registry read once more: a turn begun meanwhile keeps the tab. A tab
// kept gets no second check at all - its process stays under it. A new
// tab means the chat had no panel here - its process sits in the side bar -
// and the second check ends only processes started before the open, so the
// new tab's own is never ended - and none at all within restartHold of an
// extension-host restart (restartHeld). 'reopened', 'watch' (a queued
// prompt went into it meanwhile: its live view instead), 'new', 'stale',
// 'working', 'running', or what ensureListed refused.
async function showLive(req, file) {
    const sid = (req.sessionId || '').slice(0, 8);
    const step = (s) => log('Show it ' + sid + ': ' + s);
    const listed = await ensureListed(req);
    if (listed === 'unlistable') {
        offerTerminal(req).catch(e => log('the terminal offer failed: ' + (e && e.message)));
        return 'unlistable';
    }
    if (listed === 'held' || listed === 'unmended') {
        vscode.window.showInformationMessage((listed === 'held' ? texts.hiddenBusy : texts.unmended)(req));
        return listed;
    }
    // a new tab from this open starts a new process beside the side bar's:
    // what the old one alone had is read, and armed to go into it, first
    const lostNew = await lostByReopen(req);
    const carryNew = carryFor(req, lostNew);
    const startedBefore = new Date().toISOString();
    const before = allTabs().filter(isClaudeTab);
    const beforeActive = activeTab();
    await openOnce(req.sessionId);
    await sleep(timing.tabSettle);
    let how, col;
    if (await tabAppeared(before)) how = 'new';
    else {
        let t = activeTab();
        // the front tab unchanged: one more look, for a new tab slow to come
        if (t && t === beforeActive) {
            await sleep(timing.tabRecount);
            if (tabGrew(before)) how = 'new';
            else t = activeTab();
        }
        if (!how) {
            const twin = !!t && before.some(x => x !== t && x.label === t.label);
            const ok = !!t && isClaudeTab(t) && before.includes(t) && labelIsChat(req.title, t.label);
            const shared = ok && t === beforeActive && !twin ? await labelShared(req.title, req.cwd, req.sessionId, req.home) : false;
            if (!ok || (t === beforeActive && (twin || shared))) {
                step('not closed - active tab ' + (t ? t.label : '(none)') + (twin ? ', another Claude tab of that label' : '') +
                    (shared ? ', another chat of its folder has that label' : ''));
                how = 'stale';
            } else if (workingNow(req)) {
                step('not closed - it began to work meanwhile');
                how = 'stale';
            } else if (tabGrew(before)) how = 'new';
            else {
                // no await between this look and the close
                const now = activeTab();
                if (now !== t) { step('not closed - the tab in front changed'); how = 'stale'; }
                else {
                    col = t.group && t.group.viewColumn;
                    const closing = vscode.window.tabGroups.close(t);
                    await bounded(closing, 'closing the tab');
                    how = 'closed';
                }
            }
        }
    }
    step(how === 'closed' ? 'its tab closed' : how === 'new' ? 'a new tab - it had no panel here' : 'its tab left as it is');
    // A tab left open keeps its process: no second check, which would end
    // it under the tab after the grace - the dead tab, "Claude Code process
    // exited with code 1", this order is there to prevent. Closing the tab
    // and opening the chat again, as said, ends it cleanly.
    if (how === 'stale') {
        vscode.window.showInformationMessage(texts.staleTab(req));
        return 'stale';
    }
    // A new tab moments after an extension-host restart may be one Claude
    // Code reopened by itself, the open only revealing it: its process, of
    // this window and started before the open, is the one the second check
    // would end - that tab dead again. So then it only judges.
    const held = how === 'new' && restartHeld();
    if (held) step('a new tab within ' + Math.round(timing.restartHold / 1000) + ' s of an extension-host restart (' + runClock.hostStart + ') - maybe one Claude Code reopened: judged only, nothing ended');
    const v2 = await module.exports._getVerdict(req, file, held ? { judgeOnly: true } : { grace: timing.graceSeconds, hostPid: process.pid, startedBefore });
    step(v2 ? 'then oldProcess ' + v2.oldProcess + ', outcome ' + v2.outcome : 'the second check failed');
    if (how === 'new') {
        await unlockClaudeGroup(req.title, before, 'new');
        vscode.window.showInformationMessage((held ? texts.restartNew : texts.sideBarStale)(req));
        // a new process too: what the old one alone had is not in it, but
        // where carried - and the first open might have revealed a panel,
        // so no pre-fill
        sayLost(req, lostNew, false, carryNew);
        return 'new';
    }
    if (!v2 || !['none', 'ended'].includes(v2.oldProcess)) {
        const running = !!v2 && v2.outcome === 'running';
        step('not opened again - ' + (running ? 'a print-mode run goes into it' : 'a process still holds it'));
        const run = running ? liveRunFor(req.sessionId) : null;
        if (run) { openWatch(run.jobId, { viewColumn: col, title: run.title }); return 'watch'; }
        vscode.window.showInformationMessage((running ? texts.running : texts.working)(req));
        return running ? 'running' : 'working';
    }
    // a queued prompt that went in while this ran: its live view, where the
    // tab was - the chat opened now would load part way through the run
    const run = liveRunFor(req.sessionId);
    if (run) { step('#' + run.seq + ' runs into it now - its live view instead'); openWatch(run.jobId, { viewColumn: col, title: run.title }); return 'watch'; }
    await sleep(timing.tabSettle);
    // its tab closed and its process gone: a new panel, whose process -
    // or else its input box - takes what the old process alone had. Armed
    // again, as the first open's arm may have gone by in the grace
    const lost = await lostByReopen(req);
    const carrying = carryFor(req, lost);
    await openOnce(req.sessionId, col, (lost && lost.prefill) || undefined);
    await sleep(timing.tabSettle);
    await unlockClaudeGroup(req.title, before, 'reopened');
    step('opened again');
    sayLost(req, lost, true, carrying);
    return 'reopened';
}

async function offer(context, req, file) {
    // Not ours: left for the window it is for. Checked before marking it
    // seen, which every window shares.
    if (!isTarget(req)) return;
    const exact = isExactlyMine(req);
    const age = ageOf(req);
    const fresh = req.kind === 'ran' && canShowFresh(req);

    // Marked seen BEFORE acting: the file is still on disk afterwards, so
    // without this the same request would prompt again on every reload.
    // A newer run into the chat takes the place of a Show it not taken.
    if (req.kind === 'ran') unshown.delete(unshownKey(req.sessionId));
    await markSeen(context, SEEN_KEY, req.id);

    // The run of a job this window handed its tab over to: the chat is put
    // back as the run ends (restoreHandover), from data/run-state, whatever
    // the outcome - so this request, which comes only after some, has
    // nothing more to do. Offered too, it would ask to show a chat whose tab
    // is gone, beside the live view that says the same.
    if (req.kind === 'ran' && req.jobId && handoverOf(context, req.jobId)) {
        log('ran ' + (req.sessionId || '').slice(0, 8) + ': #' + (req.seq || '?') + ' was handed over here - the run\'s end puts the chat back');
        return 'handed over';
    }

    const auto = reloadsItself(req, setting('autoReload'), setting('autoReloadAfterRun'), exact, age);
    if (fresh) {
        const by = showsItself(req, setting('autoReloadAfterRun'), exact, age);
        if (by === 'show it') {
            log(req.kind + ' ' + (req.sessionId || '').slice(0, 8) + ' by itself: Show it, its idle process here (away ' + req.away + ', busy ' + req.busy + ')');
            return showIt(req, file);
        }
        if (auto || by === 'tab') {
            log(req.kind + ' ' + (req.sessionId || '').slice(0, 8) + ' by itself: busy ' + req.busy + ', oldProcess ' + req.oldProcess);
            const how = plan(req, { busy: req.busy, oldProcess: req.oldProcess }, { fresh: true, claude: true });
            return enqueue(() => perform(how, req));
        }
        if (req.oldProcess === 'other') { vscode.window.showInformationMessage(message(req, true)); return; }
        if (req.oldProcess === 'held') {
            const go = 'Reload anyway';
            const shownAt = safe._now();
            const pick = await askReload(true, message(req, true), go, askSay(req));
            if (pick === go) return enqueue(() => reloadAnyway(shownAt, req.sessionId, req.sessionId));
            return;
        }
        const go = 'Show it';
        // until it is taken, the chip's open of this chat goes its way
        if (req.sessionId) unshown.set(unshownKey(req.sessionId), req);
        const pick = await vscode.window.showInformationMessage(message(req, true), go, 'Not now');
        if (pick !== go) return;
        // the chip went its way while this notice waited: shown already
        if (shownRuns.has(req.id)) {
            log('Show it ' + (req.sessionId || '').slice(0, 8) + ': shown already, by the open chip - passed by');
            return 'shown';
        }
        return showIt(req, file);
    }

    // The script's word was of one folder, as the request went out; the
    // reload ends every chat of this window, whatever its folder, and the
    // word says nothing of one that began since. So this window's own
    // chats are looked at first (guardReload): one working, and it asks.
    const except = req.kind === 'ran' ? req.sessionId : null;
    if (auto) {
        return safe._guardReload(true, except);
    }
    if (req.kind === 'new') { vscode.window.showInformationMessage(message(req, false)); return; }
    const busy = req.busy === true;
    const go = busy ? 'Reload anyway' : 'Reload';
    const shownAt = safe._now();
    const pick = await askReload(busy, message(req, false), go, askSay(req));
    if (pick === go) {
        // Reload anyway was the answer to a warning about this request's
        // chat: fresh, it reloads; later, looked at again past that chat. A
        // plain Reload, maybe clicked minutes later, is looked at again
        if (busy) return reloadAnyway(shownAt, req.sessionId, except);
        return safe._guardReload(false, except);
    }
}

// Every request in the file not seen yet, oldest first; what the newest of
// them came to is returned.
function check(context, file, onlyRecent) {
    let last;
    const reqs = requestsOf(file);
    seedSeen(context, SEEN_KEY, reqs);
    for (const req of reqs) {
        const r = checkOne(context, req, file, onlyRecent);
        if (r !== undefined) last = r;
    }
    return last;
}

function checkOne(context, req, file, onlyRecent) {
    if (!req.id || req.kind === 'open') return;
    if (wasSeen(context, SEEN_KEY, req.id)) return;
    if (!isTarget(req)) return;
    if (onlyRecent) {
        // at startup, ignore a request left over from days ago - the list it
        // was about was rebuilt from disk when this window opened
        const at = Date.parse(req.at || '');
        if (!at || Date.now() - at > 10 * 60 * 1000) return;
        // a window just opened has read every chat from disk, the run
        // included, so it has nothing to reload for - and the new chat a
        // run started is one no reload lists; and a run's away verdict,
        // given as it ended, is stale with someone opening windows
        if (req.kind === 'ran' || req.kind === 'new') { markSeen(context, SEEN_KEY, req.id); return; }
    }
    return offer(context, req, file);
}

// The overlay's open chip: always a tab (openTab). The chip ends no process,
// so there is nothing to show fresh and showFresh has no say; a reload would
// only cut off whatever else the window runs. At startup - a window code -n
// just opened for it - the Claude extension is given a moment to start.
// Its watch (kind 'watch', with the job's id): a queued prompt runs into the
// chat, and its live view is opened instead - no Claude extension needed.
// Every request in the file not seen yet, oldest first, each waited for;
// what the newest of them came to is returned.
async function checkOpen(context, file, onlyRecent) {
    let last;
    const reqs = requestsOf(file);
    seedSeen(context, OPEN_SEEN_KEY, reqs);
    for (const req of reqs) {
        const r = await checkOpenOne(context, req, file, onlyRecent);
        if (r !== undefined) last = r;
    }
    return last;
}

// A chat whose run was offered Show it here, not taken (unshown): its tab
// shows it from before the run, on a process that never reads the
// transcript again, and a message typed there goes on from before it. So
// the chip's open goes Show it's way - judged first, its tab closed, what
// outlived the close ended, and opened again from disk (showLive) - with
// what the chip judged just now in place of what the run's end did. Only
// while the chip found that process idle in this window (live): with none
// left - its tab closed - any open loads the chat from disk, and one
// working has been typed into since, so it goes on from what it shows and
// a reopen would show the same. Either way the offer is forgotten. Where
// no window can be told (hostPids empty, as on a Mac) the tab is brought
// forward as before.
async function checkOpenOne(context, req, file, onlyRecent) {
    if (!isGuid(req.sessionId) || !req.id) return;
    if (req.kind !== 'open' && !(req.kind === 'watch' && validJobId(req.jobId))) return;
    if (wasSeen(context, OPEN_SEEN_KEY, req.id)) return;
    if (!isTarget(req)) return;
    const age = ageOf(req);
    await markSeen(context, OPEN_SEEN_KEY, req.id);
    if (!(age <= timing.openMaxAge)) return;
    if (req.kind === 'watch') {
        log('watch ' + req.sessionId.slice(0, 8) + ': #' + (req.seq || '?') + ' from the chip');
        return openWatch(req.jobId, { title: req.title }) ? 'watch' : 'failed';
    }
    if (!hasClaude()) {
        vscode.window.showInformationMessage(texts.noClaude(req));
        return;
    }
    const ran = unshown.get(unshownKey(req.sessionId));
    if (ran && (req.oldProcess === 'none' || req.oldProcess === 'held')) unshown.delete(unshownKey(req.sessionId));
    else if (ran && req.oldProcess === 'live' && hostPidsOf(req).includes(process.pid)) {
        log('open ' + req.sessionId.slice(0, 8) + ': its run\'s Show it was not taken here - shown its way');
        return showIt(Object.assign({}, ran, { hostPids: hostPidsOf(req), oldProcess: req.oldProcess, busy: req.busy, file: req.file || ran.file, at: req.at }), file, req);
    }
    if (onlyRecent) await sleep(timing.startupOpen);
    return enqueue(() => openTab(req));
}

// --- a queued prompt's run, where the chat's tab was -------------------------
// The watcher runs one job at a time, and says where it is in data/run-state
// (Write-ChatRunState, src/chatrm.ps1): 'handover' - it is about to run into
// a chat a window here holds on an idle process, and waits a moment for that
// window to answer (data/run-ack/<its pid>.json) and close the chat's tab -
// then 'running', then 'ended', whatever the outcome. A run beside a live
// tab forks the chat: a message typed there goes on from the tab's own
// memory, and the run's turn ends up on a branch nobody sees. So the tab
// goes, a live view of the run - the watch panel - takes its place, and the
// chat comes back when the run ends. The file is looked at every
// timing.runPoll, and once as the window starts.

const HANDOVER_KEY = 'chatManager.handovers';
const WATCH_TYPE = 'chatManager.watch';
// a job's id, as New-ChatqJobSlot makes it: the only thing of run-state's or
// a request's that ever becomes part of a path here
const JOB_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/;
function validJobId(id) { return typeof id === 'string' && JOB_ID.test(id); }

function dataDir() { return path.join(toolFolder(), 'data'); }
function runStateFile() { return path.join(dataDir(), 'run-state'); }
function ackFile() { return path.join(dataDir(), 'run-ack', process.pid + '.json'); }
function jobFileOf(id) { return path.join(dataDir(), 'queue', id + '.json'); }
function logFileOf(id) { return path.join(dataDir(), 'logs', id + '.jsonl'); }

// data/run-state, or null for none, or one of no shape this reads
function readRunState() {
    const rs = readRequest(runStateFile());
    if (!rs || !rs.id || !['handover', 'running', 'ended'].includes(rs.phase) || !validJobId(rs.jobId)) return null;
    return rs;
}

function readJob(id) { return validJobId(id) ? readRequest(jobFileOf(id)) : null; }

// Is the run run-state names going now? A watcher killed mid-run, or a PC
// that slept through its end, leaves 'running' there for good - so only
// while the job file says running too, and the watcher (runnerPid) lives.
function runIsLive(rs) {
    if (!rs || (rs.phase !== 'handover' && rs.phase !== 'running')) return false;
    const job = readJob(rs.jobId);
    if (!job || job.state !== 'running') return false;
    const pid = Number.isInteger(rs.runnerPid) && rs.runnerPid > 0 ? rs.runnerPid : Number.isInteger(job.runnerPid) ? job.runnerPid : 0;
    return pid > 0 ? module.exports._alive(pid) : true;
}

// A job file that says running for that chat, its watcher alive. The
// watcher sets a job running before its handover and writes run-state only
// after it, so for those seconds run-state still names the run before - and
// an open then would start a second copy of the chat as the run goes in.
function runningJobFor(sid, rs) {
    let names;
    try { names = fs.readdirSync(path.join(dataDir(), 'queue')); } catch (e) { return null; }
    const want = String(sid).toLowerCase();
    for (const n of names) {
        if (!n.endsWith('.json')) continue;
        const id = n.slice(0, -5);
        const job = readJob(id);
        if (!job || job.state !== 'running' || String(job.sessionId || '').toLowerCase() !== want) continue;
        if (Number.isInteger(job.runnerPid) && job.runnerPid > 0 && !module.exports._alive(job.runnerPid)) continue;
        // run-state saying this very job ended after it started: the file is
        // behind; one started after that end is a new try of the job
        if (rs && rs.jobId === id && rs.phase === 'ended' && !(Date.parse(job.startedAt) > Date.parse(rs.at))) continue;
        return { jobId: id, seq: job.seq, sessionId: job.sessionId, title: job.title, cwd: job.cwd, home: job.home, provider: job.provider, phase: 'running' };
    }
    return null;
}

// run-state of the chatq run going into that chat now - or, before
// run-state says so, its job file - else null. Read only where a chat is
// about to be opened, never per row.
function liveRunFor(sid) {
    if (!sid) return null;
    const rs = readRunState();
    if (rs && String(rs.sessionId || '').toLowerCase() === String(sid).toLowerCase() && runIsLive(rs)) return rs;
    return runningJobFor(sid, rs);
}

// The chats this window handed over, kept in workspaceState so a reload in
// between still puts them back: { sessionId, jobId, seq, title, cwd, home,
// provider, viewColumn, wasVisible, at }, and restored once put back.
function handovers(context) {
    const a = context && context.workspaceState ? context.workspaceState.get(HANDOVER_KEY) : null;
    return Array.isArray(a) ? a.filter(r => r && validJobId(r.jobId)) : [];
}
function handoverOf(context, jobId) { return handovers(context).find(r => r.jobId === jobId); }
async function putHandovers(context, list) {
    if (context && context.workspaceState) await context.workspaceState.update(HANDOVER_KEY, list);
}

// This window's answer to a handover: 'closing' (its tab is being closed -
// the watcher waits for the process to leave), 'unsure' (no tab here is
// surely the chat's), 'in-use' (you are in it - the job waits) or 'off'
// (chatManager.watchRuns). Written whole, then moved into place, so the
// watcher never reads half of one.
function writeAck(rs, answer) {
    const f = ackFile();
    try {
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(f + '.tmp', JSON.stringify({ id: rs.handoverId || rs.id, answer, at: new Date().toISOString() }));
        fs.renameSync(f + '.tmp', f);
    } catch (e) { log('handover: ' + f + ' could not be written: ' + (e && e.message)); }
}

// a command of the scripts, run through the tool folder's loader as
// overlayAutoStart runs one - so the tests stand in for PowerShell. null
// where there is no loader or no PowerShell.
async function psRun(cmd) {
    const io = module.exports._overlayIo;
    const loader = path.join(toolFolder(), setup.LOADER);
    if (!io.exists(loader)) { log('no ' + loader + ', so not run: ' + cmd); return null; }
    const exe = io.powershell(io.platform());
    if (!exe) { log('no PowerShell found, so not run: ' + cmd); return null; }
    return setup._runPs(exe, loader, cmd, 60000, log);
}

function besideColumn() { return vscode.ViewColumn && vscode.ViewColumn.Beside !== undefined ? vscode.ViewColumn.Beside : -2; }

// run-state ids acted on; jobs whose next handover skips the in-use rule
// (Hand over now); jobs whose in-use notice was said; runs (runOf) whose
// old view was said stale; the last run-state of each job, for its away
// once run-state has moved on
const handled = new Set(), handOverNow = new Set(), inUseSaid = new Set(), besideSaid = new Set();
const lastRuns = new Map();
function remember(set, v) { set.add(v); if (set.size > 200) set.delete(set.values().next().value); }

// One run of a job, as run-state names it: its handover's id, which the
// run's own writes carry on (handoverId), else - no handover, as for a
// background command - the write's own id, one 'running' a run. Pure.
function runOf(rs) { return String((rs && (rs.handoverId || rs.id)) || ''); }

// Is the handover rs still the one the watcher waits on? run-state read
// again: it moves on once the watcher stops listening - after
// ChatHandoverAckSeconds (src/core.ps1), 3 s from its write - and runs
// beside the tab or puts the job back. It may stay 'handover' a while after
// that, while the watcher judges the chat again, so an answer later than
// timing.ackWindow from the write counts as late too: nobody reads it.
function stillHandover(rs) {
    const now = readRunState();
    if (!now || now.phase !== 'handover' || now.id !== rs.id) return false;
    const at = Date.parse(now.at || '');
    return !(at && Date.now() - at > timing.ackWindow);
}

// A handover for this window, handled at once - never behind a show on the
// show queue, which can take half a minute while the watcher waits 3 s for
// the answer. The tab is found by its label alone: editor.open here would
// start a second process for the chat where it has no panel, mid-run. An
// answer is written, a tab closed and the in-use notice shown only while
// the watcher still waits for this handover (stillHandover): a late one is
// read by nobody, and the run may already go on beside the tab - closed
// then, a liveIdle stop may have ended its process first; said to wait, you
// would type into a chat the run writes to. Late: nothing done, nothing
// said - the run's own 'running' says the old view is stale (onBeside).
async function onHandover(context, rs) {
    const say = s => log('handover ' + String(rs.sessionId || '').slice(0, 8) + ' (' + seqOf(rs) + '): ' + s);
    const answer = (a) => {
        if (!stillHandover(rs)) { say('late - the watcher went on without it; ' + a + ' not written, nothing done'); return false; }
        writeAck(rs, a);
        return true;
    };
    if (setting('watchRuns') === false) { if (!answer('off')) return 'late'; say('off - chatManager.watchRuns'); return 'off'; }
    if (!isGuid(rs.sessionId)) { if (!answer('unsure')) return 'late'; say('no session id'); return 'unsure'; }
    // a turn begun since the watcher looked: it waits, as for a busy chat
    if (workingNow(rs)) { if (!answer('in-use')) return 'late'; say('it works now - it waits'); return 'in-use'; }
    const t = oneTabOf(rs.title, allTabs().filter(isClaudeTab));
    const shared = t ? await labelShared(rs.title, rs.cwd, rs.sessionId, rs.home) : false;
    if (!t || shared) {
        if (!answer('unsure')) return 'late';
        say('no tab here is surely its own' + (shared ? ' - another chat of its folder has that label' : '') + ': its live view beside, the old view said stale');
        // the run goes beside it ('unsure'): said here, so not again then
        remember(besideSaid, runOf(rs));
        openWatch(rs.jobId, { viewColumn: besideColumn(), preserveFocus: true, title: rs.title });
        vscode.window.showWarningMessage(texts.handoverStale(rs));
        return 'unsure';
    }
    const focused = !!(vscode.window.state && vscode.window.state.focused);
    const front = focused && activeTab() === t;
    // In front of you, and you here: you may be reading the answer, or
    // typing the next message - a close would lose the draft, or cut off a
    // turn begun a moment later. It waits for you to leave the tab.
    if (front && rs.away !== true && !handOverNow.has(rs.jobId)) {
        if (!answer('in-use')) return 'late';
        say('its tab is in front of you - it waits');
        if (!inUseSaid.has(rs.jobId)) { remember(inUseSaid, rs.jobId); askHandOver(rs).catch(e => log('hand over now failed: ' + (e && e.message))); }
        return 'in-use';
    }
    if (!answer('closing')) return 'late';
    handOverNow.delete(rs.jobId);
    const g = t.group;
    const col = g ? g.viewColumn : undefined;
    const visible = !!g && g.activeTab === t;
    // The live view first, in the tab's group: closed first, the tab's
    // group may go with it (closeEmptyGroups) and the view land elsewhere. A
    // tab behind others gets none by itself - it would hide what is shown
    // there - only a word with Watch.
    const made = visible ? openWatch(rs.jobId, { viewColumn: col, preserveFocus: !front, title: rs.title }) : null;
    const late = !stillHandover(rs);
    if (late || workingNow(rs) || !allTabs().includes(t)) {
        say('not closed - ' + (late ? 'the watcher went on without it' : allTabs().includes(t) ? 'it began to work meanwhile' : 'its tab went meanwhile'));
        if (made && made.fresh) made.panel.dispose();
        return late ? 'late' : 'kept';
    }
    // start: when the process the close ends began - what it alone had is
    // put back with the chat, and a reload before then forgets the launch
    const start = processStart(rs.sessionId);
    await bounded(vscode.window.tabGroups.close(t), 'closing the tab');
    // the view a Show it not taken was for is gone: the chat comes back
    // from disk as the run ends
    unshown.delete(unshownKey(rs.sessionId));
    const rec = { sessionId: rs.sessionId, jobId: rs.jobId, seq: rs.seq, title: rs.title || '', cwd: rs.cwd || '', home: rs.home || null,
        provider: rs.provider || 'claude', viewColumn: col, wasVisible: visible, at: new Date().toISOString(), start };
    // a new record, a new run: no wait on an old run's watch tab carried on
    tabWaits.delete(rs.jobId);
    await putHandovers(context, handovers(context).filter(r => r.jobId !== rs.jobId).concat([rec]));
    say('its tab closed' + (visible ? ', its live view in its place' : ' - a tab behind others, so no live view by itself'));
    if (!visible) {
        const go = 'Watch';
        vscode.window.showInformationMessage(texts.handedBack(rs), go).then(p => { if (p === go) openWatch(rs.jobId, { viewColumn: col, title: rs.title }); }, () => { });
    }
    return 'closing';
}

// The in-use notice, once a job. Hand over now: that job's next handover
// skips the rule, and its wait alone is cleared - its deferUntil, through
// the loader as Cancel runs Stop-ChatqJobRun, and only while the job is
// still queued waiting for its tab ('in-use') - and the watcher poked to
// look again. Never chatqrun -Now's wake, which forgets every wait of every
// lane: a limit, an outage, the other chats' deferrals. A click on a notice
// left in the notification centre after its job moved on - handed over
// since, or ended - does nothing: that job's later handover, a continue
// after the limit say, keeps the rule. 'asked', 'stale', 'not now' or
// 'failed'.
async function askHandOver(rs) {
    const go = 'Hand over now';
    const pick = await vscode.window.showInformationMessage(texts.inUse(rs), go);
    if (pick !== go) return 'not now';
    const say = s => log('handover ' + String(rs.sessionId || '').slice(0, 8) + ' (' + seqOf(rs) + '): Hand over now - ' + s);
    const job = readJob(rs.jobId);
    if (!job || job.state !== 'queued' || job.deferWhy !== 'in-use') { say('it waits for its tab no more (' + (job ? job.state : 'gone') + '), so nothing done'); return 'stale'; }
    // before the wake: the handover it brings may come before the answer
    remember(handOverNow, rs.jobId);
    const r = await psRun('$j = Find-ChatqJob ' + psQuote(rs.jobId) + " -Exact; if ($j -and $j.state -eq 'queued' -and [string](Get-ChatField $j 'deferWhy') -eq 'in-use') { " +
        "Set-ChatqProp $j 'deferUntil' $null; Save-ChatqJob $j; Request-ChatqWatcher -Wake poke | Out-Null; [Console]::Out.WriteLine('handover: now') } " +
        "else { [Console]::Out.WriteLine('handover: not waiting') }");
    const said = lastSaid(r && r.stdout, /^handover: /);
    if (said === 'handover: not waiting') { handOverNow.delete(rs.jobId); say('it waits for its tab no more, so nothing done'); return 'stale'; }
    // no answer: its next try, within a minute, still skips the rule
    say(said ? 'its wait cleared, the watcher asked' : 'the watcher could not be asked');
    return said ? 'asked' : 'failed';
}

// A run beside the chat's view here: 'background' - no handover, since a
// background command the chat started still runs, a server, a watcher,
// which closing its tab would end; 'unsure' - the handover got no answer in
// time, or none sure of the tab; 'timed-out' - its tab closed, its process
// did not leave. Its live view beside - one open already stays where it is
// - and the old view said stale; once a run, the handover's own word
// included. A job run again - back in the queue at the limit, then on - is
// a new run, beside the tab again, and said again.
const BESIDE = ['background', 'unsure', 'timed-out'];
function onBeside(rs) {
    if (besideSaid.has(runOf(rs))) return 'said';
    remember(besideSaid, runOf(rs));
    log('run ' + String(rs.sessionId || '').slice(0, 8) + ' (' + seqOf(rs) + '): beside its tab (' + rs.beside + ')');
    const had = watchViews.get(rs.jobId);
    if (!had || had.disposed) openWatch(rs.jobId, { viewColumn: besideColumn(), preserveFocus: true, title: rs.title });
    vscode.window.showWarningMessage((rs.beside === 'background' ? texts.besideStale : texts.handoverStale)(rs));
    return 'beside';
}

// The status bar item, in every window whose folders hold the job's: which
// job runs, and - what the phone is asked - that it waits for you, in the
// warning colour. A click opens its live view.
let runItem = null;
function updateRunItem(rs, live) {
    if (!(rs && live && isMine(rs))) { if (runItem) runItem.hide(); return 'hidden'; }
    if (!runItem && vscode.window.createStatusBarItem) {
        runItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment ? vscode.StatusBarAlignment.Left : 1, 50);
    }
    if (!runItem) return 'none';
    const pw = (readJob(rs.jobId) || {}).permitWaiting;
    const asks = !!(pw && pw.tool);
    runItem.text = (asks ? '$(bell) chatq ' + seqOf(rs) + ' waits for your answer' : '$(play-circle) chatq ' + seqOf(rs) + ' running');
    runItem.tooltip = (rs.title || 'a chat') + (asks ? ' - waits for your answer on the phone: ' + pw.tool + (pw.until ? ', until ' + watch.hhmm(pw.until) : '') : '') +
        ' - click to watch it live';
    runItem.command = 'chatManager.watchRun';
    runItem.backgroundColor = asks && vscode.ThemeColor ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
    runItem.show();
    return asks ? 'asks' : 'running';
}

// --- the queue, in the status bar ---------------------------------------------
// How many prompts are queued and when the next one sends: the "sends" of
// chatqlist and the board (Get-ChatqEta, src/alerts.ps1), cut to the first.
// Looked at on the run-state timer (timing.runCheck), from data/ alone:
// each job file read again only when it changed, and data/state.json,
// the watcher's own view of the lanes' limits and overloads.

function stampOf(s) { const t = Date.parse(s || ''); return Number.isFinite(t) ? t : null; }

// Get-ChatqBlocks: each lane's limit or overload, by lane, from the saved
// state - only while its watcher runs and is not just listening for phone
// replies, whose view of the limits is hours stale. Where the watcher does
// not run nothing sends anyway, and chatqlist's scan of the limits is
// PowerShell's alone: no lane is taken as blocked. Pure.
function queueBlocks(state, watcherUp, now) {
    const out = {};
    if (!state || !watcherUp || state.listening) return out;
    for (const [lane, b] of Object.entries(state.blocked || {})) {
        const u = stampOf(b && b.until);
        if (u && u > now) out[lane] = { until: u, type: b.type };
    }
    for (const lane of Object.keys(state.outage || {})) out[lane] = { type: 'overloaded' };
    return out;
}

// What a job put off waits for, where its deferUntil is only its next look:
// Format-ChatqDeferWhy's words (src/alerts.ps1), the "since" left off
const DEFER_WORDS = { 'in-use': 'waits for you to leave its tab', background: 'waits for a background command' };

// The queue in short, else null for none queued: count, and when the first
// sends - 'now' (nothing ahead), 'after' (the run going now, seq), 'at' (a
// time), 'waits' (no time: words, what the first one waits for), or 'back'
// (every one waits on an overload; who: the provider that is down -
// 'Claude', 'Codex', or 'Claude and Codex' - as Get-ChatqEta names a
// Codex lane's outage Codex's). A job's wait is its lane's limit's end
// and a minute, its notBefore, and a deferUntil or retryAt still ahead -
// the latest of them, as Get-ChatqEta has it; and where that latest is a
// deferUntil for a tab in use or a background command, the board gives
// its words instead of a time, so no time is taken from it here. A time
// beats words: it is a send, and theirs is only a look. Pure.
function queueNext(jobs, blocks, now) {
    const queued = (jobs || []).filter(j => j && j.state === 'queued');
    if (!queued.length) return null;
    const running = (jobs || []).find(j => j && j.state === 'running');
    let soonest = null, waits = null;
    const down = new Set();
    for (const j of queued) {
        const lane = j.home ? j.provider + '|' + j.home : String(j.provider || '');
        const b = (blocks || {})[lane];
        if (b && b.type === 'overloaded') { down.add(j.provider === 'codex' ? 'Codex' : 'Claude'); continue; }
        const times = [];
        if (b && b.until) times.push(b.until + 60000);
        const du = stampOf(j.deferUntil);
        for (const t of [stampOf(j.notBefore), du, stampOf(j.retryAt)]) if (t && t > now) times.push(t);
        if (!times.length) {
            return running ? { count: queued.length, next: 'after', seq: running.seq } : { count: queued.length, next: 'now' };
        }
        const at = Math.max(...times);
        const words = du && du > now && at === du ? DEFER_WORDS[j.deferWhy] : undefined;
        if (words) { if (!waits) waits = words; continue; }
        if (soonest === null || at < soonest) soonest = at;
    }
    if (soonest !== null) return { count: queued.length, next: 'at', at: soonest };
    const who = down.size > 1 ? 'Claude and Codex' : down.has('Codex') ? 'Codex' : 'Claude';
    return waits ? { count: queued.length, next: 'waits', words: waits } : { count: queued.length, next: 'back', who: who };
}

// a time as the board writes it: HH:mm today, else its weekday before it
function sendsAt(t, now) {
    const d = new Date(t), n = new Date(now);
    const day = d.toDateString() === n.toDateString() ? '' : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()] + ' ';
    return day + watch.hhmm(t);
}

// The item's text and tooltip, else null for none queued. The board's
// words: next, after #seq, a time, what it waits for, when Claude (or
// Codex) is back. Pure.
function queueText(q, watcherUp, now) {
    if (!q) return null;
    const n = q.count + ' queued';
    const dot = ' \u00b7 ';
    if (!watcherUp) {
        return { text: '$(clock) chatq ' + n + dot + 'watcher stopped',
            tooltip: 'chatq has ' + n + ', and its watcher is not running: nothing sends until chatqrun - or a new terminal that loads chatq - starts it. Click for the queue.' };
    }
    const seq = q.seq === undefined || q.seq === null ? '?' : q.seq;
    // a q from before who was carried is Claude's, as it always said
    const who = q.who || 'Claude';
    const back = 'when ' + who + (who.indexOf(' and ') >= 0 ? ' are back' : ' is back');
    const when = q.next === 'now' ? 'next' : q.next === 'after' ? 'after #' + seq : q.next === 'back' ? back :
        q.next === 'waits' ? q.words : sendsAt(q.at, now);
    const says = q.next === 'now' ? 'the next one sends now' : q.next === 'after' ? 'the next one sends after #' + seq + ', the run going now' :
        q.next === 'back' ? 'they send ' + back + ' from ' + (who.indexOf(' and ') >= 0 ? 'their overloads' : 'its overload') : q.next === 'waits' ? 'the next one ' + q.words + ', and has no time to send' :
        'the next one sends at ' + when;
    return { text: '$(clock) chatq ' + n + dot + when, tooltip: 'chatq has ' + n + ': ' + says + '. Click for the queue.' };
}

// data/queue/*.json, each read again only when its size or write time moved
const queueSeen = new Map();
function readQueue() {
    const dir = path.join(dataDir(), 'queue');
    let names;
    try { names = fs.readdirSync(dir); } catch (e) { queueSeen.clear(); return []; }
    const jobs = [], here = new Set();
    for (const n of names) {
        if (!/\.json$/i.test(n)) continue;
        const f = path.join(dir, n);
        let st;
        try { st = fs.statSync(f); } catch (e) { continue; }
        here.add(f);
        const hit = queueSeen.get(f);
        let job = hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs ? hit.job : undefined;
        if (job === undefined) {
            job = readRequest(f);
            // one caught mid-write is read again next time
            if (job) queueSeen.set(f, { size: st.size, mtimeMs: st.mtimeMs, job });
        }
        if (job && job.id) jobs.push(job);
    }
    for (const f of [...queueSeen.keys()]) if (!here.has(f)) queueSeen.delete(f);
    return jobs;
}

// Is the watcher running? It holds data/watcher.lock open for its whole
// life (Test-ChatqWatcherAlive, src/alerts.ps1); a Mac's lock is only
// advisory, so there the pid it saved in data/state.json answers instead.
function watcherUp(state) {
    const io = module.exports._overlayIo;
    if (io.platform() === 'win32') return io.lockHeld(path.join(dataDir(), 'watcher.lock'));
    return !!state && Number.isInteger(state.pid) && state.pid > 0 && module.exports._alive(state.pid);
}

// The item, in every window: shown while something is queued, gone when
// nothing is. A click opens the board.
let queueItem = null;
function updateQueueItem(now) {
    const t = now === undefined ? Date.now() : now;
    const jobs = readQueue();
    let shown = null;
    if (jobs.some(j => j.state === 'queued')) {
        const state = readRequest(path.join(dataDir(), 'state.json'));
        const up = watcherUp(state);
        shown = queueText(queueNext(jobs, queueBlocks(state, up, t), t), up, t);
    }
    if (!shown) { if (queueItem && queueItem.hide) queueItem.hide(); return 'hidden'; }
    if (!queueItem && vscode.window.createStatusBarItem) {
        queueItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment ? vscode.StatusBarAlignment.Left : 1, 49);
    }
    if (!queueItem) return 'none';
    queueItem.text = shown.text;
    queueItem.tooltip = shown.tooltip;
    queueItem.command = 'chatManager.showQueue';
    queueItem.show();
    return shown.text;
}

// The board, data/queue.md, as the watcher last wrote it, in the Markdown
// preview - which follows each write after (chatqlist -Board)
async function showQueue() {
    const file = path.join(dataDir(), 'queue.md');
    if (!fs.existsSync(file)) { vscode.window.showInformationMessage(texts.noBoard); return 'none'; }
    try { await command('markdown.showPreview', vscode.Uri.file(file)); return 'shown'; }
    catch (e) { log('the queue board could not be shown: ' + (e && e.message)); return 'failed'; }
}

// the job file of the run going now, watched for what the phone is asked
let runJobWatched = null;
function watchRunJob(context, id) {
    if (runJobWatched && runJobWatched.id === id) return;
    if (runJobWatched) fs.unwatchFile(runJobWatched.file, runJobWatched.fn);
    runJobWatched = null;
    if (!id) return;
    const file = jobFileOf(id), fn = () => { onRunState(context); };
    fs.watchFile(file, { interval: timing.runPoll }, fn);
    runJobWatched = { id, file, fn };
}

// run-state looked at: the status bar, a handover or a run beside for this
// window, and the chats handed over whose run has ended put back.
function onRunState(context) {
    const rs = readRunState();
    if (rs) { lastRuns.set(rs.jobId, rs); if (lastRuns.size > 50) lastRuns.delete(lastRuns.keys().next().value); }
    const live = runIsLive(rs);
    updateRunItem(rs, live);
    watchRunJob(context, live && isMine(rs) ? rs.jobId : null);
    let acted = null;
    if (rs && live && !handled.has(rs.id) && hostPidsOf(rs).includes(process.pid)) {
        if (rs.phase === 'handover') {
            remember(handled, rs.id);
            acted = onHandover(context, rs).catch(e => { log('handover failed: ' + ((e && e.stack) || e)); return 'failed'; });
        } else if (rs.phase === 'running' && BESIDE.includes(rs.beside)) {
            remember(handled, rs.id);
            acted = Promise.resolve(onBeside(rs));
        }
    }
    const restored = restoreRuns(context, rs);
    return Promise.all([acted, restored]).then(([a, r]) => ({ acted: a, restored: r }));
}

// Is a handed-over job still running? By run-state while it names the job;
// once it names another, or none, by the job file and its own runner.
function stillRunning(r, rs) {
    if (rs && rs.jobId === r.jobId) return runIsLive(rs);
    const job = readJob(r.jobId);
    return !!job && job.state === 'running' && Number.isInteger(job.runnerPid) && module.exports._alive(job.runnerPid);
}

// When this window's extension started: restoreHold and restartHold count
// from it. hostStart: what started it (hostStartOf); null before then
const runClock = { activatedAt: 0, hostStart: null };

// the jobs whose record waits on a watch tab not brought back yet, and
// since when (viewComing)
const tabWaits = new Map();

// Is the watch panel of that handover about to come back? A window started
// again brings its watch panels back through the serializer - after the
// first look at run-state, maybe, and a panel in a tab behind others only
// once that tab is shown. Put back without its panel, the chat would open
// and the panel come back beside it, never closed; or you would be asked
// to open a chat whose panel then shows Open chat too. So a record waits
// while its panel is not here: for restoreHold after the start, and while a
// watch tab of its job (its label, '#15') waits to be brought back - the
// serializer looks again as it brings one. That wait is tabHold at most,
// from the first look past restoreHold that found the run over: a tab VS
// Code keeps but never shows again would hold the chat for the record's two
// days, so past it the chat is put back as for a closed view, the tab left
// to come back with Open chat. A wait ends with its view back or its tab
// gone, and starts over when the job runs again (restoreRuns) or is handed
// over again (onHandover).
function viewComing(r, now) {
    const v = watchViews.get(r.jobId);
    if (v && !v.disposed) { tabWaits.delete(r.jobId); return false; }
    if (runClock.activatedAt && now - runClock.activatedAt < timing.restoreHold) return true;
    if (!/^\d+$/.test(String(r.seq))) return false;
    const mark = new RegExp('^\\S #' + r.seq + '(\\s|$)');
    if (!allTabs().some(t => isWatchTab(t) && mark.test(String(t.label || '')))) { tabWaits.delete(r.jobId); return false; }
    if (!tabWaits.has(r.jobId)) tabWaits.set(r.jobId, now);
    if (now - tabWaits.get(r.jobId) < timing.tabHold) return true;
    log('run ' + String(r.sessionId || '').slice(0, 8) + ' (' + seqOf(r) + ') ended: its watch tab not brought back in ' + Math.round(timing.tabHold / 1000) + ' s - put back without it');
    tabWaits.delete(r.jobId);
    return false;
}

// The chats handed over whose run is over - done, needs input, failed,
// cancelled, back in the queue at the limit - put back (restoreHandover),
// once each: a record put back is kept a while, marked, for the run's own
// request to find (offer), and one two days old is dropped. Marked once it
// has been handled, not before: a record whose panel is coming back waits
// (viewComing). Each record on its own - a job being put back is left to
// the pass that took it - and nothing here waits on you: a question asked
// on the way is left up in the notification centre, and a second job ends
// and is put back while the first one's question waits.
const restoringNow = new Set();
function restoreRuns(context, rsNow) {
    try {
        const list = handovers(context);
        if (!list.length) return Promise.resolve([]);
        const rs = rsNow === undefined ? readRunState() : rsNow;
        const now = Date.now(), keep = [], due = [];
        for (const r of list) {
            if (r.restored) { if (now - Date.parse(r.restored) < 30 * 60000) keep.push(r); continue; }
            if (!(now - Date.parse(r.at) < 2 * 86400000)) continue;
            keep.push(r);
            if (restoringNow.has(r.jobId)) continue;
            // the job running (again): a wait on its watch tab begun after an
            // earlier run of it counts from that run's end, so it starts over
            if (stillRunning(r, rs)) { tabWaits.delete(r.jobId); continue; }
            if (viewComing(r, now)) continue;
            due.push(r);
        }
        for (const r of due) restoringNow.add(r.jobId);
        const pruned = keep.length !== list.length ? putHandovers(context, keep) : Promise.resolve();
        // read, marked and written with no await between, so two passes -
        // and the other records' - never write over each other
        const mark = (id) => putHandovers(context, handovers(context).map(x => (x.jobId === id ? Object.assign({}, x, { restored: new Date().toISOString() }) : x)));
        return pruned.then(() => Promise.all(due.map(r => restoreHandover(r)
            .catch(e => { log('putting a chat back failed: ' + ((e && e.stack) || e)); return 'failed'; })
            .then(async how => { await mark(r.jobId); return how; })
            .finally(() => { restoringNow.delete(r.jobId); }))))
            .catch(e => { log('putting a chat back failed: ' + ((e && e.stack) || e)); return []; });
    } catch (e) {
        log('putting a chat back failed: ' + ((e && e.stack) || e));
        return Promise.resolve([]);
    }
}

// A chat handed over, its run over. Nothing holds it and no chatq run goes
// into it: its live view in front of you, or you away - the chat opened in
// the view's place, loaded from disk, and the view closed; else the view
// stays, showing how the run ended, with Open chat. A view closed already:
// away, the chat where its tab was; else asked. A process holding the chat
// by now - opened again mid-run, from Claude Code's own list - means a stale
// view somewhere: Show it, which closes its tab before it ends anything.
// Neither the question nor Show it - whose check takes seconds, and whose
// warnings wait on you - is waited for: the record is handled once they are
// up (restoreRuns).
async function restoreHandover(r) {
    const say = s => { log('run ' + String(r.sessionId || '').slice(0, 8) + ' (' + seqOf(r) + ') ended: ' + s); };
    if (r.provider === 'codex' || !isGuid(r.sessionId)) { say('no Claude chat to put back'); return 'none'; }
    const req = { kind: 'ran', sessionId: r.sessionId, title: r.title, cwd: r.cwd, home: r.home || null, oldProcess: 'live', hostPids: [process.pid], busy: null };
    if (liveRunFor(r.sessionId)) { say('another run goes into it - left to that one'); return 'running'; }
    const view = watchViews.get(r.jobId);
    if ((readRegistry(r.home || claudeHome(), Date.now()).get(r.sessionId) || []).length) {
        say('a process holds it again - Show it');
        showIt(req, signalFiles()[0]).catch(e => log('Show it failed: ' + ((e && e.stack) || e)));
        return 'show it';
    }
    const away = (lastRuns.get(r.jobId) || {}).away === true;
    // the tab the handover closed, opened again: a new process, so what the
    // old one alone had - Ultracode, a session-only level - is gone. Looked
    // at again as it opens - the question may have waited long, and the
    // chain held it: a process holding the chat by then is Show it's, as
    // above, nothing given or said. No process is no panel of it here but
    // where a Claude tab reads as the chat - one kept over a reload and not
    // revived yet, or one whose process exited - which is only revealed,
    // and Claude Code applies no prompt to it: the commands are named
    // instead. Else the new panel's input box takes the /effort that puts
    // it back - or, carried, its new process takes both, and the word on
    // it waits for that launch without holding the chain
    const open = (col, why) => enqueue(async () => {
        if (liveRunFor(r.sessionId)) return 'running';
        if ((readRegistry(r.home || claudeHome(), Date.now()).get(r.sessionId) || []).length) {
            say('a process holds it again - Show it');
            showIt(req, signalFiles()[0]).catch(e => log('Show it failed: ' + ((e && e.stack) || e)));
            return 'show it';
        }
        if (!hasClaude()) { vscode.window.showInformationMessage(texts.noClaude(req)); return 'no Claude'; }
        const lost = await lostByReopen(req, validStart(r.start));
        const before = allTabs().filter(isClaudeTab);
        const prompt = lost && lost.prefill && !oneTabOf(r.title, before) ? lost.prefill : undefined;
        const carrying = carryFor(req, lost);
        const how = await openCore(Object.assign({}, req, { kind: 'open', oldProcess: 'none', hostPids: [] }), before, why, col, prompt);
        if (how === 'new' || how === 'revealed') sayLost(req, lost, how === 'new' && !!prompt, carrying);
        return how;
    });
    // not opened now: armed for however it is opened meanwhile (armPutBack)
    const armLater = () => { putBackLast = armPutBack(req, validStart(r.start)); };
    if (view && !view.disposed) {
        if (!(view.panel.active || away)) { say('its live view shows how, with Open chat'); armLater(); return 'shown'; }
        const col = view.panel.viewColumn !== undefined ? view.panel.viewColumn : r.viewColumn;
        say('the chat in its live view\'s place' + (away ? ' - nobody at the PC' : ''));
        const how = await open(col, '(' + seqOf(r) + ' ended, in its live view\'s place)');
        if (how === 'new' || how === 'revealed') view.panel.dispose();
        return how;
    }
    if (away) { say('the chat where its tab was - nobody at the PC'); return open(r.viewColumn, '(' + seqOf(r) + ' ended, where its tab was)'); }
    const go = 'Open chat';
    say('its live view closed - asked');
    armLater();
    Promise.resolve(vscode.window.showInformationMessage(texts.ranClosed(r), go))
        .then(pick => (pick === go ? open(r.viewColumn, '(' + seqOf(r) + ' ended, asked)') : null))
        .catch(e => log('putting a chat back failed: ' + ((e && e.stack) || e)));
    return 'asked';
}

// --- the watch panel ------------------------------------------------------------
// One per job, a second open revealing it. It tails the job's log from where
// it last read, a line taken only once its newline has come, the first read
// at most the log's last 2 MB; and it watches the job file for the state,
// the question the phone is asked, and the end. retainContextWhenHidden:
// the page keeps its rows and its place while another tab is in front, and
// a window reload brings it back (the serializer).
const watchViews = new Map();
const watchIo = { firstRead: 2 * 1024 * 1024 };

function newNonce() { return require('crypto').randomBytes(18).toString('base64').replace(/[^A-Za-z0-9]/g, ''); }

// A play mark, '#15' and the title as Claude shortens it: a run going, done
// (a tick), or other (a square)
function watchTitle(job, title) {
    const j = job || {};
    const mark = !j.state || j.state === 'running' ? '\u25B6' : j.state === 'done' ? '\u2713' : '\u25A0';
    const t = j.title || title || '';
    return mark + ' #' + (j.seq === undefined || j.seq === null ? '?' : j.seq) + (t ? ' ' + claudeTabLabel(t) : '');
}

// Opens the job's live view, or brings forward the one open. o: viewColumn
// (claudeColumn's by default), preserveFocus, title (until the job file is
// read). The view, fresh when just made; null where none can be.
function openWatch(jobId, o) {
    const x = o || {};
    if (!validJobId(jobId)) { log('watch: not a job id: ' + jobId); return null; }
    const had = watchViews.get(jobId);
    if (had && !had.disposed) {
        try { had.panel.reveal(x.viewColumn, !!x.preserveFocus); } catch (e) { }
        had.fresh = false;
        return had;
    }
    if (!vscode.window.createWebviewPanel) return null;
    const col = x.viewColumn !== undefined && x.viewColumn !== null ? x.viewColumn : claudeColumn();
    const panel = vscode.window.createWebviewPanel(WATCH_TYPE, watchTitle(readJob(jobId), x.title), { viewColumn: col, preserveFocus: !!x.preserveFocus },
        { enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [] });
    const v = attachWatch(panel, jobId, x.title);
    v.fresh = true;
    log('watch ' + jobId + ': opened');
    return v;
}

// A panel made here, or brought back by the serializer, fed the job's log
// and job file.
function attachWatch(panel, jobId, title) {
    const v = { jobId, panel, title: title || '', parser: watch.newParser(), tail: { rest: null }, offset: 0, cut: false, lastAt: 0,
        job: null, running: false, prompt: '', head: '', ready: false, disposed: false, fresh: false };
    try { panel.webview.options = { enableScripts: true, localResourceRoots: [] }; } catch (e) { }
    panel.webview.html = watch.pageHtml(newNonce(), jobId);
    const logF = logFileOf(jobId), jobF = jobFileOf(jobId);
    const onLog = () => { if (readWatchLog(v, false)) { renderHead(v); postWatch(v, false); } };
    const onJob = () => { readWatchJob(v); postWatch(v, false); };
    fs.watchFile(logF, { interval: timing.runPoll }, onLog);
    fs.watchFile(jobF, { interval: timing.runPoll }, onJob);
    panel.webview.onDidReceiveMessage(m => { onWatchMessage(v, m).catch(e => log('watch ' + jobId + ': ' + ((e && e.stack) || e))); });
    panel.onDidDispose(() => {
        v.disposed = true;
        fs.unwatchFile(logF, onLog);
        fs.unwatchFile(jobF, onJob);
        if (watchViews.get(jobId) === v) watchViews.delete(jobId);
    });
    watchViews.set(jobId, v);
    readWatchJob(v);
    readWatchLog(v, true);
    renderHead(v);
    return v;
}

// The prompt as the header shows it: its first lines, from the job's prompt
// file as it is now; a continue, as that. Only the file's first bytes are
// read, and each line cut as clip() cuts a result: the header goes to the
// page with every row the log gains, and a pasted log line of megabytes
// would go with it each time. Pure but for the read.
const promptIo = { bytes: 4096, lines: 3, chars: 300 };
function promptOf(job) {
    if (!job) return '';
    if (job.kind === 'continue' || job.retryAs === 'continue') return 'continue (after the limit)';
    const f = String(job.promptFile || '');
    if (!f || /[\\/]|\.\./.test(f)) return '';
    let t, fd;
    try {
        fd = fs.openSync(path.join(dataDir(), 'queue', f), 'r');
        const b = Buffer.alloc(promptIo.bytes);
        let got = 0;
        while (got < b.length) {
            const n = fs.readSync(fd, b, got, b.length - got, got);
            if (n <= 0) break;
            got += n;
        }
        // a character cut where the read stopped is left out
        t = b.toString('utf8', 0, got).replace(/\uFFFD+$/, '');
    } catch (e) { return ''; }
    finally { if (fd !== undefined) try { fs.closeSync(fd); } catch (e) { } }
    t = t.replace(/^\uFEFF/, '').replace(/^\s*<!--\s*chatq:[\s\S]*?-->/, '').trim();
    return t.split(/\r?\n/).slice(0, promptIo.lines).map(l => (l.length > promptIo.chars ? l.slice(0, promptIo.chars) + '...' : l)).join('\n');
}

function readWatchJob(v) {
    const job = readJob(v.jobId);
    v.job = job;
    v.running = !!job && job.state === 'running';
    v.prompt = promptOf(job);
    try { v.panel.title = watchTitle(job, v.title); } catch (e) { }
    renderHead(v);
}

// Ultracode and the effort level the run keeps of the chat's: the job's own
// word, else run-state's last for it - all optional, as older scripts write
// neither
function renderHead(v) {
    const rs = lastRuns.get(v.jobId) || {};
    const ultracode = (!!v.job && v.job.ultracode === true) || rs.ultracode === true;
    const effort = (v.job && v.job.effort) || rs.effort || null;
    v.head = watch.headerHtml(v.job, { prompt: v.prompt, lastAt: v.lastAt, cut: v.cut, ultracode, effort });
}

// What the log has gained since the last read. A log shorter than was read
// is a new one: read from its start. True when a line was taken.
function readWatchLog(v, first) {
    let fd;
    try { fd = fs.openSync(logFileOf(v.jobId), 'r'); } catch (e) { return false; }
    try {
        const st = fs.fstatSync(fd);
        if (st.size < v.offset) { v.offset = 0; v.tail = { rest: null }; v.parser = watch.newParser(); v.reset = true; }
        let start = v.offset;
        if (first && st.size - start > watchIo.firstRead) { start = st.size - watchIo.firstRead; v.cut = true; }
        const len = st.size - start;
        if (len <= 0) return false;
        const buf = Buffer.alloc(len);
        let got = 0;
        while (got < len) {
            const n = fs.readSync(fd, buf, got, len - got, start + got);
            if (n <= 0) break;
            got += n;
        }
        v.offset = start + got;
        v.lastAt = st.mtimeMs;
        let lines = watch.takeLines(v.tail, buf.subarray(0, got));
        // the first line of a tail is cut in two
        if (first && v.cut) lines = lines.slice(1);
        // what was there before the view opened came at the log's last
        // write, as near as can be told
        const at = first ? st.mtimeMs : Date.now();
        for (const l of lines) v.parser.push(l, at);
        // a blank line - the newline ending the last one, come on its own -
        // makes no row, so the page is sent nothing for it
        return lines.some(l => l.trim()) || !!v.reset;
    } catch (e) {
        log('watch ' + v.jobId + ': reading its log failed: ' + (e && e.message));
        return false;
    } finally {
        try { fs.closeSync(fd); } catch (e) { }
    }
}

// To the page: everything, once it says it is ready, and after that only
// the rows that came or changed. Everything is the rows the parser keeps
// (watch.MAX_ROWS), and a word on how many went before them.
function postWatch(v, full) {
    if (!v.ready || v.disposed) return false;
    const all = full || v.reset;
    const rows = all ? v.parser.items : v.parser.dirty();
    if (all) v.parser.dirty();
    const gone = v.parser.dropped;
    const msg = { head: v.head, pin: watch.pinnedTodo(v.parser), running: v.running, rows: rows.map(it => ({ i: it.i, html: watch.itemHtml(it) })),
        earlier: gone ? gone + ' earlier rows are not kept here - Log has them' : '' };
    if (all) msg.reset = true;
    v.reset = false;
    try { v.panel.webview.postMessage(msg); } catch (e) { return false; }
    return true;
}

async function onWatchMessage(v, m) {
    const type = m && m.type;
    if (type === 'ready') { v.ready = true; return postWatch(v, true); }
    if (type === 'cancel') return cancelRun(v);
    if (type === 'log') {
        try { await command('vscode.open', vscode.Uri.file(logFileOf(v.jobId))); return 'log'; }
        catch (e) { log('watch ' + v.jobId + ': the log did not open: ' + (e && e.message)); return 'failed'; }
    }
    if (type === 'open') return openFromWatch(v);
    return 'unknown';
}

// Cancel: asked in a modal of VS Code's own - a webview shows no confirm() -
// then Stop-ChatqJobRun, through the loader, as the console's Stop does: a
// cancel file the run reads within seconds. The job file says the rest.
async function cancelRun(v) {
    const job = readJob(v.jobId) || { seq: '?', title: v.title };
    const go = 'Stop the run';
    const pick = await vscode.window.showWarningMessage(texts.cancelAsk(job), { modal: true }, go);
    if (pick !== go) return 'kept';
    const r = await psRun('$j = Find-ChatqJob ' + psQuote(v.jobId) + " -Exact; if ($j) { [Console]::Out.WriteLine('stop: ' + (Stop-ChatqJobRun $j)) } else { [Console]::Out.WriteLine('stop: no such job') }");
    const said = lastSaid(r && r.stdout, /^stop: /);
    log('watch ' + v.jobId + ': Cancel - ' + (said || 'no answer'));
    if (!said) { vscode.window.showWarningMessage(texts.cancelFailed(job)); return 'failed'; }
    return said.slice('stop: '.length);
}

// Open chat, once the run is over: the chat in the view's place, loaded
// from disk - what runs it read first, as the picker reads it. A run going
// into it by then: that run's view instead.
async function openFromWatch(v) {
    const job = readJob(v.jobId);
    if (!job || job.provider === 'codex' || !isGuid(job.sessionId)) return 'none';
    const run = liveRunFor(job.sessionId);
    if (run) { openWatch(run.jobId, { title: run.title }); return 'watch'; }
    const req = { kind: 'open', sessionId: job.sessionId, title: job.title, cwd: job.cwd, home: job.home || null, oldProcess: 'none', hostPids: [], file: job.path };
    const said = { title: job.title ? formatTitle(job.title) : '' };
    const state = chatState(readRegistry(job.home || claudeHome(), Date.now()).get(job.sessionId));
    const why = state === 'terminal' ? texts.pickTerminal : state === 'running' ? texts.pickRunning :
        state === 'working' && !oneTabOf(job.title, allTabs().filter(isClaudeTab)) ? texts.pickWorking : null;
    if (why) { vscode.window.showInformationMessage(why(said)); log('watch ' + v.jobId + ': Open chat refused - ' + state); return 'refused'; }
    if (!hasClaude()) { vscode.window.showInformationMessage(texts.noClaude(said)); return 'no Claude'; }
    const col = v.panel.viewColumn;
    return enqueue(async () => {
        // No process of the chat by the registry, and the run between ended
        // the one the tab had - so the new panel's input box takes what that
        // process alone had. But a Claude tab here reading as the chat - one
        // kept over a reload and not revived yet, or one whose process
        // exited - is only revealed, and Claude Code applies no prompt to it:
        // the commands are named instead. One running it, the open may only
        // reveal its panel: nothing given, nothing said. Read again here: the
        // chain may have held this open a while. Carried, the new process
        // takes both instead, and nothing goes into the box
        const none = chatState(readRegistry(job.home || claudeHome(), Date.now()).get(job.sessionId)) === 'closed';
        const lost = none ? await lostByReopen(req) : null;
        const before = allTabs().filter(isClaudeTab);
        const prompt = lost && lost.prefill && !oneTabOf(job.title, before) ? lost.prefill : undefined;
        const carrying = carryFor(req, lost);
        const how = await openCore(req, before, '(Open chat, #' + job.seq + ')', col, prompt);
        if (how === 'new' || how === 'revealed') {
            sayLost(req, lost, how === 'new' && !!prompt, carrying);
            v.panel.dispose();
        }
        return how;
    });
}

// Chat Manager: Watch the running queued prompt - the status bar item's too
function watchRun() {
    const rs = readRunState();
    if (!rs || !runIsLive(rs)) { vscode.window.showInformationMessage(texts.noRun); return 'none'; }
    return openWatch(rs.jobId, { title: rs.title }) ? 'watch' : 'failed';
}

// A window reload brings a watch panel back with its state, the job's id -
// and a run that ended meanwhile, whose chat waited for its panel
// (viewComing), is put back now, the panel there
function watchSerializer(context) {
    return {
        deserializeWebviewPanel: async (panel, state) => {
            const id = state && state.jobId;
            if (!validJobId(id) || (watchViews.get(id) && !watchViews.get(id).disposed)) { try { panel.dispose(); } catch (e) { } return; }
            attachWatch(panel, id);
            log('watch ' + id + ': brought back');
            // not waited for: VS Code waits on this before it shows the panel
            if (context) restoreRuns(context);
        }
    };
}

// --- the chat picker: Chat Manager: Open chat... -----------------------------
// This window's Claude chats, newest first, each opened as a tab through
// openCore - what the overlay's open chip does, without the overlay. What
// runs each one is read from the Claude home's own registry.

const PICK_CAP = 200;
// the part of a transcript read at either end: never a whole large file
const SPAN = 256 * 1024;
// the most transcripts read at once
const PICK_READS = 16;

// CLAUDE_CONFIG_DIR, as the Claude extension reads it, else ~/.claude
function claudeHome() {
    const d = String(process.env.CLAUDE_CONFIG_DIR || '').trim();
    return d ? expandHome(d) : path.join(os.homedir(), '.claude');
}

// Get-ChatSlug (src/core.ps1): the folder's whole path, every character that
// is not a letter or digit a dash. A drive's root keeps its slash. Pure.
function chatSlug(p) {
    let s = String(p || '').replace(/[\\/]+$/, '');
    if (s === '' || /^[A-Za-z]:$/.test(s)) s = String(p || '');
    return s.replace(/[^A-Za-z0-9]/g, '-');
}

// projects/<slug> of a folder. The slug keeps the case of the path it was
// made from, and VS Code hands a drive letter over in lower case, so one of
// another case is taken where the exact one is missing - on any system.
async function projectDir(home, folder) {
    const root = path.join(home, 'projects');
    const slug = chatSlug(folder);
    let names;
    try { names = await fsp.readdir(root); } catch (e) { return null; }
    const hit = names.includes(slug) ? slug : names.find(n => n.toLowerCase() === slug.toLowerCase());
    return hit ? path.join(root, hit) : null;
}

// Every folder's transcripts - <GUID>.jsonl in its project folder, nothing
// deeper - newest first by write time, the newest cap of them.
async function listChats(home, folders, cap) {
    const out = [], dirs = new Set();
    for (const f of folders || []) {
        const fp = f && f.uri ? f.uri.fsPath : '';
        const dir = fp ? await projectDir(home, fp) : null;
        if (!dir || dirs.has(dir.toLowerCase())) continue;
        dirs.add(dir.toLowerCase());
        let names;
        try { names = await fsp.readdir(dir); } catch (e) { continue; }
        const mine = names.filter(n => /\.jsonl$/i.test(n) && isGuid(n.slice(0, -6)));
        const folderName = f.name || path.basename(fp);
        const found = await Promise.all(mine.map(n => fsp.stat(path.join(dir, n)).then(st => st.isFile() ? {
            file: path.join(dir, n), dir, sid: n.slice(0, -6), size: st.size, mtimeMs: st.mtimeMs, folder: folderName, cwd: fp
        } : null, () => null)));
        for (const c of found) if (c) out.push(c);
    }
    out.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return out.slice(0, cap === undefined ? PICK_CAP : cap);
}

// Test-ChatNoise (src/core.ps1): a prompt that is machinery, not typed. Pure.
function isNoise(t) {
    return t.startsWith('<') || t.startsWith('Caveat') || /system-reminder/i.test(t) || /^\[Request interrupted/i.test(t);
}

// Format-ChatTitle (src/core.ps1): one line, cut at 60 characters. Pure.
function formatTitle(text, width) {
    const w = width || 60;
    if (!text) return '(empty)';
    let t = String(text).replace(/\s+/g, ' ').trim();
    if (t.length > w) t = t.substring(0, w).trimEnd() + '...';
    return t;
}

function parseLine(l) { try { return JSON.parse(l); } catch (e) { return null; } }

// the whole line around position at
function lineAt(text, at) {
    const s = text.lastIndexOf('\n', at) + 1;
    let e = text.indexOf('\n', at);
    if (e < 0) e = text.length;
    return [s, e];
}

// The newest record of that type holding a field of text, else ''. Pure.
function lastRecord(text, type, field) {
    const mark = '"type":"' + type + '"';
    for (let at = text.lastIndexOf(mark); at >= 0;) {
        const [s, e] = lineAt(text, at);
        const o = parseLine(text.slice(s, e));
        if (o && o.type === type && typeof o[field] === 'string' && o[field].trim()) return o[field].trim();
        if (s === 0) break;
        at = text.lastIndexOf(mark, s - 1);
    }
    return '';
}

// Read-ClaudePrompt (src/providers.ps1): a user record's text, as typed,
// one line - else '' for a tool result, a meta record or noise. Pure.
function readPrompt(line) {
    if (line.includes('"tool_result"') || line.includes('"isMeta":true') || /system-reminder/i.test(line)) return '';
    const o = parseLine(line);
    if (!o || o.type !== 'user' || !o.message) return '';
    let c = o.message.content;
    if (typeof c !== 'string') {
        c = Array.isArray(c) ? c.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join(' ') : '';
    }
    c = c.trim();
    if (!c || isNoise(c)) return '';
    return c.replace(/\s+/g, ' ');
}

// the first prompt typed, in the order written. Pure.
function firstPrompt(text) {
    const mark = '"type":"user"';
    for (let at = text.indexOf(mark); at >= 0;) {
        const [s, e] = lineAt(text, at);
        const t = readPrompt(text.slice(s, e));
        if (t) return t;
        at = text.indexOf(mark, e);
    }
    return '';
}

async function readSpan(fh, start, len) {
    const b = Buffer.alloc(len);
    const { bytesRead } = await fh.read(b, 0, len, start);
    return b.toString('utf8', 0, bytesRead);
}

async function readSidecar(dir, sid) {
    try {
        let raw = await fsp.readFile(path.join(dir, sid, 'custom-title.json'), 'utf8');
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        const o = JSON.parse(raw);
        return o && typeof o.customTitle === 'string' ? o.customTitle.trim() : '';
    } catch (e) { return ''; }
}

// One transcript, as the Claude extension would title it: a rename (a
// custom-title record, or the sidecar beside it), else its ai-title, else
// the first prompt typed - '' for none. Each record is looked for in the
// last 256 KB, newest first, and where the tail has none of that kind, in
// the first 256 KB - as the index's Describe (src/providers.ps1) does, so a
// large chat renamed early reads the same here and in chatfind. The prompt
// is looked for in the first 256 KB; a file of no more is read once, and
// the head of a larger one only when something is looked for there. { skip }
// for what the Claude extension lists not: a side transcript, flagged on its
// first line, and one of 64 KB or less that holds no message at all. null
// when it cannot be read.
async function readChat(c) {
    let fh;
    try { fh = await fsp.open(c.file, 'r'); } catch (e) { return null; }
    try {
        const size = c.size;
        let head = null;
        const headText = async () => {
            if (head === null) {
                head = await readSpan(fh, 0, Math.min(size, SPAN));
                // the last line, cut where the read stopped, is left out
                if (size > SPAN) head = head.slice(0, head.lastIndexOf('\n') + 1);
            }
            return head;
        };
        const start = size <= SPAN ? await headText() : await readSpan(fh, 0, 16384);
        const nl = start.indexOf('\n');
        if ((nl >= 0 ? start.slice(0, nl) : start).includes('"isSidechain":true')) return { skip: 'side' };
        let tail;
        if (size <= SPAN) tail = await headText();
        else {
            tail = await readSpan(fh, size - SPAN, SPAN);
            tail = tail.slice(tail.indexOf('\n') + 1);
        }
        if (size <= 65536 && !tail.includes('"type":"user"') && !tail.includes('"type":"assistant"')) return { skip: 'empty' };
        // a record of that kind at the tail, else at the head - which is the
        // tail itself for a file of no more than SPAN
        const either = async (type, field) => lastRecord(tail, type, field) ||
            (size > SPAN ? lastRecord(await headText(), type, field) : '');
        const title = await either('custom-title', 'customTitle') || await readSidecar(c.dir, c.sid) ||
            await either('ai-title', 'aiTitle') || firstPrompt(await headText());
        return { title };
    } catch (e) {
        log('pick: reading ' + c.file + ' failed: ' + (e && e.message));
        return null;
    } finally {
        try { await fh.close(); } catch (e) { }
    }
}

// by path, size and write time, for the extension's life
const titleCache = new Map();
function cachedChat(c) {
    const hit = titleCache.get(c.file);
    return hit && hit.size === c.size && hit.mtimeMs === c.mtimeMs ? hit.d : undefined;
}
async function describeChat(c) {
    const hit = cachedChat(c);
    if (hit) return hit;
    const d = await module.exports._readChat(c);
    if (d) titleCache.set(c.file, { size: c.size, mtimeMs: c.mtimeMs, d });
    return d;
}

// Does another chat carry the tab label this title gets? A Claude tab
// carries no session id, only its label, so while another chat could show
// the same one - the same title, or the same first 24 characters - no tab
// here reading as the chat can be told for its own: counted as the chat's,
// a second copy of a working chat would be let through, or the other chat's
// tab closed. A tab of this window may be any of its folders' chats, so
// every workspace folder is looked in, and the chat's own folder beside
// them. Each folder's newest PICK_CAP transcripts - what the picker lists -
// are read as the picker reads them, newest first, and kept by path, size
// and write time, so a second look reads only what changed. The read gets
// timing.labelBudget: one not done by then answers shared, the safe side -
// a tab left, or a chat not opened, and said - and is logged. A chat of no
// title shares nothing: no tab is taken for it anyway. home, the request's
// Claude home, else this window's.
async function labelShared(title, cwd, sid, home) {
    if (!title) return false;
    const want = claudeTabLabel(title);
    const me = String(sid || '').toLowerCase();
    const dirs = (vscode.workspace.workspaceFolders || []).concat(cwd ? [{ uri: { fsPath: cwd } }] : []);
    const ms = timing.labelBudget;
    let over = false, timer = null;
    const scan = async () => {
        const seen = new Set(), others = [];
        // one folder at a time: the cap is each folder's own
        for (const d of dirs) {
            if (over) return false;
            for (const c of await listChats(home || claudeHome(), [d], PICK_CAP)) {
                const k = c.file.toLowerCase();
                if (seen.has(k) || c.sid.toLowerCase() === me) continue;
                seen.add(k);
                others.push(c);
            }
        }
        others.sort((a, b) => b.mtimeMs - a.mtimeMs);
        for (let i = 0; i < others.length; i += PICK_READS) {
            if (over) return false;
            const ds = await Promise.all(others.slice(i, i + PICK_READS).map(describeChat));
            if (ds.some(d => d && !d.skip && d.title && claudeTabLabel(d.title) === want)) return true;
        }
        return false;
    };
    if (!(ms > 0)) return scan();
    const late = new Promise(r => { timer = setTimeout(() => { over = true; r('late'); }, ms); });
    try {
        const r = await Promise.race([scan(), late]);
        if (r !== 'late') return r;
        log('label ' + me.slice(0, 8) + ': its folders\' chats not all read in ' + ms + ' ms - taken as shared');
        return true;
    } finally { clearTimeout(timer); }
}

// Is a registry entry's process still that session? Its pid answers - a
// process of another user's is there too (EPERM) - and its startedAt is
// neither in the future nor from before this machine last started, which
// catches most files a crash left behind for a pid handed on since. A pid
// handed on since boot answers too: liveRegistry looks at the process
// itself where it can (procFacts).
function entryLive(o, now) {
    const at = Number(o.startedAt);
    if (Number.isFinite(at) && at > 0) {
        const boot = now - os.uptime() * 1000;
        if (at > now + 60000 || at < boot - 60000) return false;
    }
    return module.exports._alive(o.pid);
}

// sessions/<pid>.json, the live ones, by session id
function readRegistry(home, now) {
    const dir = path.join(home, 'sessions');
    const by = new Map();
    let names;
    try { names = fs.readdirSync(dir); } catch (e) { return by; }
    for (const n of names) {
        if (!/^\d+\.json$/.test(n)) continue;
        let raw;
        try { raw = fs.readFileSync(path.join(dir, n), 'utf8'); } catch (e) { continue; }
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        const o = parseLine(raw);
        if (!o || !Number.isInteger(o.pid) || o.pid <= 0 || !isGuid(o.sessionId) || !entryLive(o, now)) continue;
        if (!by.has(o.sessionId)) by.set(o.sessionId, []);
        by.get(o.sessionId).push(o);
    }
    return by;
}

// --- a registry entry's process, as the OS has it ----------------------------
// What node cannot read of another process: when it started, and its
// parent. On Windows one Windows PowerShell asks CIM (Win32_Process) for
// every pid at once - about a second, for any number; wmic is gone from
// Windows 11, and tasklist knows neither - and each answer is kept
// timing.procFresh by pid, so the picker and the pick after it ask once.
// Elsewhere nothing is asked and nothing known: the registry is taken as
// entryLive has it. Replaced by the tests: they never start PowerShell.
const procIo = {
    platform: () => process.platform,
    // the script's output, '' where it did not run to its end
    run: (script, ms) => new Promise(resolve => {
        try {
            cp.execFile(windowsPowerShell(), ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
                { timeout: ms, windowsHide: true, maxBuffer: 1 << 20 }, (err, out) => resolve(err ? '' : String(out || '')));
        } catch (e) { resolve(''); }
    })
};

// One line per process that is there, its fields split by | - which no
// process name holds, a Windows file name never does: its pid, its start
// as a FILETIME - the registry's procStart - its parent's pid and start,
// its name, and its parent's name as Get-Process has it ("Code"). A parent
// that is gone, or not this user's to read, starts at 0 and has no name.
// Pure.
function procScript(pids) {
    const filter = pids.map(p => 'ProcessId=' + p).join(' OR ');
    return "$ErrorActionPreference = 'SilentlyContinue'\n" +
        "foreach ($p in @(Get-CimInstance Win32_Process -Filter '" + filter + "')) {\n" +
        "  $st = if ($p.CreationDate) { $p.CreationDate.ToFileTimeUtc() } else { 0 }\n" +
        "  $pp = Get-Process -Id ([int]$p.ParentProcessId)\n" +
        "  $ps = 0; $pn = ''\n" +
        "  if ($pp) { $pn = [string]$pp.ProcessName; try { $ps = $pp.StartTime.ToFileTimeUtc() } catch { $ps = 0 } }\n" +
        "  [Console]::Out.WriteLine(('proc|{0}|{1}|{2}|{3}|{4}|{5}' -f $p.ProcessId, $st, $p.ParentProcessId, $ps, $p.Name, $pn))\n" +
        "}\n";
}

// procScript's lines, by pid. FILETIMEs stay strings: they are past 2^53.
// Pure.
function parseProcs(text) {
    const out = new Map();
    for (const line of String(text || '').split(/\r?\n/)) {
        const m = /^proc\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|([^|]+)\|([^|]*)$/.exec(line.trim());
        if (m) out.set(Number(m[1]), { start: m[2], ppid: Number(m[3]), parentStart: m[4], name: m[5], parentName: m[6] });
    }
    return out;
}

// pid -> { at, f }: f null for a pid asked about that was not there. One
// look at a time is asked for: a pick while the picker's own look is out
// waits for that one rather than start a second PowerShell.
const procSeen = new Map();
let procAsking = null;
async function procFacts(pids, now) {
    const out = new Map();
    const io = module.exports._procIo;
    if (io.platform() !== 'win32') return out;
    const t = now === undefined ? Date.now() : now;
    const ask = [];
    for (const p of new Set(pids)) {
        if (!Number.isInteger(p) || p <= 0) continue;
        const hit = procSeen.get(p);
        if (hit && t - hit.at >= 0 && t - hit.at < timing.procFresh) { if (hit.f) out.set(p, hit.f); }
        else ask.push(p);
    }
    if (!ask.length) return out;
    // what the look found, fresh: one that failed leaves an older answer out
    const keep = () => {
        for (const p of ask) {
            const hit = procSeen.get(p);
            if (hit && hit.f && Math.abs(t - hit.at) < timing.procFresh) out.set(p, hit.f);
        }
        return out;
    };
    if (procAsking && ask.every(p => procAsking.pids.has(p))) { await procAsking.done; return keep(); }
    const asking = { pids: new Set(ask), done: null };
    asking.done = (async () => {
        const got = parseProcs(await io.run(procScript(ask), timing.procTimeout));
        // none at all is a query that failed, or pids all gone since: either
        // way nothing is kept, and entryLive's answer stands
        if (!got.size) { log('processes ' + ask.join(',') + ': their start and parent could not be read'); return; }
        for (const p of ask) procSeen.set(p, { at: t, f: got.get(p) || null });
    })().catch(e => log('processes ' + ask.join(',') + ': ' + (e && e.message)));
    procAsking = asking;
    try { await asking.done; } finally { if (procAsking === asking) procAsking = null; }
    return keep();
}

function ftMs(ft) { return Number(BigInt(ft) / 10000n) - 11644473600000; }

// Is the process an entry's pid names now still that entry's? The rules of
// Test-ChatqSessionAlive (src/live-chats.ps1) and Test-ChatqClaudeProcess
// (src/watcher.ps1): a claude or node, started when procStart says - to
// 3 s, where it is a FILETIME, as on Windows - and never more than 10 s
// after startedAt. A start not read (0) says nothing. Pure.
function startFits(o, f) {
    if (!/^(claude|node)/i.test(f.name)) return false;
    const began = /^\d{17,}$/.test(f.start) ? BigInt(f.start) : null;
    if (began === null) return true;
    const ps = String(o.procStart === undefined || o.procStart === null ? '' : o.procStart);
    if (/^\d{17,}$/.test(ps)) {
        const d = BigInt(ps) - began;
        if (d > 30000000n || d < -30000000n) return false;
    }
    const at = Number(o.startedAt);
    if (Number.isFinite(at) && at > 0 && ftMs(began) - at > 10000) return false;
    return true;
}

// Which window a VS Code panel's process is in: its parent is the
// extension host of the window that started it, as the script's hostPids
// has it (S30, Test-ChatVsCodeOwned in src/live-chats.ps1) - 'here' where
// that is this extension's host, 'window' for another Code that is still
// there, '' where it cannot be told: not a VS Code panel, a start not read,
// a parent of another name, or one that started after the process did -
// its pid handed on since. Pure but for alive.
function whereOf(o, f) {
    if (o.entrypoint !== 'claude-vscode' || !(f.ppid > 0)) return '';
    if (!/^\d{17,}$/.test(f.start) || !/^\d{17,}$/.test(f.parentStart) || BigInt(f.parentStart) > BigInt(f.start)) return '';
    if (f.ppid === process.pid) return 'here';
    return /^Code( - Insiders)?$/i.test(f.parentName || '') && module.exports._alive(f.ppid) ? 'window' : '';
}

// readRegistry's entries, those whose process is not theirs any more left
// out, and each of the rest with where it runs and its host (whereOf). An
// entry of no facts is kept as it was. Pure but for alive.
function withFacts(by, facts) {
    const out = new Map();
    for (const [sid, es] of by) {
        const keep = [];
        for (const o of es) {
            const f = facts && facts.get(o.pid);
            if (f && !startFits(o, f)) continue;
            keep.push(f ? Object.assign({}, o, { where: whereOf(o, f), host: f.ppid }) : o);
        }
        if (keep.length) out.set(sid, keep);
    }
    return out;
}

// the live entries, by session id, each process looked at where it can be
async function liveRegistry(home, now) {
    const by = readRegistry(home, now);
    const pids = [];
    for (const es of by.values()) for (const o of es) pids.push(o.pid);
    return withFacts(by, pids.length ? await procFacts(pids, now) : new Map());
}

// Where the VS Code panels holding a chat are: 'here' - all in this
// window, 'window' - all in others, '' - some of each, a terminal's among
// them, or any that cannot be told. Pure.
function placeOf(entries) {
    const ws = new Set((entries || []).map(e => e.where || ''));
    return ws.size === 1 ? [...ws][0] : '';
}

// the other windows' hosts holding it
function hostsOf(entries) {
    return [...new Set((entries || []).filter(e => e.where === 'window').map(e => e.host))];
}

// A chat another window holds, handed to it through data/open-request as
// the overlay's open chip hands one (Write-ChatOpenRequest,
// src/chatrm.ps1): the same fields, and hostPids its windows, so only they
// act on it. There it is openTab's: its tab brought forward, or - working
// outside the tabs - said, and never a second copy. The chip's own file, so
// a chip's click within the same 2 s poll replaces it, as one click
// replaces another. The request or null.
function handToWindow(c, title, busy, hostPids, home) {
    const file = openFiles()[0];
    const req = {
        id: require('crypto').randomUUID(), kind: 'open', sessionId: c.sid, cwd: c.cwd, title,
        home: String(process.env.CLAUDE_CONFIG_DIR || '').trim() ? home : null,
        busy: null, oldProcess: busy ? 'held' : 'live', hostPids, file: c.file, at: new Date().toISOString()
    };
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify(req));
        return req;
    } catch (e) {
        log('pick ' + c.sid.slice(0, 8) + ': ' + file + ' could not be written: ' + (e && e.message));
        return null;
    }
}

// What runs a chat, from its live entries. Pure.
//   closed    nothing: it opens from disk
//   running   a run of no one's typing - a kind set and not interactive, or
//             an SDK's entrypoint (sdk-cli, sdk-ts, sdk-py): chatq's queued
//             prompt, claude -p, which Claude Code 2.1.283 registers as
//             interactive with sdk-cli - is writing to it now
//   terminal  a claude of a terminal holds it: an entrypoint other than
//             claude-vscode
//   working   a VS Code panel holds it - or an entry naming no entrypoint -
//             mid-turn or waiting on a prompt
//   open      the same, idle
function chatState(entries) {
    if (!entries || !entries.length) return 'closed';
    if (entries.some(e => (e.kind && e.kind !== 'interactive') || SDK_ENTRYPOINTS.has(e.entrypoint))) return 'running';
    // a terminal only by an entrypoint that says so: none at all is no
    // terminal, as the script's where has it (an empty where)
    if (entries.some(e => e.entrypoint && e.entrypoint !== 'claude-vscode')) return 'terminal';
    if (entries.some(e => e.status === 'busy' || e.status === 'waiting')) return 'working';
    return 'open';
}

// Get-ChatAge (src/core.ps1). Pure.
function ageText(ms) {
    const s = ms / 1000;
    if (s < 60) return 'now';
    if (s < 3600) return Math.floor(s / 60) + 'm';
    if (s < 86400) return Math.floor(s / 3600) + 'h';
    if (s < 2592000) return Math.floor(s / 86400) + 'd';
    if (s < 31536000) return Math.floor(s / 2592000) + 'mo';
    return Math.floor(s / 31536000) + 'y';
}

const STATE_ICON = { running: '$(play) ', terminal: '$(terminal) ', working: '$(sync~spin) ', open: '$(window) ', closed: '' };
const STATE_WORD = { running: 'a queued prompt running', terminal: 'in a terminal', working: 'working', open: 'open', closed: '' };

// VS Code draws $(name) in a QuickPick's text as a codicon, and a backslash
// before it keeps it as typed: a chat titled "$(x)" reads as that. Only a
// whole codicon pattern is escaped, and one escaped already left, as VS
// Code's own escapeIcons does: any other "$(" - "echo $(git rev-parse
// HEAD)" - is drawn as typed, and a backslash put before it would show.
// Pure.
const ICON = /(\\)?\$\([A-Za-z0-9-]+(?:~[A-Za-z]+)?\)/g;
function noIcons(s) { return String(s).replace(ICON, (m, escaped) => (escaped ? m : '\\' + m)); }

// One chat's line in the picker; d undefined while its title is being read
// shows its id. place: placeOf its entries, said of a chat open or working
// where it is known. Pure.
function pickItem(c, d, state, multi, now, place) {
    const held = state === 'open' || state === 'working';
    const word = (STATE_WORD[state] || '') + (held && place === 'here' ? ' in this window' : held && place === 'window' ? ' in another window' : '');
    const item = {
        label: (STATE_ICON[state] || '') + (d ? noIcons(formatTitle(d.title)) : c.sid),
        description: ageText(now - c.mtimeMs) + (word ? ' \u00b7 ' + word : ''),
        chat: c, state
    };
    if (multi) item.detail = noIcons(c.folder);
    return item;
}

// The picker. It is up at once, busy; the chats are listed as soon as their
// titles are read, or at pickBudget with each one not read yet by its id,
// and those are filled in as they come - the item under the cursor kept.
// Resolves once a chat is opened, refused, or nothing picked.
async function openChat() {
    const home = claudeHome();
    const folders = vscode.workspace.workspaceFolders || [];
    const multi = folders.length > 1;
    const qp = vscode.window.createQuickPick();
    qp.placeholder = 'A chat of this window to open in a tab';
    qp.matchOnDescription = true;
    qp.matchOnDetail = true;
    qp.busy = true;
    const picked = new Promise(resolve => {
        qp.onDidAccept(() => { const it = (qp.selectedItems || [])[0] || (qp.activeItems || [])[0]; resolve(it); qp.hide(); });
        qp.onDidHide(() => resolve(undefined));
    });
    qp.show();
    const now = Date.now();
    const chats = await listChats(home, folders, PICK_CAP);
    // the registry at once; each process looked at beside the titles'
    // reads, and the list put again with what that finds (liveRegistry)
    let states = readRegistry(home, now);
    const known = new Map();
    for (const c of chats) { const d = cachedChat(c); if (d) known.set(c.file, d); }
    // over: picked or dismissed, and the picker gone - nothing more put in it
    let shown = false, over = false, timer = null;
    const put = () => {
        if (timer) { clearTimeout(timer); timer = null; }
        if (over) return;
        const was = (qp.activeItems || [])[0];
        const items = [];
        for (const c of chats) {
            const d = known.get(c.file);
            if (d && d.skip) continue;
            const es = states.get(c.sid);
            items.push(pickItem(c, d, chatState(es), multi, now, placeOf(es)));
        }
        qp.items = items;
        const keep = was && items.find(i => i.chat.sid === was.chat.sid);
        if (keep) qp.activeItems = [keep];
        shown = true;
    };
    const later = () => { if (shown && !timer) timer = setTimeout(put, 100); };
    const todo = chats.filter(c => !known.has(c.file));
    let next = 0;
    const worker = async () => {
        while (next < todo.length) {
            const c = todo[next++];
            const d = await describeChat(c);
            if (d) known.set(c.file, d);
            later();
        }
    };
    const reading = Promise.all(Array.from({ length: Math.min(PICK_READS, todo.length) }, worker));
    const pids = [];
    for (const es of states.values()) for (const o of es) pids.push(o.pid);
    if (pids.length) {
        procFacts(pids, now).then(facts => { if (facts.size) { states = withFacts(states, facts); later(); } },
            e => log('pick: ' + (e && e.message)));
    }
    await Promise.race([reading, sleep(timing.pickBudget)]);
    put();
    if (!chats.length) qp.placeholder = 'No Claude chats in this window\'s folders';
    reading.then(() => { put(); if (!over) qp.busy = false; }, e => log('pick: ' + (e && e.message)));
    const it = await picked;
    over = true;
    if (timer) { clearTimeout(timer); timer = null; }
    try { qp.dispose(); } catch (e) { }
    if (!it || !it.chat) return 'none';
    return acceptChat(it.chat);
}

// A chat picked. What runs it is read again: the picker may have been open
// a while. A terminal holds it, or a queued prompt goes into it: never.
// Working in VS Code: only its one tab here brought forward - anything else
// starts a second copy mid-answer - and where its process says it is in
// another window (whereOf), handed to that window (handToWindow), which
// brings its tab forward there. Open idle elsewhere - another window, or
// the side bar, which the open (openCall) does not look at - only when
// asked; in another window, Show it there hands it over instead. Nothing
// runs it: opened from disk. Its one tab here counts only while no other
// chat of its folder shares the tab's label. And it is read once more
// after the question, which may sit unanswered for minutes, and again right
// before the open, which may wait behind another show: what began to work
// meanwhile is refused as it would have been at once.
async function acceptChat(c) {
    const home = claudeHome();
    const d = await describeChat(c);
    const title = d && !d.skip ? d.title : '';
    // the title as written for the tabs, and shortened for what is said
    const req = { kind: 'pick', sessionId: c.sid, title, cwd: c.cwd, file: c.file };
    const said = { title: title ? formatTitle(title) : '' };
    let state, place = '', hosts = [];
    // what runs it now, where, and whether it has a tab here that is surely
    // its own
    const look = async () => {
        const es = (await liveRegistry(home, Date.now())).get(c.sid);
        state = chatState(es);
        place = placeOf(es);
        hosts = hostsOf(es);
        if (state !== 'working' && state !== 'open') return false;
        return !!oneTabOf(title, allTabs().filter(isClaudeTab)) && !(await labelShared(title, c.cwd, c.sid, home));
    };
    // said and true where it may not be opened as it stands
    const refused = (tab) => {
        const why = state === 'terminal' ? texts.pickTerminal : state === 'running' ? texts.pickRunning :
            state === 'working' && !tab ? (place === 'here' ? texts.pickWorkingHere : texts.pickWorking) : null;
        if (why) vscode.window.showInformationMessage(why(said));
        return !!why;
    };
    // held in other windows alone, with no tab here: theirs to show
    const theirs = (tab) => (state === 'working' || state === 'open') && !tab && place === 'window' && hosts.length > 0;
    const handOver = () => {
        const sent = handToWindow(c, title, state === 'working', hosts, home);
        vscode.window.showInformationMessage((sent ? texts.pickHanded : texts.pickNotHanded)(said));
        return done(sent ? 'handed to ' + hosts.join(',') : 'not handed');
    };
    const done = (outcome) => { log('pick ' + c.sid.slice(0, 8) + ': ' + state + ' -> ' + outcome); return outcome; };
    // A queued prompt of chatq's going into it - from the handover, before
    // its run has a registry entry, to the end: its live view, where the
    // chat itself would start a second writer. Looked at first, and again
    // right before the open.
    const watched = () => {
        const run = liveRunFor(c.sid);
        if (!run) return false;
        state = state || 'running';
        openWatch(run.jobId, { title: run.title });
        return true;
    };
    if (watched()) return done('watch');
    let tab = await look();
    if (state === 'working' && theirs(tab)) return handOver();
    if (refused(tab)) return done('refused');
    if (state === 'open' && !tab) {
        const go = 'Open here too', there = 'Show it there';
        const inWindow = theirs(tab);
        const ask = inWindow ? texts.pickThere : place === 'here' ? texts.pickSideBar : texts.pickElsewhere;
        const pick = await (inWindow ? vscode.window.showWarningMessage(ask(said), there, go, 'Cancel') :
            vscode.window.showWarningMessage(ask(said), go, 'Cancel'));
        if (pick !== go && pick !== there) return done('cancelled');
        tab = await look();
        if (pick === there) {
            if (theirs(tab)) return handOver();
            // left that window meanwhile: here only where that is its tab,
            // or nothing holds it now - never a second copy unasked
            if (refused(tab)) return done('refused');
            if (state !== 'closed' && !tab) { vscode.window.showInformationMessage(texts.pickMoved(said)); return done('moved'); }
        }
        if (refused(tab)) return done('refused');
    }
    if (!hasClaude()) { vscode.window.showInformationMessage(texts.noClaude(said)); return done('no Claude'); }
    const how = await enqueue(async () => {
        if (watched()) return 'watch';
        if (refused(await look())) return 'refused';
        return openCore(req, allTabs().filter(isClaudeTab), '(picked, ' + state + ')');
    });
    return done(how || 'failed');
}

// The extension this one replaces, VS Code chat manager - reload. Both would
// act on every request, and a window would reload twice, so while it is
// installed and watches the same file, this one handles none, and one window
// offers to remove it.
function oldExtension() {
    return !!(vscode.extensions && vscode.extensions.getExtension && vscode.extensions.getExtension(setup.OLD_ID));
}

// Does the old one watch the file this one would? It read only its own
// signalFile, else the default place. Where chatManager.folder points
// elsewhere, it watches a file nobody writes, and this one takes over.
function oldWatchesMine() {
    const sig = oldSignalFile();
    const oldFile = sig ? expandHome(sig) : path.join(DEFAULT_FOLDER(), 'data', 'reload-request');
    return path.resolve(oldFile).toLowerCase() === path.resolve(signalFiles()[0]).toLowerCase();
}

async function askToRemoveOld() {
    const data = path.join(toolFolder(), 'data');
    // left in place: it keeps the other windows from asking for 10 minutes.
    // A data/ that cannot be written asks anyway.
    try {
        fs.mkdirSync(data, { recursive: true });
        if (!setup._takeLock(path.join(data, 'old-extension.lock'), Date.now(), 10 * 60 * 1000)) return 'elsewhere';
    } catch (e) { log('cannot write ' + data + ' (' + (e && e.message) + '): asking anyway'); }
    const go = 'Uninstall it';
    if (await vscode.window.showWarningMessage(texts.oldThere, go, 'Not now') !== go) return 'kept';
    try { await vscode.commands.executeCommand('workbench.extensions.uninstallExtension', setup.OLD_ID); }
    catch (e) {
        log('uninstalling ' + setup.OLD_ID + ' failed: ' + (e && e.message));
        vscode.window.showWarningMessage(texts.oldStuck);
        return 'failed';
    }
    const r = 'Reload';
    if (await vscode.window.showInformationMessage(texts.oldGone, r) === r) await safe._guardReload(false, null);
    return 'removed';
}

// The terminal half (setup.js), once at a time per window: at start, and
// from the command palette, which asks again even after Never - and, asked
// for while a start's run is going, runs after it rather than not at all.
// onReady: called once the loader is in place, before the profile question.
// One given to a run that joins the one going is that run's too: called when
// its loader is ready, or at once where it was ready already; and never where
// that run leaves the loader to another window, or fails to copy it.
let settingUp = null, readyNow = null;
function runSetup(context, force, onReady) {
    if (settingUp) {
        if (onReady) readyNow.add(onReady);
        return force ? settingUp.then(() => runSetup(context, true)) : settingUp;
    }
    const run = { ready: false, waiting: [] };
    const call = (f) => { try { f(); } catch (e) { log('setup: onReady failed: ' + (e && e.message)); } };
    readyNow = { add: (f) => { if (run.ready) call(f); else run.waiting.push(f); } };
    if (onReady) run.waiting.push(onReady);
    const ready = () => { run.ready = true; for (const f of run.waiting.splice(0)) call(f); };
    settingUp = setup.setUp({ extensionPath: context.extensionPath, folder: toolFolder(), log, force, onReady: ready })
        .catch(e => log('setup failed: ' + ((e && e.stack) || e)))
        .finally(() => { settingUp = null; readyNow = null; });
    return settingUp;
}

// Test-ChatqLockHeld (src/alerts.ps1), in node. The overlay holds
// data/overlay.lock open with no sharing for its whole life, and the OS lets
// go of it even when the process dies hard, so a lock that cannot be opened
// is held - EBUSY on Windows, EPERM or the like elsewhere. Missing, or opened
// and closed again, nobody holds it. On a Mac that lock is only advisory and
// always opens here; Start-ChatOverlayAuto looks again, and says running.
function lockHeld(file) {
    let fd;
    try { fd = fs.openSync(file, 'r+'); }
    catch (e) { return !(e && e.code === 'ENOENT'); }
    try { fs.closeSync(fd); } catch (e) { }
    return false;
}

// Everything startOverlay reads of the machine, replaced by the tests.
// powershell: Windows PowerShell's own path on Windows, never setup's
// hosts(), whose look on PATH for pwsh is a where.exe of up to 5 s, run
// synchronously, on every activation; elsewhere pwsh, as hosts() finds it -
// once for the host's life: a reload's wait asks every 25 s, and each look
// would hold every extension of the window. One installed later is found
// after the next reload.
let pwshFound;
const overlayIo = {
    platform: () => process.platform,
    readFile: (f) => fs.readFileSync(f, 'utf8'),
    exists: (f) => fs.existsSync(f),
    lockHeld,
    powershell: (platform) => {
        if (platform !== 'win32') {
            if (pwshFound === undefined) pwshFound = setup._hosts()[0] || null;
            return pwshFound;
        }
        const ps = windowsPowerShell();
        return module.exports._overlayIo.exists(ps) ? ps : null;
    }
};

// The overlay, started with the window. data/config.json's overlay.autoStart
// is the one switch - chatoverlay -AutoStart on|off sets it - and a missing
// file or key reads as the default: on for Windows, off on a Mac, where the
// panel is untested. A config.json there that cannot be read, or does not
// parse, reads as off: it may be the one that turned the overlay off. Once
// per activation: only a start that ran PowerShell counts, so a look made
// before the setup had put the loader in place does not use it up. The
// script's Start-ChatOverlayAuto has the last word, printed as one of
// started, running, off or failed; the checks here only spare a PowerShell
// where the answer is known. PowerShell is run through setup's exports, so
// the tests can stand in for it. Never throws: what went wrong is logged.
const overlayStarted = new WeakSet();
async function startOverlay(context) {
    try {
        if (overlayStarted.has(context)) return 'already';
        const io = module.exports._overlayIo;
        const platform = io.platform();
        if (platform !== 'win32' && platform !== 'darwin') return 'no panel';
        const folder = toolFolder();
        const cfgFile = path.join(folder, 'data', 'config.json');
        let raw = null;
        try { raw = io.readFile(cfgFile); }
        catch (e) {
            if (!(e && e.code === 'ENOENT')) { log('overlay: ' + cfgFile + ' cannot be read (' + (e && e.message) + '), so taken as off'); return 'off'; }
        }
        let cfg = null;
        if (raw !== null) {
            if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
            try { cfg = JSON.parse(raw); }
            catch (e) { log('overlay: ' + cfgFile + ' does not parse, so taken as off'); return 'off'; }
        }
        const auto = cfg && typeof cfg === 'object' && cfg.overlay ? cfg.overlay.autoStart : undefined;
        if (auto === false || (auto !== true && platform !== 'win32')) { log('overlay: autoStart is off'); return 'off'; }
        const loader = path.join(folder, setup.LOADER);
        if (!io.exists(loader)) { log('overlay: no ' + loader + ', so not started'); return 'no loader'; }
        if (io.lockHeld(path.join(folder, 'data', 'overlay.lock'))) { log('overlay: running'); return 'running'; }
        const exe = io.powershell(platform);
        if (!exe) { log('overlay: no PowerShell found'); return 'failed'; }
        // marked before the await: a second call while this one runs finds it
        overlayStarted.add(context);
        const r = await setup._runPs(exe, loader, 'Start-ChatOverlayAuto', 60000, log);
        const words = String((r && r.stdout) || '').split(/\r?\n/).map(s => s.trim()).filter(s => /^(started|running|off|failed)$/.test(s));
        const said = words.length ? words[words.length - 1] : 'failed';
        log('overlay: ' + said);
        return said;
    } catch (e) {
        log('starting the overlay failed: ' + ((e && e.message) || e));
        return 'failed';
    }
}

// The last word of an answer's lines that matches, else ''. Pure.
function lastSaid(stdout, re) {
    const hit = String(stdout || '').split(/\r?\n/).map(s => s.trim()).filter(s => re.test(s));
    return hit.length ? hit[hit.length - 1] : '';
}

// Chat Manager: Overlay: start by itself... - the one switch, set as
// chatoverlay -AutoStart on|off sets it, without a terminal: the owner who
// never installed the terminal commands has no other way to stop it. Off
// also closes a running overlay through chatoverlay -Stop, so it is off now
// and not only at the next start. Run through the tool folder's loader and
// setup's runPs, as startOverlay is, so the tests stand in for PowerShell;
// the script's own lines say whether it took. Never throws.
async function overlayAutoStart() {
    const io = module.exports._overlayIo;
    const done = (outcome) => { log('overlay autoStart: ' + outcome); return outcome; };
    try {
        const platform = io.platform();
        if (platform !== 'win32' && platform !== 'darwin') {
            vscode.window.showInformationMessage(texts.autoStartNoPanel);
            return done('no panel');
        }
        const folder = toolFolder();
        const loader = path.join(folder, setup.LOADER);
        // said before the question: an answer could not be applied anyway
        if (!io.exists(loader)) {
            vscode.window.showWarningMessage(texts.autoStartNoLoader(folder));
            return done('no loader in ' + folder);
        }
        const pick = await vscode.window.showQuickPick([
            { label: 'On', description: 'with every shell and VS Code window', value: 'on' },
            { label: 'Off', description: 'only when chatoverlay starts it; a running one is closed', value: 'off' }
        ], { placeHolder: texts.autoStartAsk });
        if (!pick || !pick.value) return done('nothing picked');
        const exe = io.powershell(platform);
        if (!exe) { vscode.window.showWarningMessage(texts.autoStartFailed); return done(pick.value + ' - no PowerShell found'); }
        // Write-Host is the information stream: *>&1 brings it to stdout
        const r = await setup._runPs(exe, loader, 'chatoverlay -AutoStart ' + pick.value + ' *>&1 | Out-String -Width 200', 60000, log);
        const set = lastSaid(r && r.stdout, /^start with every shell and VS Code window: (on|off)$/);
        if (!(r && r.ok) || !set.endsWith(': ' + pick.value)) {
            vscode.window.showWarningMessage(texts.autoStartFailed);
            return done(pick.value + ' - failed');
        }
        if (pick.value === 'on') { vscode.window.showInformationMessage(texts.autoStartOn); return done('on'); }
        const s = await setup._runPs(exe, loader, 'chatoverlay -Stop *>&1 | Out-String -Width 200', 60000, log);
        const out = String((s && s.stdout) || '');
        const stopped = /overlay closed/.test(out) ? 'closed' : /has not yet/.test(out) ? 'not yet' :
            /not running/.test(out) ? 'not running' : 'unknown';
        vscode.window.showInformationMessage(texts.autoStartOff(stopped));
        return done('off, the overlay ' + stopped);
    } catch (e) {
        vscode.window.showWarningMessage(texts.autoStartFailed);
        return done('failed - ' + ((e && e.message) || e));
    }
}

// Chat Manager: Phone alerts... - the setup window for Join alerts and for
// answering them from the phone, as chatnotify -Setup opens it from a
// terminal. That window is WPF in a process of its own, so Windows only;
// elsewhere the same settings are chatnotify's switches, and this says so.
// Run through the tool folder's loader and setup's runPs, as
// overlayAutoStart is, so the tests stand in for PowerShell. The script's
// one "phone setup ..." line says whether the window came; the window itself
// is the answer when it did. Never throws.
const phoneTexts = {
    windowsOnly: 'The phone alerts window is Windows-only. In a terminal, chatnotify -Setup lists the same settings as chatnotify switches.',
    noLoader: folder => 'The scripts are not in ' + folder + ', so the phone alerts window cannot open. Chat Manager: Install terminal commands puts them there.',
    already: 'The phone alerts window is already open.',
    failed: said => (said ? 'The phone alerts window: ' + said + '.' : 'The phone alerts window did not open.') + ' Chat Manager: Show log has the details.'
};
async function phoneAlerts() {
    const io = module.exports._overlayIo;
    const done = (outcome) => { log('phone alerts: ' + outcome); return outcome; };
    try {
        const platform = io.platform();
        if (platform !== 'win32') {
            vscode.window.showInformationMessage(phoneTexts.windowsOnly);
            return done('Windows only');
        }
        const folder = toolFolder();
        const loader = path.join(folder, setup.LOADER);
        if (!io.exists(loader)) {
            vscode.window.showWarningMessage(phoneTexts.noLoader(folder));
            return done('no loader in ' + folder);
        }
        const exe = io.powershell(platform);
        if (!exe) { vscode.window.showWarningMessage(phoneTexts.failed('')); return done('no PowerShell found'); }
        // Write-Host is the information stream: *>&1 brings it to stdout
        const r = await setup._runPs(exe, loader, 'chatnotify -Setup *>&1 | Out-String -Width 200', 60000, log);
        const said = lastSaid(r && r.stdout, /phone setup/);
        if (/opens in its own window|is still starting/.test(said)) return done(said);
        if (/already open/.test(said)) { vscode.window.showInformationMessage(phoneTexts.already); return done('already open'); }
        vscode.window.showWarningMessage(phoneTexts.failed(said));
        return done('failed - ' + (said || 'no word from the script'));
    } catch (e) {
        vscode.window.showWarningMessage(phoneTexts.failed(''));
        return done('failed - ' + ((e && e.message) || e));
    }
}

// Chat Manager: Auto-continue cut-off chats... - the switch chatq
// -AutoContinue on|ask|off sets, in data/config.json: no VS Code setting,
// which is per profile and would disagree with the overlay and the
// terminal. Run through the tool folder's loader and setup's runPs, as
// overlayAutoStart is, so the tests stand in for PowerShell; the script's
// own line - "auto-continue: on", "ask" or "off" - says whether it took.
// Every platform: the watcher scans too. Never throws.
const autoTexts = {
    ask: 'What should chatq do with chats the usage limit cuts off?',
    on: 'Chats the usage limit cuts off are now continued by chatq, a minute after the reset.',
    asks: 'Once the usage limit is over, the overlay asks before chatq continues the chats it cut off.',
    off: 'chatq no longer continues chats the limit cuts off.',
    noLoader: folder => 'The scripts are not in ' + folder + ', so auto-continue could not be set. Chat Manager: Install terminal commands puts them there.',
    failed: 'Auto-continue could not be set. Chat Manager: Show log has the details.'
};
async function autoContinue() {
    const io = module.exports._overlayIo;
    const done = (outcome) => { log('auto-continue: ' + outcome); return outcome; };
    try {
        const folder = toolFolder();
        const loader = path.join(folder, setup.LOADER);
        if (!io.exists(loader)) {
            vscode.window.showWarningMessage(autoTexts.noLoader(folder));
            return done('no loader in ' + folder);
        }
        // the settings box's three, in its order and words
        const pick = await vscode.window.showQuickPick([
            { label: 'Continue', description: 'a minute after the limit resets, each chat it cut off gets "continue"', value: 'on' },
            { label: 'Ask', description: 'the default: once the limit is over, the overlay asks, and continues them on a click', value: 'ask' },
            { label: 'Leave', description: 'they are only marked orange', value: 'off' }
        ], { placeHolder: autoTexts.ask });
        if (!pick || !pick.value) return done('nothing picked');
        const exe = io.powershell(io.platform());
        if (!exe) { vscode.window.showWarningMessage(autoTexts.failed); return done(pick.value + ' - no PowerShell found'); }
        // Write-Host is the information stream: *>&1 brings it to stdout
        const r = await setup._runPs(exe, loader, 'chatq -AutoContinue ' + pick.value + ' *>&1 | Out-String -Width 200', 60000, log);
        const set = lastSaid(r && r.stdout, /^auto-continue: (on|ask|off)\b/);
        if (!(r && r.ok) || !set.startsWith('auto-continue: ' + pick.value)) {
            vscode.window.showWarningMessage(autoTexts.failed);
            return done(pick.value + ' - failed');
        }
        vscode.window.showInformationMessage(pick.value === 'on' ? autoTexts.on : pick.value === 'ask' ? autoTexts.asks : autoTexts.off);
        return done(pick.value);
    } catch (e) {
        vscode.window.showWarningMessage(autoTexts.failed);
        return done('failed - ' + ((e && e.message) || e));
    }
}

function activate(context) {
    // which extension host this is: the parent of this window's claude
    // processes, as the script's hostPids name it (S30)
    log('activated in extension host ' + process.pid);
    // a new version of this extension installed: said, with what a reload
    // would stop here, and reloaded only when asked or once all is idle
    try { safe.activate(context); } catch (e) { log('watching for a new version failed: ' + ((e && e.stack) || e)); }
    if (vscode.commands.registerCommand) {
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.installTerminal', () => runSetup(context, true)));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.showLog', () => { log('log shown'); if (channel) channel.show(); }));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.openChat',
            () => openChat().catch(e => log('the chat picker failed: ' + ((e && e.stack) || e)))));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.overlayAutoStart', () => overlayAutoStart()));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.phoneAlerts', () => phoneAlerts()));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.autoContinue', () => autoContinue()));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.watchRun', () => watchRun()));
        context.subscriptions.push(vscode.commands.registerCommand('chatManager.showQueue', () => showQueue()));
    }
    // the spawn hook in before Claude Code brings its tabs back, so it sees
    // when each chat's process began (processStart)
    if (keepSettings() && carryReaches()) installSpawnHook();
    // a watch panel open as the window reloaded comes back - whoever
    // handles the requests
    runClock.activatedAt = Date.now();
    // a restart or a reload (restartHeld), and this activation's id kept
    // for the next one to tell
    noteHostStart(context);
    if (vscode.window.registerWebviewPanelSerializer) {
        try { context.subscriptions.push(vscode.window.registerWebviewPanelSerializer(WATCH_TYPE, watchSerializer(context))); }
        catch (e) { log('the watch panel\'s serializer failed: ' + (e && e.message)); }
    }
    // The overlay from the setup's onReady alone: at once where the loader is
    // in place and nothing is to be copied - setUp calls it before its first
    // await - else the moment its copy has put the loader there. Never from
    // a loader this window or another is about to copy an update over, and
    // never after the setup settles, which waits on its profile question
    // that nobody may ever answer. After a start, a second does nothing.
    // Neither holds up the rest of activation.
    setTimeout(() => { runSetup(context, false, () => { startOverlay(context); }); }, 0);
    if (oldExtension()) {
        askToRemoveOld().catch(e => log('asking about the old extension failed: ' + (e && e.message)));
        if (oldWatchesMine()) {
            log(setup.OLD_ID + ' is installed and watches ' + signalFiles()[0] + ': every request is left to it');
            return;
        }
        log(setup.OLD_ID + ' is installed but watches another file: this one handles ' + signalFiles()[0]);
    }
    for (const file of signalFiles()) {
        check(context, file, true);
        // watchFile polls. createFileSystemWatcher only reaches inside workspace
        // folders, and this path is deliberately outside every one of them.
        fs.watchFile(file, { interval: 2000 }, () => check(context, file, false));
        context.subscriptions.push({ dispose: () => fs.unwatchFile(file) });
    }
    for (const file of openFiles()) {
        checkOpen(context, file, true);
        fs.watchFile(file, { interval: 2000 }, () => checkOpen(context, file, false));
        context.subscriptions.push({ dispose: () => fs.unwatchFile(file) });
    }
    // A queued run: read once now - a run going, or one that ended while no
    // window was open, whose chat this window handed over - then followed.
    // Looked at on a timer besides, for a watcher that died mid-run.
    const rsFile = runStateFile();
    const look = () => { onRunState(context).catch(e => log('run-state: ' + ((e && e.stack) || e))); };
    look();
    fs.watchFile(rsFile, { interval: timing.runPoll }, look);
    // the queue's status bar item, on the same timer
    const lookQueue = () => { try { updateQueueItem(); } catch (e) { log('the queue item: ' + ((e && e.stack) || e)); } };
    lookQueue();
    const timer = setInterval(() => { look(); lookQueue(); }, timing.runCheck);
    if (timer && timer.unref) timer.unref();
    context.subscriptions.push({ dispose: () => {
        fs.unwatchFile(rsFile); clearInterval(timer); watchRunJob(context, null);
        if (runItem) { runItem.dispose(); runItem = null; }
        if (queueItem) { queueItem.dispose(); queueItem = null; }
    } });
    // the overlay's answers to a reload asked here (askReload); a gone
    // window's files swept, and this one's own taken with it
    sweepPending();
    const ansFile = answerFile();
    fs.watchFile(ansFile, { interval: 2000 }, () => { try { onReloadAnswer(); } catch (e) { log('reload-answer: ' + ((e && e.stack) || e)); } });
    context.subscriptions.push({ dispose: () => { fs.unwatchFile(ansFile); pendingAsks.clear(); writePending(); } });
}

// child_process.spawn as it was, where chatq's hook is still in it
function deactivate() { removeSpawnHook(); }

// The underscored ones are exported so the path matching, the BOM strip, the
// wording, the auto rules, the plan and the command sequences can be driven
// from a test with the vscode module stubbed out - all of them decide
// whether, or how, a chat is shown, and fail silently when wrong. _alive,
// _getVerdict, _readChat, _timing, _overlayIo and _procIo are replaced by
// the tests.
module.exports = {
    activate, deactivate,
    _readRequest: readRequest, _isMine: isMine, _signalFiles: signalFiles, _openFiles: openFiles, _message: message,
    _texts: texts, _reloadsItself: reloadsItself, _isExactlyMine: isExactlyMine, _check: check, _checkOpen: checkOpen,
    _plan: plan, _isTarget: isTarget, _alive: alive, _timing: timing, _hasClaude: hasClaude, _showFresh: showFresh,
    _isClaudeTab: isClaudeTab, _claudeTabLabel: claudeTabLabel, _labelIsChat: labelIsChat, _claudeOnly: claudeOnly,
    _unlockClaudeGroup: unlockClaudeGroup, _windowsPowerShell: windowsPowerShell, _isGuid: isGuid, _psQuote: psQuote, _verdictCommand: verdictCommand,
    _parseVerdict: parseVerdict, _getVerdict: getVerdict, _showTab: showTab, _openTab: openTab,
    _enqueue: enqueue, _perform: perform, _offer: offer, _showIt: showIt, _judged: JUDGED,
    _setting: setting, _toolFolder: toolFolder, _oldExtension: oldExtension, _askToRemoveOld: askToRemoveOld, _runSetup: runSetup,
    _oldWatchesMine: oldWatchesMine, _startOverlay: startOverlay, _lockHeld: lockHeld, _overlayIo: overlayIo,
    _oneTabOf: oneTabOf, _openCore: openCore, _chatSlug: chatSlug, _listChats: listChats, _isNoise: isNoise, _formatTitle: formatTitle,
    _readChat: readChat, _describeChat: describeChat, _titleCache: titleCache, _readRegistry: readRegistry, _chatState: chatState,
    _ageText: ageText, _pickItem: pickItem, _openChat: openChat, _acceptChat: acceptChat, _claudeHome: claudeHome,
    _labelShared: labelShared, _noIcons: noIcons, _overlayAutoStart: overlayAutoStart,
    _openCall: openCall, _claudeColumn: claudeColumn, _versionAtLeast: versionAtLeast, _openOnce: openOnce,
    _showsItself: showsItself, _requestsOf: requestsOf, _unshown: unshown
};
module.exports._phoneAlerts = phoneAlerts;
module.exports._autoContinue = autoContinue;
module.exports._autoTexts = autoTexts;
Object.assign(module.exports, {
    _entrypointIn: entrypointIn, _unlistedWhy: unlistedWhy, _headAndTail: headAndTail, _listedLine: listedLine,
    _ensureListed: ensureListed, _offerTerminal: offerTerminal, _claudeExe: claudeExe
});
// a queued run's live view, the handover and the chat put back, and Show it's
// close before its end
Object.assign(module.exports, {
    _showLive: showLive, _isWatchTab: isWatchTab, _openWith: openWith, _readRunState: readRunState, _runIsLive: runIsLive,
    _liveRunFor: liveRunFor, _onRunState: onRunState, _onHandover: onHandover, _restoreRuns: restoreRuns, _handovers: handovers,
    _openWatch: openWatch, _watchViews: watchViews, _watchIo: watchIo, _watchRun: watchRun, _watchSerializer: watchSerializer,
    _updateRunItem: updateRunItem, _cancelRun: cancelRun, _openFromWatch: openFromWatch, _onWatchMessage: onWatchMessage,
    _promptOf: promptOf, _promptIo: promptIo, _askHandOver: askHandOver, _watchTitle: watchTitle, _validJobId: validJobId,
    _stillHandover: stillHandover, _runClock: runClock, _runOf: runOf, _tabWaits: tabWaits,
    _forgetRuns: () => { handled.clear(); handOverNow.clear(); inUseSaid.clear(); besideSaid.clear(); lastRuns.clear(); restoringNow.clear(); tabWaits.clear(); }
});
// an extension-host restart told from a reload, for Show it's second check
Object.assign(module.exports, { _hostStartOf: hostStartOf, _noteHostStart: noteHostStart, _restartHeld: restartHeld, _hostKey: HOST_KEY });
// Ultracode and effort, lost by a reopen: _sessionSettingsIn is replaced by
// the tests
Object.assign(module.exports, { _effortSaid: effortSaid, _effortLine: effortLine, _sessionSettingsIn: sessionSettingsIn, _ultracodeIn: ultracodeIn,
    _sessionIo: sessionIo, _lostByReopen: lostByReopen, _sayLost: sayLost });
// and carried into one: _carryIo.mod is replaced by the tests, so the real
// child_process is never hooked there
Object.assign(module.exports, { _carryIo: carryIo, _installSpawnHook: installSpawnHook, _removeSpawnHook: removeSpawnHook,
    _carryArgs: carryArgs, _armCarry: armCarry, _carryFor: carryFor, _reportCarry: reportCarry, _keepSettings: keepSettings,
    _carryReaches: carryReaches, _carryArms: carryArms, _launches: launches, _processStart: processStart, _validStart: validStart,
    _putBackLast: () => putBackLast });
// the picker's look at each process - _procIo is replaced by the tests, so
// PowerShell is never started there - and the queue's status bar item
Object.assign(module.exports, { _procIo: procIo, _procScript: procScript, _parseProcs: parseProcs, _procFacts: procFacts,
    _procSeen: procSeen, _startFits: startFits, _whereOf: whereOf, _withFacts: withFacts, _liveRegistry: liveRegistry,
    _placeOf: placeOf, _hostsOf: hostsOf, _handToWindow: handToWindow,
    _queueBlocks: queueBlocks, _queueNext: queueNext, _queueText: queueText, _readQueue: readQueue, _watcherUp: watcherUp,
    _updateQueueItem: updateQueueItem, _showQueue: showQueue, _queueItem: () => queueItem });
// what safe-restart.js uses of this file
Object.assign(module.exports, { _log: log, _command: command, _reloadWindow: reloadWindow, _reloadAnyway: reloadAnyway, _safe: safe, _forgetPwsh: () => { pwshFound = undefined; } });
// a reload asked for, on the overlay too
Object.assign(module.exports, { _askReload: askReload, _askSay: askSay, _onReloadAnswer: onReloadAnswer, _sweepPending: sweepPending,
    _pendingAsks: pendingAsks, _pendingFile: pendingFile, _answerFile: answerFile, _writePending: writePending, _reloadIo: reloadIo });
