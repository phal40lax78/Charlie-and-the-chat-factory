// The terminal half. This package carries the PowerShell scripts - payload/,
// which build.js fills - and puts them in the tool folder, where data/ lives:
// never into a git checkout, never over a copy it cannot read the version of
// or a newer one, never into a folder of someone else's, one window at a
// time. Then it asks, once, before adding the line that loads them to a
// PowerShell profile - and before allowing local scripts, where the policy
// would stop that line. Every process it starts is logged with its command
// line first. docs/marketplace-spec.md has the design.
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const LOADER = 'Charlie-and-the-chat-factory.ps1';
const OLD_ID = 'phal40lax78.chat-manager-reload';
// a lock older than this was left by a window that died holding it
const COPY_STALE_MS = 2 * 60 * 1000;
// how long one window's question keeps the others from asking the same
const ASK_STALE_MS = 10 * 60 * 1000;
// chatinstall builds the search index on a first install: ~30 s, longer
// with many chats, and the version stamp is written after it
const CHATINSTALL_MS = 10 * 60 * 1000;
const PROBE = '[Console]::Out.WriteLine([string](Test-ChatProfileLine))';

// lazily: build.js and the tests load this file without VS Code
function vs() { return require('vscode'); }

// the loader's $script:ChatVersion, read from its text
function readVersion(text) {
    const m = /^\$script:ChatVersion = '(\d+)\.(\d+)\.(\d+)'/m.exec(String(text || ''));
    return m ? m[1] + '.' + m[2] + '.' + m[3] : null;
}

// null when the file cannot be read, or its version not
function readVersionFile(file) {
    try { return readVersion(fs.readFileSync(file, 'latin1')); } catch (e) { return null; }
}

function compareVersions(a, b) {
    const x = String(a).split('.').map(Number), y = String(b).split('.').map(Number);
    for (let i = 0; i < 3; i++) {
        if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) < (y[i] || 0) ? -1 : 1;
    }
    return 0;
}

// What to do with the tool folder. Pure. Given the version this package
// carries, whether a loader is there and the version read from it, whether
// the folder is in a git checkout, and whether it is someone else's folder
// (neither our loader nor a data/ in it, and not empty):
//   install  nothing there        update  older there      none  the same
//   newer    newer there (the one-liner or a pull got there first): left
//   skew     a git checkout at another version: never written, only said
//   unknown  a loader whose version cannot be read: left, and said
//   foreign  a folder that is not the tool's: nothing written, and said
function decide(o) {
    if (!o.bundled) return 'none';
    if (o.loader && !o.onDisk) return 'unknown';
    if (o.git) return o.onDisk && compareVersions(o.onDisk, o.bundled) !== 0 ? 'skew' : 'none';
    if (!o.loader) return o.foreign ? 'foreign' : 'install';
    const c = compareVersions(o.onDisk, o.bundled);
    return c < 0 ? 'update' : (c > 0 ? 'newer' : 'none');
}

// Is the folder, or any folder above it, a git work tree? A worktree's .git
// is a file, so either counts. ~/Tools itself may be someone's dotfiles repo.
// ceiling, for the tests, whose sandbox sits inside this repo: the last
// folder looked at, as GIT_CEILING_DIRECTORIES does for git.
function inGitCheckout(folder, ceiling) {
    const stop = ceiling ? path.resolve(ceiling).toLowerCase() : null;
    for (let d = path.resolve(folder); ;) {
        if (fs.existsSync(path.join(d, '.git'))) return true;
        const up = path.dirname(d);
        if (up === d || d.toLowerCase() === stop) return false;
        d = up;
    }
}

// a folder that exists, holds something, and is not the tool's
function isForeign(folder) {
    try {
        if (!fs.readdirSync(folder).length) return false;
    } catch (e) { return false; }
    return !fs.existsSync(path.join(folder, LOADER)) && !fs.existsSync(path.join(folder, 'data'));
}

