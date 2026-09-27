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
const timing = {
    retry: 2500, tabSettle: 400, tabRecount: 1500, startupOpen: 2000,
    openMaxAge: 120000, judgedMaxAge: 20000, verdictTimeout: 20000,
    commandTimeout: 15000, pickBudget: 250, labelBudget: 1500, anywayFresh: 60000
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

const DEFAULT_FOLDER = () => path.join(os.homedir(), 'Tools', 'VS-code-chat-manager');
function expandHome(p) { return path.normalize(String(p).replace(/^~(?=$|[\\/])/, os.homedir())); }

// the old extension's signalFile, as it was set, else ''
function oldSignalFile() {
    const old = vscode.workspace.getConfiguration('chatManagerReload');
    return isSet(old.inspect && old.inspect('signalFile')) ? String(old.get('signalFile') || '').trim() : '';
}

// The tool folder: the scripts, and data/ beside them - and where setup.js
// writes, so only a full path is taken. chatManager.folder; else the folder
// whose data/reload-request the old signalFile named, and only a path of
// that shape; else ~/Tools/VS-code-chat-manager. What is set and refused is
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

// VS-code-chat-manager writes data/reload-request after chatrm deletes a chat,
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
        if (!channel && vscode.window.createOutputChannel) channel = vscode.window.createOutputChannel('VS Code Chat Manager');
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
    return req.kind === 'open' ? isExactlyMine(req) : isMine(req);
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
    sideBarStale: req => name(req) + ' was also open in this window outside its tabs - most likely the side bar. That copy is stale now and can be closed: the tab shows the run.',
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
// 2.1.283: sessionId, prompt, viewColumn, group, fullEditor, options.
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
// since the groups change between two opens.
function openCall(sessionId) {
    if (!versionAtLeast(claudeVersion(), OPEN_SINCE)) return [OPEN_FULL, sessionId];
    return [OPEN, sessionId, undefined, claudeColumn(), undefined, false, { programmatic: 'pin-to-panel' }];
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
async function openOnce(sessionId) {
    const [c, ...args] = openCall(sessionId);
    try { await command(c, ...args); }
    catch (e) {
        log(c + ' failed: ' + (e && e.message));
        if (c !== OPEN || (e && e.timedOut)) throw e;
        try { await command(OPEN_FULL, sessionId); }
        catch (e2) { log(OPEN_FULL + ' failed: ' + (e2 && e2.message)); throw e2; }
        log('opened with ' + OPEN_FULL + ' instead - that tab has no header');
    }
}

// Asked twice at most: the Claude extension may still be starting. One that
// timed out is not asked again - the first may yet land, and a second would
// only wait behind it. Each try works the column out again.
async function openWith(sessionId) {
    for (let i = 0; i < 2; i++) {
        try { await openOnce(sessionId); return true; }
        catch (e) {
            if (e && e.timedOut) return false;
            if (i === 0) await sleep(timing.retry);
        }
    }
    return false;
}

// Did a Claude tab appear that was not among before?
function tabGrew(before) {
    const now = allTabs().filter(isClaudeTab);
    return now.length > before.length || now.some(t => !before.includes(t));
}

// Looked at twice, after tabSettle and again after tabRecount: a new panel
// can be slow to show.
async function tabAppeared(before) {
    if (tabGrew(before)) return true;
    await sleep(timing.tabRecount);
    return tabGrew(before);
}

// A group of Claude tabs alone. One holding any other editor is the user's
// own arrangement. Pure.
function claudeOnly(tabs) {
    const all = Array.isArray(tabs) ? tabs : [];
    return all.length > 0 && all.every(isClaudeTab);
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
    await openOnce(req.sessionId);
    // for the new tab to be there when its group is looked for
    await sleep(timing.tabSettle);
    return up('reopened');
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
async function openCore(req, before, why) {
    let how;
    const listed = await ensureListed(req);
    if (listed === 'unlistable') {
        how = 'unlistable';
        offerTerminal(req).catch(e => log('the terminal offer failed: ' + (e && e.message)));
    } else if (listed === 'held' || listed === 'unmended') {
        how = listed;
        vscode.window.showInformationMessage((listed === 'held' ? texts.hiddenBusy : texts.unmended)(req));
    } else if (!(await openWith(req.sessionId))) {
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
// is up to date and only revealed - and the open (openCall) never rewrites
// the Claude extension's preferredLocation setting, as a plain editor.open
// does. It does not look at the side bar, though: a chat held
// there gets a second panel and a second process. Held idle, that is said
// once; held working, it is not opened at all, since the second process
// would start mid-turn.
async function openTab(req) {
    const hp = hostPidsOf(req);
    const sid = (req.sessionId || '').slice(0, 8);
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
            const r = await showTab(req);
            // A new tab for a chat a process of this window held: its view
            // here was outside the tabs, and the process under it has been
            // ended, so that view is dead. Said once, here.
            if (r === 'new' && hostPidsOf(req).includes(process.pid)) {
                log(req.kind + ' ' + (req.sessionId || '').slice(0, 8) + ': its old view here was outside the tabs');
                vscode.window.showInformationMessage(texts.sideBarStale(req));
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

// Show it's check: the script's Show-ChatFresh, which ends the chat's old
// idle process and judges the folder again, printing one line of JSON.
function verdictCommand(script, req) {
    if (!isGuid(req.sessionId)) throw new Error('not a session id: ' + req.sessionId);
    let cmd = "$env:CHATQ_OVERLAY='1'; . " + psQuote(script) + '; $r = @(Show-ChatFresh -Via button -SessionId ' +
        psQuote(req.sessionId) + ' -Cwd ' + psQuote(req.cwd || '');
    if (req.home) cmd += ' -ConfigDir ' + psQuote(req.home);
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

function getVerdict(req, file) {
    const script = path.join(path.dirname(path.dirname(file)), 'VS-code-chat-manager.ps1');
    let exe, args;
    try { [exe, args] = verdictCommand(script, req); } catch (e) { log(e.message); return Promise.resolve(null); }
    return new Promise(resolve => {
        cp.execFile(exe, args, { timeout: timing.verdictTimeout, windowsHide: true }, (err, stdout) => {
            if (err) log('Show it check failed: ' + err.message);
            resolve(parseVerdict(stdout));
        });
    });
}

// The outcomes of a check that judged the chat. Any other - missing, bad -
// returned before looking at its process at all, so what it says of that
// process is nothing to act on.
const JUDGED = ['ok', 'held', 'other', 'running'];

// Show it: the check, then the chat shown by what it found. A failed check,
// or one that judged nothing, leaves the verdict to the request's own - a
// fresh tab if the process was ended, else a reload offer; never a tab
// beside a process still running. The request's busy goes with it: another
// chat it found working is still a reason to ask the reload only as anyway.
// A queued prompt going into the chat now leaves it alone: showing it would
// load it part way through.
async function showIt(req, file) {
    const bar = vscode.window.setStatusBarMessage ? vscode.window.setStatusBarMessage(texts.checking) : null;
    let v;
    try { v = await module.exports._getVerdict(req, file); }
    finally { if (bar && bar.dispose) bar.dispose(); }
    const sid = (req.sessionId || '').slice(0, 8);
    if (v) log('Show it ' + sid + ': busy ' + v.busy + ', oldProcess ' + v.oldProcess + ', outcome ' + v.outcome);
    else log('Show it ' + sid + ': the check failed; the request\'s oldProcess ' + req.oldProcess);
    if (v && !JUDGED.includes(v.outcome)) { log('Show it check judged nothing: ' + v.outcome); v = null; }
    if (v && v.outcome === 'running') {
        vscode.window.showInformationMessage(texts.running(req));
        return 'running';
    }
    const verdict = v || { busy: req.busy === true ? true : null, oldProcess: req.oldProcess };
    const how = plan(req, verdict, { fresh: showFresh(), claude: hasClaude() });
    // Held working, or another chat of the folder busy: a reload now cuts it
    // off, so it is asked only as anyway - held, as the offer says it; the
    // chat itself not held, as the other chat's work, which is what a reload
    // would cut off.
    if (how === 'reload' && (verdict.oldProcess === 'held' || verdict.busy === true)) {
        const go = 'Reload anyway';
        const said = verdict.oldProcess === 'held' ? message(Object.assign({}, req, { oldProcess: 'held' }), true) : texts.ranBusy(req);
        const shownAt = safe._now();
        const pick = await vscode.window.showWarningMessage(said, go, 'Not now');
        // held: the warning named this chat; busy: another chat of its folder,
        // which it did not name, so nothing is left out of a later look
        if (pick === go) return enqueue(() => reloadAnyway(shownAt, verdict.oldProcess === 'held' ? req.sessionId : null, req.sessionId));
        return 'asked';
    }
    if (how === 'reload') {
        const go = 'Reload';
        const pick = await vscode.window.showWarningMessage(texts.couldNotEnd(req), go, 'Not now');
        // a plain Reload, maybe clicked minutes later: looked at again
        if (pick === go) return enqueue(() => safe._guardReload(false, req.sessionId));
        return 'asked';
    }
    // the windows the check found holding the chat, beside the request's:
    // either may name this one, whose old view then needs a word after
    const had = hostPidsOf(req);
    const shown = v ? Object.assign({}, req, { hostPids: had.concat(hostPidsOf(v).filter(p => !had.includes(p))) }) : req;
    return enqueue(() => perform(how, shown));
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
    await context.globalState.update(SEEN_KEY, req.id);

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
            const pick = await vscode.window.showWarningMessage(message(req, true), go, 'Not now');
            if (pick === go) return enqueue(() => reloadAnyway(shownAt, req.sessionId, req.sessionId));
            return;
        }
        const go = 'Show it';
        const pick = await vscode.window.showInformationMessage(message(req, true), go, 'Not now');
        if (pick === go) return showIt(req, file);
        return;
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
    const pick = busy
        ? await vscode.window.showWarningMessage(message(req, false), go, 'Not now')
        : await vscode.window.showInformationMessage(message(req, false), go, 'Not now');
    if (pick === go) {
        // Reload anyway was the answer to a warning about this request's
        // chat: fresh, it reloads; later, looked at again past that chat. A
        // plain Reload, maybe clicked minutes later, is looked at again
        if (busy) return reloadAnyway(shownAt, req.sessionId, except);
        return safe._guardReload(false, except);
    }
}

function check(context, file, onlyRecent) {
    const req = readRequest(file);
    if (!req || !req.id || req.kind === 'open') return;
    if (context.globalState.get(SEEN_KEY) === req.id) return;
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
        if (req.kind === 'ran' || req.kind === 'new') { context.globalState.update(SEEN_KEY, req.id); return; }
    }
    return offer(context, req, file);
}

// The overlay's open chip: always a tab (openTab). The chip ends no process,
// so there is nothing to show fresh and showFresh has no say; a reload would
// only cut off whatever else the window runs. At startup - a window code -n
// just opened for it - the Claude extension is given a moment to start.
async function checkOpen(context, file, onlyRecent) {
    const req = readRequest(file);
    if (!req || req.kind !== 'open' || !isGuid(req.sessionId) || !req.id) return;
    if (context.globalState.get(OPEN_SEEN_KEY) === req.id) return;
    if (!isTarget(req)) return;
    const age = ageOf(req);
    await context.globalState.update(OPEN_SEEN_KEY, req.id);
    if (!(age <= timing.openMaxAge)) return;
    if (!hasClaude()) {
        vscode.window.showInformationMessage(texts.noClaude(req));
        return;
    }
    if (onlyRecent) await sleep(timing.startupOpen);
    return enqueue(() => openTab(req));
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
// the first prompt typed - '' for none. The records are looked for in the
// last 256 KB, newest first, the prompt in the first 256 KB; a file of no
// more is read once. { skip } for what the Claude extension lists not: a
// side transcript, flagged on its first line, and one of 64 KB or less that
// holds no message at all. null when it cannot be read.
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
        const title = lastRecord(tail, 'custom-title', 'customTitle') || await readSidecar(c.dir, c.sid) ||
            lastRecord(tail, 'ai-title', 'aiTitle') || firstPrompt(await headText());
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
// catches most files a crash left behind for a pid handed on since.
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

// What runs a chat, from its live entries. Pure.
//   closed    nothing: it opens from disk
//   running   a run of no one's typing - a kind set and not interactive, as
//             chatq's queued prompt, claude -p, is - is writing to it now
//   terminal  a claude of a terminal holds it: an entrypoint other than
//             claude-vscode
//   working   a VS Code panel holds it - or an entry naming no entrypoint -
//             mid-turn or waiting on a prompt
//   open      the same, idle
function chatState(entries) {
    if (!entries || !entries.length) return 'closed';
    if (entries.some(e => e.kind && e.kind !== 'interactive')) return 'running';
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
// shows its id. Pure.
function pickItem(c, d, state, multi, now) {
    const word = STATE_WORD[state] || '';
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
    const states = readRegistry(home, now);
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
            items.push(pickItem(c, d, chatState(states.get(c.sid)), multi, now));
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
// starts a second copy mid-answer. Open idle elsewhere - another window, or
// the side bar, which the open (openCall) does not look at - only when asked.
// Nothing runs it: opened from disk. Its one tab here counts only while no
// other chat of its folder shares the tab's label. And it is read once more
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
    let state;
    // what runs it now, and whether it has a tab here that is surely its own
    const look = async () => {
        state = chatState(readRegistry(home, Date.now()).get(c.sid));
        if (state !== 'working' && state !== 'open') return false;
        return !!oneTabOf(title, allTabs().filter(isClaudeTab)) && !(await labelShared(title, c.cwd, c.sid, home));
    };
    // said and true where it may not be opened as it stands
    const refused = (tab) => {
        const why = state === 'terminal' ? texts.pickTerminal : state === 'running' ? texts.pickRunning :
            state === 'working' && !tab ? texts.pickWorking : null;
        if (why) vscode.window.showInformationMessage(why(said));
        return !!why;
    };
    const done = (outcome) => { log('pick ' + c.sid.slice(0, 8) + ': ' + state + ' -> ' + outcome); return outcome; };
    let tab = await look();
    if (refused(tab)) return done('refused');
    if (state === 'open' && !tab) {
        const go = 'Open here too';
        if (await vscode.window.showWarningMessage(texts.pickElsewhere(said), go, 'Cancel') !== go) return done('cancelled');
        tab = await look();
        if (refused(tab)) return done('refused');
    }
    if (!hasClaude()) { vscode.window.showInformationMessage(texts.noClaude(said)); return done('no Claude'); }
    const how = await enqueue(async () => {
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
}

function deactivate() { }

// The underscored ones are exported so the path matching, the BOM strip, the
// wording, the auto rules, the plan and the command sequences can be driven
// from a test with the vscode module stubbed out - all of them decide
// whether, or how, a chat is shown, and fail silently when wrong. _alive,
// _getVerdict, _readChat, _timing and _overlayIo are replaced by the tests.
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
    _showsItself: showsItself
};
module.exports._phoneAlerts = phoneAlerts;
module.exports._autoContinue = autoContinue;
module.exports._autoTexts = autoTexts;
Object.assign(module.exports, {
    _entrypointIn: entrypointIn, _unlistedWhy: unlistedWhy, _headAndTail: headAndTail, _listedLine: listedLine,
    _ensureListed: ensureListed, _offerTerminal: offerTerminal, _claudeExe: claudeExe
});
// what safe-restart.js uses of this file
Object.assign(module.exports, { _log: log, _command: command, _reloadWindow: reloadWindow, _reloadAnyway: reloadAnyway, _safe: safe, _forgetPwsh: () => { pwshFound = undefined; } });