// Look at the profile at all? A PowerShell in every window at every start
// costs a second of CPU each, so only when files changed, or when the
// question was never settled for this version. Pure.
function needsProbe(action, state, version) {
    if (action === 'install' || action === 'update') return true;
    if (state.profile === 'yes' || state.profile === 'never') return false;
    return state.notNowFor !== version;
}

// Ask about the profile line? Only where a PowerShell lacks it; never after
// Never, and after Not now not again for the same version - unless asked for
// from the command palette. Pure.
function shouldAsk(state, lacking, version, force) {
    if (!lacking.length) return false;
    if (force) return true;
    if (state.profile === 'never') return false;
    return state.notNowFor !== version;
}

// An exclusive file as a lock between windows: the first to create it acts,
// and false means another holds it. One older than staleMs is taken as
// abandoned and taken over, once. Any error but the file being there - a
// data/ that cannot be written - is thrown, not taken for another window.
function takeLock(file, now, staleMs) {
    for (let i = 0; i < 2; i++) {
        try {
            fs.writeFileSync(file, String(process.pid), { flag: 'wx' });
            return true;
        } catch (e) {
            if (e.code !== 'EEXIST') throw e;
            let st;
            try { st = fs.statSync(file); } catch (e2) { continue; }
            if (now - st.mtimeMs < staleMs) return false;
            try { fs.unlinkSync(file); } catch (e3) { return false; }
        }
    }
    return false;
}

function releaseLock(file) { try { fs.unlinkSync(file); } catch (e) { } }

// A JSON file, or null where it cannot be read or does not parse.
// PowerShell's Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell
// and JSON.parse rejects it outright. The script writes without one, but a
// file edited by hand may well have it.
function readJson(file) {
    let raw;
    try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { return null; }
    if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
    try { return JSON.parse(raw); } catch (e) { return null; }
}

// data/extension.json: what the owner answered and what was said, kept
// beside the rest of the tool's data rather than in VS Code's own storage
function statePath(folder) { return path.join(folder, 'data', 'extension.json'); }

function readState(folder) {
    const o = readJson(statePath(folder));
    return o && typeof o === 'object' && !Array.isArray(o) ? o : {};
}

// A temp name of this window's own: two windows writing at once must not
// rename each other's file away. Windows refuses a rename over a file that
// something has open for a moment - a virus scanner looking at the last
// write, or another window reading it - so a refusal is tried again a few
// times, briefly, before it counts.
function writeState(folder, s) {
    fs.mkdirSync(path.join(folder, 'data'), { recursive: true });
    const f = statePath(folder);
    const tmp = f + '.' + process.pid + '.' + Math.random().toString(36).slice(2) + '.new';
    fs.writeFileSync(tmp, JSON.stringify(s, null, 1));
    for (let i = 0; ; i++) {
        try { fs.renameSync(tmp, f); return; }
        catch (e) {
            if (i < 5 && e && ['EPERM', 'EACCES', 'EBUSY'].includes(e.code)) {
                Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20 * (i + 1));
                continue;
            }
            try { fs.unlinkSync(tmp); } catch (e2) { }
            throw e;
        }
    }
}

// Say something once per key, ever: the key goes into the state first. With
// data/ unwritable it is said each time, which is what that needs.
function sayOnce(folder, key, show, log) {
    const state = readState(folder);
    const said = state.said && typeof state.said === 'object' ? state.said : {};
    if (said[key]) return false;
    said[key] = true;
    state.said = said;
    try { writeState(folder, state); } catch (e) { log('setup: could not note what was said: ' + e.message); }
    show();
    return true;
}

// written beside the target, then renamed over it: never half a file, and
// no .new left behind when it fails
function put(from, to) {
    const tmp = to + '.new';
    try {
        fs.copyFileSync(from, tmp);
        fs.renameSync(tmp, to);
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (e2) { }
        throw e;
    }
}

// Every part first, then the loader, as install.ps1 does: stopped half-way,
// the old loader still loads whole, or names the part it cannot find.
function copyPayload(payload, folder) {
    const from = path.join(payload, 'src'), to = path.join(folder, 'src');
    fs.mkdirSync(to, { recursive: true });
    for (const n of fs.readdirSync(from).filter(n => /\.ps1$/i.test(n)).sort()) put(path.join(from, n), path.join(to, n));
    put(path.join(payload, LOADER), path.join(folder, LOADER));
}

// Windows PowerShell on Windows, where it is; PowerShell 7 wherever it is on
// PATH. Each keeps a profile, and an execution policy, of its own.
function which(name) {
    try {
        const r = cp.spawnSync(process.platform === 'win32' ? 'where.exe' : 'which', [name],
            { encoding: 'utf8', windowsHide: true, timeout: 5000 });
        const first = String(r.stdout || '').split(/\r?\n/).map(s => s.trim()).find(Boolean);
        return r.status === 0 && first ? first : null;
    } catch (e) { return null; }
}

// Windows PowerShell, where Windows keeps it - what hosts() puts first,
// without its look on PATH for pwsh
function windowsPowerShell() {
    return path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

function hosts() {
    const out = [];
    if (process.platform === 'win32') {
        const ps = windowsPowerShell();
        if (fs.existsSync(ps)) out.push(ps);
    }
    const pwsh = which('pwsh');
    if (pwsh) out.push(pwsh);
    return out;
}

// ' and the curly quotes doubled: PowerShell reads all four as a quote
function psQuote(s) {
    return "'" + String(s).replace(/['\u2018-\u201B]/g, m => m + m) + "'";
}

// The arguments for one command after the loader is dot-sourced, marked as
// no interactive shell so the loader starts nothing of its own. Pure.
function psArgs(loader, command) {
    const cmd = "$env:CHATQ_OVERLAY='1'; . " + psQuote(loader) + '; ' + command;
    return ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
        Buffer.from(cmd, 'utf16le').toString('base64')];
}

function run(exe, args, shown, timeoutMs, log) {
    log('run: ' + exe + ' ' + shown);
    return new Promise(resolve => {
        cp.execFile(exe, args, { timeout: timeoutMs, windowsHide: true, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
            const out = String(stdout || '').trim();
            if (out) log(out.split(/\r?\n/).map(l => '    ' + l).join('\n'));
            if (err) log('  failed: ' + err.message + (stderr ? ' ' + String(stderr).trim().slice(0, 500) : ''));
            resolve({ ok: !err, stdout: String(stdout || '') });
        });
    });
}

function runPs(exe, loader, command, timeoutMs, log) {
    return run(exe, psArgs(loader, command), '(loads ' + loader + ') ' + command, timeoutMs, log);
}

// The last word of an answer's lines that matches, else ''. Pure.
function lastSaid(stdout, re) {
    const hit = String(stdout || '').split(/\r?\n/).map(s => s.trim()).filter(s => re.test(s));
    return hit.length ? hit[hit.length - 1] : '';
}

// the last line that is True or False, else null: no answer at all
function lastBool(stdout) {
    const l = lastSaid(stdout, /^(True|False)$/);
    return l ? l === 'True' : null;
}

// Get-ExecutionPolicy as a user's own shell sees it: a plain -Command, which
// even Restricted allows, and no -ExecutionPolicy of ours in the way
async function policyOf(exe, log) {
    const r = await run(exe, ['-NoProfile', '-NonInteractive', '-Command', '(Get-ExecutionPolicy).ToString()'],
        '-Command (Get-ExecutionPolicy).ToString()', 30000, log);
    return lastSaid(r.stdout, /\S/) || null;
}

// a policy under which the profile line cannot run. Pure.
function blocksProfile(policy) { return policy === 'Restricted' || policy === 'AllSigned'; }

// RemoteSigned for this user in this PowerShell; true when it took - a group
// policy can overrule it
async function allowScripts(exe, log) {
    await run(exe, ['-NoProfile', '-NonInteractive', '-Command', 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force'],
        '-Command Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force', 30000, log);
    return !blocksProfile(await module.exports._policyOf(exe, log));
}

const texts = {
    ask: 'Charlie and the Chat Factory: add chatrm, chatq and chatoverlay to your PowerShell profile, so every new terminal has them? The profile is backed up first.',
    askPolicy: (p) => 'Charlie and the Chat Factory: add chatrm, chatq and chatoverlay to your PowerShell profile, so every new terminal has them? ' +
        'PowerShell\'s execution policy is ' + p + ', which would stop that line, so Add also allows local scripts for your user (RemoteSigned). The profile is backed up first.',
    policyHave: (p) => 'Your PowerShell profile loads the chat commands, but PowerShell\'s execution policy is ' + p +
        ', so it never runs. Allow local scripts for your user (RemoteSigned)?',
    policyStuck: 'The execution policy did not change - a group policy decides it on this machine - so the profile line was not added.',
    installed: (v, folder) => 'Charlie and the Chat Factory ' + v + ' put its PowerShell commands in ' + folder + '.',
    updated: (v) => 'Chat Manager\'s PowerShell commands are now ' + v + '. Terminals already open keep the old ones until reopened.',
    skew: (folder, disk, mine) => 'The scripts in ' + folder + ' are ' + disk + ' and this extension is ' + mine +
        '. It never writes into a git checkout - pull to match.',
    unknown: (folder) => 'The scripts in ' + folder + ' carry no version this extension can read, so it leaves them as they are.',
    foreign: (folder) => folder + ' holds other files and is not Chat Manager\'s folder, so nothing was put there. Set chatManager.folder to an empty or new folder.',
    copyFailed: (folder, m) => 'Charlie and the Chat Factory could not put its PowerShell commands in ' + folder + ': ' + m + '. Chat Manager: Show log has the details.',
    added: 'Added. New terminals have the chat commands; type chat for the list.',
    addFailed: 'The chat commands could not be added to your PowerShell profile. Chat Manager: Show log has the details, and Chat Manager: Install terminal commands tries again.',
    present: 'Your PowerShell profile already loads the chat commands.',
    noPayload: 'This build of the extension carries no scripts - nothing to install.'
};

// The profile step. Which PowerShells load the commands and which lack the
// line - one that cannot be asked counts as neither - and each one's policy;
// the question where one lacks it; chatinstall where the owner said Add (the
// policy first, where it would stop the line) and, after files changed,
// where the line already is; the answer kept only once the line is really
// there; one restart of a running watcher and overlay after files changed.
async function profileStep(o) {
    const vscode = vs();
    const m = module.exports;
    const { folder, loader, version, action, force, log } = o;
    const exes = m._hosts();
    if (!exes.length) { log('setup: no PowerShell found'); return; }
    const have = [], lacking = [], policy = {};
    for (const exe of exes) {
        const b = lastBool((await m._runPs(exe, loader, PROBE, 60000, log)).stdout);
        if (b === null) { log('setup: could not tell whether ' + exe + ' loads the commands - left alone'); continue; }
        (b ? have : lacking).push(exe);
        policy[exe] = await m._policyOf(exe, log);
    }
    let state = readState(folder);
    const added = [], failed = [];
    if (shouldAsk(state, lacking, version, force)) {
        const blocked = lacking.filter(e => blocksProfile(policy[e]));
        const pick = await vscode.window.showInformationMessage(
            blocked.length ? texts.askPolicy(policy[blocked[0]]) : texts.ask, 'Add', 'Not now', 'Never');
        if (pick === 'Add') {
            for (const exe of lacking) {
                if (blocksProfile(policy[exe]) && !(await m._allowScripts(exe, log))) {
                    vscode.window.showWarningMessage(texts.policyStuck);
                    failed.push(exe);
                    continue;
                }
                await m._runPs(exe, loader, 'chatinstall -NoRestart *>&1 | Out-String -Width 200', CHATINSTALL_MS, log);
                (lastBool((await m._runPs(exe, loader, PROBE, 60000, log)).stdout) === true ? added : failed).push(exe);
            }
        }
        state = readState(folder);
        if (pick === 'Never') state.profile = 'never';
        else if (pick === 'Add' && !failed.length) state.profile = 'yes';
        else state.notNowFor = version;
        writeState(folder, state);
    } else if (!lacking.length && have.length && state.profile !== 'yes') {
        state.profile = 'yes';
        writeState(folder, state);
        if (force) vscode.window.showInformationMessage(texts.present);
    }
    if (added.length) vscode.window.showInformationMessage(texts.added);
    if (failed.length) vscode.window.showWarningMessage(texts.addFailed);
    // a line already there that the policy never lets run: offered once a
    // version, or whenever asked from the palette
    const stuck = have.filter(e => blocksProfile(policy[e]));
    state = readState(folder);
    if (stuck.length && (force || state.policyAskedFor !== version)) {
        state.policyAskedFor = version;
        writeState(folder, state);
        if (await vscode.window.showWarningMessage(texts.policyHave(policy[stuck[0]]), 'Allow', 'Not now') === 'Allow') {
            for (const exe of stuck) if (!(await m._allowScripts(exe, log))) vscode.window.showWarningMessage(texts.policyStuck);
        }
    }
    const changed = action === 'install' || action === 'update';
    if (changed) {
        for (const exe of have) await m._runPs(exe, loader, 'chatinstall -NoRestart *>&1 | Out-String -Width 200', CHATINSTALL_MS, log);
        await m._runPs(exes[0], loader, 'Restart-ChatBackground *>&1 | Out-String -Width 200', 60000, log);
    }
}

// the copy, under the install lock: 'copied', 'elsewhere' (another window
// holds the lock), 'done' (another window finished it meanwhile) or 'failed'
function copyUnderLock(o) {
    const vscode = vs();
    const { payload, folder, bundled, action, git, log } = o;
    const data = path.join(folder, 'data');
    const lock = path.join(data, 'install.lock');
    const fail = (e) => {
        log('setup: copying into ' + folder + ' failed: ' + (e && e.message));
        const state = readState(folder);
        if (state.failedFor !== bundled) {
            state.failedFor = bundled;
            try { writeState(folder, state); } catch (e2) { }
            vscode.window.showWarningMessage(texts.copyFailed(folder, e && e.message));
        }
        return 'failed';
    };
    try {
        fs.mkdirSync(data, { recursive: true });
        if (!takeLock(lock, Date.now(), COPY_STALE_MS)) { log('setup: another window is installing'); return 'elsewhere'; }
    } catch (e) { return fail(e); }
    try {
        // again under the lock: another window may have just done it
        const loader = path.join(folder, LOADER);
        const hasLoader = fs.existsSync(loader);
        const now = decide({ bundled, loader: hasLoader, onDisk: hasLoader ? readVersionFile(loader) : null, git, foreign: false });
        if (now !== action) { log('setup: done meanwhile'); return 'done'; }
        copyPayload(payload, folder);
        log('setup: copied ' + bundled + ' into ' + folder);
        return 'copied';
    } catch (e) { return fail(e); } finally { releaseLock(lock); }
}

// On activation, in every window, and from the command palette (force).
// onReady, when given, is called once the loader is in place - copied here,
// or there already - and before the profile step, whose question may never
// be answered: what needs only the loader need not wait on that. Where
// nothing is to be copied it is called before the first await, so a caller
// needs no look of its own at the loader; where a copy is due, only once it
// is whole - and not at all while another window is copying, or where the
// copy failed, since the scripts may then be half old and half new.
async function setUp(o) {
    const vscode = vs();
    const { extensionPath, folder, log, force, onReady } = o;
    if (!path.isAbsolute(folder)) { log('setup: not a full path, nothing done: ' + folder); return 'none'; }
    const payload = path.join(extensionPath, 'payload');
    const bundled = readVersionFile(path.join(payload, LOADER));
    const loader = path.join(folder, LOADER);
    const hasLoader = fs.existsSync(loader);
    const onDisk = hasLoader ? readVersionFile(loader) : null;
    const git = module.exports._inGitCheckout(folder);
    const foreign = !hasLoader && isForeign(folder);
    const action = decide({ bundled, loader: hasLoader, onDisk, git, foreign });
    log('setup: ' + action + ' - carries ' + (bundled || 'nothing') + ', ' + folder + ' has ' +
        (hasLoader ? (onDisk || 'a loader of no readable version') : 'nothing') + (git ? ' (in a git checkout)' : ''));
    if (force && !bundled && !hasLoader) { vscode.window.showWarningMessage(texts.noPayload); return action; }
    // not our folder: nothing written there, not even a note of having said so
    if (action === 'foreign') {
        if (force || !module.exports._saidForeign) { module.exports._saidForeign = true; vscode.window.showWarningMessage(texts.foreign(folder)); }
        return action;
    }
    const ready = () => {
        if (!onReady || !fs.existsSync(loader)) return;
        try { onReady(); } catch (e) { log('setup: onReady failed: ' + (e && e.message)); }
    };
    if (action === 'install' || action === 'update') {
        const r = copyUnderLock({ payload, folder, bundled, action, git, log });
        // done: another window's copy is whole; failed or elsewhere, what is
        // there may be half old and half new
        if (r === 'done') ready();
        if (r !== 'copied') return r === 'done' ? 'none' : r;
    }
    ready();
    const notice = action === 'skew' || action === 'unknown';
    if (!notice && !fs.existsSync(loader)) return action;
    const version = readVersionFile(loader);
    const probe = action !== 'unknown' && (force || needsProbe(action, readState(folder), version));
    if (!notice && !probe) return action;
    // one window speaks; the others leave it to that one for a while
    const ask = path.join(folder, 'data', 'ask.lock');
    try {
        fs.mkdirSync(path.join(folder, 'data'), { recursive: true });
        if (!takeLock(ask, Date.now(), force ? 0 : ASK_STALE_MS)) { log('setup: another window is asking'); return action; }
    } catch (e) { log('setup: cannot write ' + path.join(folder, 'data') + ': ' + e.message); return action; }
    try {
        if (action === 'skew') sayOnce(folder, 'skew ' + onDisk + '/' + bundled, () => vscode.window.showInformationMessage(texts.skew(folder, onDisk, bundled)), log);
        if (action === 'unknown') sayOnce(folder, 'unknown ' + bundled, () => vscode.window.showWarningMessage(texts.unknown(folder)), log);
        // through the exports, so the tests can stand in for PowerShell
        if (probe) await module.exports._profileStep({ folder, loader, version, action, force, log });
    } finally { releaseLock(ask); }
    if (action === 'install') vscode.window.showInformationMessage(texts.installed(bundled, folder));
    else if (action === 'update') vscode.window.showInformationMessage(texts.updated(bundled));
    return action;
}

module.exports = {
    setUp, OLD_ID, LOADER, texts, psQuote, windowsPowerShell, lastSaid, readJson,
    _readVersion: readVersion, _compareVersions: compareVersions, _decide: decide, _needsProbe: needsProbe,
    _shouldAsk: shouldAsk, _takeLock: takeLock, _releaseLock: releaseLock, _readState: readState, _writeState: writeState,
    _copyPayload: copyPayload, _psArgs: psArgs, _lastBool: lastBool, _blocksProfile: blocksProfile,
    _inGitCheckout: inGitCheckout, _isForeign: isForeign,
    // replaced by the tests, which start no PowerShell
    _hosts: hosts, _runPs: runPs, _policyOf: policyOf, _allowScripts: allowScripts, _profileStep: profileStep,
    _saidForeign: false
};
