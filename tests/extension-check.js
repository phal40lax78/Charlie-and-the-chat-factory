// Checks extension/extension.js's parts with the vscode module stubbed out:
// which window a request is for, what it says, when it acts without asking,
// how it shows a chat fresh - the plan, and the commands each way runs - how
// the overlay's open chip opens one, which files it watches, and when it
// starts the overlay. Each decides whether - or how - a chat is shown, and
// each fails silently when wrong.
//
//     node tests/extension-check.js
// or, with no node on the machine, VS Code's own Electron:
//     $env:ELECTRON_RUN_AS_NODE = 1; & "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe" tests/extension-check.js
//
// The exit code is the number of failed checks.
const Module = require('module');
const path = require('path');
const folders = [{ uri: { fsPath: path.resolve('/work/projA') } }];
// the settings, by 'section.key': '' for anything unset, as VS Code's get
// hands back a default, and inspect saying where a value was set
const cfgVals = {};
let claudeHere = false;
// the Claude extension's version, as its package.json says it
let claudeVer = '2.1.283';
let oldHere = false;
class TabInputWebview { constructor(viewType) { this.viewType = viewType; } }
class TabInputText { constructor(uri) { this.uri = uri; } }
// what the extension writes to its output channel, without the time
const logged = [];
const stub = {
    workspace: {
        getConfiguration: (sec) => ({
            get: (k) => (sec + '.' + k in cfgVals ? cfgVals[sec + '.' + k] : ''),
            inspect: (k) => (sec + '.' + k in cfgVals ? { key: k, globalValue: cfgVals[sec + '.' + k] } : { key: k })
        }),
        workspaceFolders: folders
    },
    // state.focused: the window has the keyboard, as a handover asks
    window: { createOutputChannel: () => ({ appendLine: (l) => logged.push(l.replace(/^\S+\s+/, '')), show() { } }), state: { focused: true } },
    commands: {},
    ViewColumn: { Active: -1, Beside: -2 },
    Uri: { file: (p) => ({ fsPath: p, scheme: 'file' }) },
    ThemeColor: class { constructor(id) { this.id = id; } },
    extensions: {
        getExtension: (id) => (claudeHere && id === 'anthropic.claude-code' ? { id, packageJSON: { version: claudeVer } } :
            oldHere && id === 'phal40lax78.chat-manager-reload' ? { id } : undefined)
    },
    TabInputWebview, TabInputText
};
const load = Module._load;
Module._load = function (req) {
    if (req === 'vscode') return stub;
    return load.apply(this, arguments);
};
const ext = require(path.join(__dirname, '..', 'extension', 'extension.js'));
// The spawn hook that carries Ultracode and a level into a reopen goes into
// a stand-in for child_process: a test never hooks the real one. spawned:
// every launch's arguments, as the stand-in's own spawn got them
const fakeCp = { spawned: [], spawn(...a) { fakeCp.spawned.push(a); return { args: a }; } };
ext._carryIo.mod = fakeCp;
// The transcripts written here are dated 2026, before this test began: the
// extension host started at the epoch, and a launch is noted there too, so
// every record is of the chat's current process unless a check says when
// that one began
ext._carryIo.hostStart = 0;
ext._carryIo.now = () => 0;
// Every reload asked about is listed for the overlay (askReload): in the
// sandbox, never the real tool folder's data/, which the real overlay reads
const reloadData = path.join(__dirname, '.sandbox', 'ext-reload-data');
ext._reloadIo.dir = reloadData;
// Before any reload, and for a new install, the extension asks the script
// which chats of its window work (safe-restart.js). A test never runs that
// PowerShell - it would load the real tool folder's scripts - so the answer
// is nothing working here, unless a check says otherwise.
const safe = require(path.join(__dirname, '..', 'extension', 'safe-restart.js'));
const noWork = async () => ({ hostPid: process.pid, known: true, chats: [] });
safe._hostWork = noWork;
// Nor the PowerShell that reads a registry entry's process (procFacts): a
// platform of no such look knows nothing of any process, unless a check
// hands it one. procRuns: every script it was given
const procRuns = [];
ext._procIo = { platform: () => 'test', run: async (script) => { procRuns.push(script); return ''; } };
let failed = 0, total = 0;
// A run that ends before its summary fails: an await on what never comes,
// with nothing else holding the event loop, lets node exit 0 there, the
// checks after it never run. The summary alone sets the code.
let summed = false;
process.exitCode = 1;
process.on('exit', () => { if (!summed) console.log('  FAIL  the run ended before its summary, after ' + total + ' checks: an await nothing settled'); });
const check = (name, ok, detail) => {
    total++;
    if (!ok) failed++;
    console.log((ok ? '  ok    ' : '  FAIL  ') + name + (ok || detail === undefined ? '' : '  ' + detail));
};
check('a queued run asks to reload to show it', /queued prompt ran in "T"/.test(ext._message({ kind: 'ran', title: 'T' })));
check('an archive says archived', ext._message({ kind: 'archived', title: 'T' }).startsWith('Archived "T"'));
check('a request without a kind is a delete, as the old ones were', ext._message({ title: 'T' }).startsWith('Deleted "T"'));
const busyMsg = ext._message({ kind: 'deleted', title: 'T', busy: true });
check('a delete while a chat works says so, and does not ask to reload now',
    busyMsg.startsWith('Deleted "T".') && /still working/.test(busyMsg) && !/Reload to refresh/.test(busyMsg));
check('busy: null, as when it could not be judged, asks as before',
    ext._message({ kind: 'archived', title: 'T', busy: null }) === 'Archived "T". Reload to refresh the chat list?');
check('autoReload reloads after a quiet delete', ext._reloadsItself({ kind: 'deleted', busy: false }, true));
check('but never while a chat works', !ext._reloadsItself({ kind: 'deleted', busy: true }, true));
check('autoReload alone never reloads after a queued run', !ext._reloadsItself({ kind: 'ran' }, true, true, true));
check('a new chat says so, and that no reload shows it - Claude Code lists no chat claude -p started - but the chip\'s terminal does',
    /new chat, "T", was started in this folder/.test(ext._message({ kind: 'new', title: 'T' })) && /no reload shows it/.test(ext._message({ kind: 'new', title: 'T' })) &&
    !/Reload to pick it up/.test(ext._message({ kind: 'new', title: 'T' })));
check('and never reloads by itself for one - not with autoReload, nor on an away verdict',
    !ext._reloadsItself({ kind: 'new' }, true, true, true) && !ext._reloadsItself({ kind: 'new', away: true, busy: false }, false, true, true));
const ran = (x) => Object.assign({ kind: 'ran', away: true, busy: false }, x);
check('a queued run reloads itself when nobody is at the PC and nothing else works', ext._reloadsItself(ran({}), false, true, true));
check('which is the default, the setting unset', ext._reloadsItself(ran({}), false, undefined, true));
check('never with someone at the PC', !ext._reloadsItself(ran({ away: false }), false, true, true));
check('never while another chat works', !ext._reloadsItself(ran({ busy: true }), false, true, true));
check('never on what was not judged', !ext._reloadsItself(ran({ away: null }), false, true, true) &&
    !ext._reloadsItself(ran({ busy: null }), false, true, true) && !ext._reloadsItself({ kind: 'ran', busy: false }, false, true, true));
check('never with autoReloadAfterRun off', !ext._reloadsItself(ran({}), true, false, true));
check('and never in a window that is not exactly the judged folder', !ext._reloadsItself(ran({}), false, true, false));
check('exactly the folder: its one folder is the job\'s', ext._isExactlyMine({ cwd: path.resolve('/work/projA') }));
check('a folder inside it is not', !ext._isExactlyMine({ cwd: path.resolve('/work/projA/src') }));
folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
check('nor is a multi-root window, though the request is its', !ext._isExactlyMine({ cwd: path.resolve('/work/projA') }) &&
    ext._isMine({ cwd: path.resolve('/work/projA') }));
folders.pop();
check('the window whose folder it is', ext._isMine({ cwd: path.resolve('/work/projA') }));
check('a folder inside it', ext._isMine({ cwd: path.resolve('/work/projA/src') }));
check('not the sibling -Mobile folder', !ext._isMine({ cwd: path.resolve('/work/projA-Mobile') }));
const files = ext._signalFiles();
check('by default only this tool\'s own folder', files.length === 1 &&
    files[0].endsWith(path.join('Charlie-and-the-chat-factory', 'data', 'reload-request')));

// --- showing a chat fresh: the pure parts -------------------------------------
const SID = '11111111-1111-4111-8111-111111111111';
const plan = (req, v, c) => ext._plan(Object.assign({ kind: 'ran', sessionId: SID }, req), v,
    Object.assign({ fresh: true, claude: true }, c));
check('plan: a terminal holds it - nothing', plan({}, { oldProcess: 'other', busy: false }) === 'none');
check('plan: held working - reload later', plan({}, { oldProcess: 'held', busy: true }) === 'reload');
check('plan: a process left running or not checked - reload', plan({}, { oldProcess: 'live', busy: false }) === 'reload' &&
    plan({}, { oldProcess: 'kept', busy: false }) === 'reload');
check('plan: the old process ended, or none - a tab of its own, whatever else works, never Reload Webviews',
    ['ended', 'none'].every(o => [false, true, null].every(b => plan({}, { oldProcess: o, busy: b }) === 'tab')) &&
    plan({}, null) === 'tab');
check('plan: an old writer, showFresh off, or no Claude extension - reload', plan({ sessionId: undefined }, { oldProcess: 'ended', busy: false }) === 'reload' &&
    plan({}, { oldProcess: 'ended', busy: false }, { fresh: false }) === 'reload' && plan({}, { oldProcess: 'ended', busy: false }, { claude: false }) === 'reload');
const aliveSet = new Set();
ext._alive = (p) => aliveSet.has(p);
aliveSet.add(process.pid);
aliveSet.add(999991);
check('target: the window whose extension host held the chat, wherever its folder', ext._isTarget({ kind: 'ran', cwd: path.resolve('/elsewhere'), hostPids: [process.pid] }));
check('target: not a window when another live one held it', !ext._isTarget({ kind: 'ran', cwd: path.resolve('/work/projA'), hostPids: [999991] }));
check('target: every holder gone - the folder decides, exactly for an open',
    ext._isTarget({ kind: 'ran', cwd: path.resolve('/work/projA/src'), hostPids: [999992] }) &&
    ext._isTarget({ kind: 'open', cwd: path.resolve('/work/projA'), hostPids: [999992] }) &&
    !ext._isTarget({ kind: 'open', cwd: path.resolve('/work/projA/src'), hostPids: [999992] }));
aliveSet.clear();
check('auto: never on a held chat, never on a judgement over 20 s old', !ext._reloadsItself(ran({ busy: true, oldProcess: 'held' }), false, true, true, 1000) &&
    !ext._reloadsItself(ran({}), false, true, true, 30000) && ext._reloadsItself(ran({}), false, true, true, 5000));
claudeHere = true;
const fr = (x) => Object.assign({ kind: 'ran', title: 'T', sessionId: SID, oldProcess: 'ended' }, x);
check('says: Show it, for a run it can show fresh', ext._message(fr({})) === 'A queued prompt ran in "T", which this window still has open. Show it?');
check('says: reload once it finishes, for a chat held working',
    ext._message(fr({ oldProcess: 'held' })) === 'A queued prompt ran in "T" while that chat was working in this window. Reload once it finishes to show the run.');
check('says: use the terminal, for a chat a terminal holds',
    ext._message(fr({ oldProcess: 'other' })) === '"T" is also open in a terminal, so it was not shown here. Type there, or close it first.');
check('says: reload, as 0.5.0 did, for an old writer', ext._message({ kind: 'ran', title: 'T' }) === 'A queued prompt ran in "T", which this window still has open. Reload to show it?');
check('says: after Show it, what went wrong',
    ext._texts.couldNotEnd({ title: 'T' }) === 'chatq could not end the old process of "T", so only a reload shows the run.');
check('says: for an open, no Claude extension, not opened, or open in two places',
    ext._texts.noClaude({ title: 'T' }) === 'The Claude Code extension is not in this window, so "T" cannot be opened here.' &&
    ext._texts.notOpened({ title: 'T' }) === '"T" could not be opened. Chat Manager: Show log has the details.' &&
    /^"T" was also open in this window outside its tabs .* now runs in two places\. Type in the tab, and close the other\.$/.test(ext._texts.twoPlaces({ title: 'T' })));
check('says: open in two places, the other copy idle - close the side bar\'s',
    /^"T" was also open in this window outside its tabs .* now runs in two places\. Type in the tab, and close the side bar's copy, which is idle\.$/.test(ext._texts.twoPlaces({ title: 'T', oldProcess: 'live' })),
    ext._texts.twoPlaces({ title: 'T', oldProcess: 'live' }));
check('says: working outside the tabs - not opened, and to click open again once it finishes, since nothing opens it then by itself; after a run, the side bar\'s copy stale',
    /^"T" is working outside the tabs here .* so it was not opened as a tab.* Click open again once it finishes\.$/.test(ext._texts.working({ title: 'T' })) &&
    !/opens as a tab once/.test(ext._texts.working({ title: 'T' })) &&
    /^"T" was also open in this window outside its tabs .* That copy is stale now and can be closed/.test(ext._texts.sideBarStale({ title: 'T' })));
claudeHere = false;
const ELL = '\u2026';
check('tab label: no title is "Claude Code"', ext._claudeTabLabel('') === 'Claude Code' && ext._claudeTabLabel(undefined) === 'Claude Code');
check('tab label: 25 characters stay whole, 26 are cut to 24 and an ellipsis',
    ext._claudeTabLabel('a'.repeat(25)) === 'a'.repeat(25) && ext._claudeTabLabel('a'.repeat(26)) === 'a'.repeat(24) + ELL);
check('tab label: as the Claude extension showed a real one', ext._claudeTabLabel('Extension icon IMG_8588.jpg') === 'Extension icon IMG_8588.' + ELL,
    ext._claudeTabLabel('Extension icon IMG_8588.jpg'));
check('tab label: the chat\'s, whole or shortened; an untitled chat is no tab\'s',
    ext._labelIsChat('T', 'T') && ext._labelIsChat('Extension icon IMG_8588.jpg', 'Extension icon IMG_8588.' + ELL) &&
    !ext._labelIsChat('T', 'U') && !ext._labelIsChat('', 'Claude Code') && !ext._labelIsChat(undefined, 'Claude Code'));
const cTab = { label: 'c', input: new TabInputWebview('claudeVSCodePanel') };
const fTab = { label: 'f', input: new TabInputText('x') };
check('group: unlocked only when it holds Claude tabs alone - never a mixed one, nor an empty one',
    ext._claudeOnly([cTab]) && ext._claudeOnly([cTab, cTab]) && !ext._claudeOnly([cTab, fTab]) && !ext._claudeOnly([fTab]) &&
    !ext._claudeOnly([]) && !ext._claudeOnly(undefined));
const wTab = { label: '▶ #15 T', input: new TabInputWebview('mainThreadWebview-chatManager.watch') };
check('group: a watch panel standing in for a chat keeps a group Claude\'s; it is never a Claude tab - never closed by a label, nor taken for a chat',
    ext._claudeOnly([cTab, wTab]) && ext._claudeOnly([wTab]) && !ext._claudeOnly([wTab, fTab]) && !ext._isClaudeTab(wTab) && ext._isWatchTab(wTab) && !ext._isWatchTab(cTab));
check('a Claude tab: the Claude extension\'s panel only - never Cline\'s, whose name holds "claude" too, nor a markdown preview',
    ext._isClaudeTab({ label: 'T', input: new TabInputWebview('mainThreadWebview-claudeVSCodePanel') }) &&
    !ext._isClaudeTab({ label: 'T', input: new TabInputWebview('mainThreadWebview-claude-dev.TabPanelProvider') }) &&
    !ext._isClaudeTab({ label: 'T', input: new TabInputWebview('claude-dev.TabPanelProvider') }) &&
    !ext._isClaudeTab({ label: 'Preview claude.md', input: new TabInputWebview('mainThreadWebview-markdown.preview') }) &&
    !ext._isClaudeTab({ label: 'T', input: new TabInputText('claudeVSCodePanel') }));
check('one tab of the chat: exactly one reading as it - twins, or a chat of no title, are none',
    ext._oneTabOf('T', [cTab, { label: 'T' }]).label === 'T' && ext._oneTabOf('T', [{ label: 'T' }, { label: 'T' }]) === undefined &&
    ext._oneTabOf('', [{ label: 'Claude Code' }]) === undefined && ext._oneTabOf('T', []) === undefined);
// --- the watch panel's pure half: extension/watch.js --------------------------
// A queued run's stream as rows, each row's HTML, the header and the page.
const wv = require(path.join(__dirname, '..', 'extension', 'watch.js'));
const fx = (name) => require('fs').readFileSync(path.join(__dirname, 'fixtures', 'stream', name), 'utf8').split('\n');
const longOut = 'z'.repeat(400);
const wLines = fx('watch-claude.jsonl').map(l => l.replace('{{LONG}}', longOut));
const T0 = 1e12;
const wItems = wv.watchItems(wLines, T0);
const kinds = wItems.map(i => i.kind).join();
const wTool = (id) => wItems.find(i => i.kind === 'tool' && i.id === id) || {};
const wRes = (id) => wItems.find(i => i.kind === 'toolResult' && i.id === id) || {};
check('watch: the rows a run makes - init, its text, tools, their results, a denial, the limit, the end; the prompt, thinking and an allowed rate event left out',
    kinds === 'init,text,tool,toolResult,tool,toolResult,tool,toolResult,tool,tool,toolResult,toolResult,tool,toolResult,tool,denied,toolResult,tool,limit,result' &&
    !wItems.some(i => i.kind === 'text' && /the model's own|run the tests and fix/.test(i.text)), kinds);
check('watch: init names the model, the mode and Claude Code\'s version; a tool its argument - a command\'s first line, the file, the pattern, the description',
    wItems[0].model === 'claude-fake-1' && wItems[0].mode === 'acceptEdits' && wItems[0].version === '2.1.283' &&
    wTool('toolu_bash').arg === 'npm test' && wTool('toolu_read').arg === 'C:\\work\\parser.js' && wTool('toolu_grep').arg === 'parseLine\\(' &&
    wTool('toolu_agent').arg === 'Look for callers', JSON.stringify(wItems.filter(i => i.kind === 'tool').map(i => i.arg)));
check('watch: a subagent\'s rows indented under its Agent; the heartbeat on its tool\'s row, its clock set back by it',
    wTool('toolu_grep').depth === 1 && wRes('toolu_grep').depth === 1 && wTool('toolu_agent').depth === 0 &&
    wTool('toolu_bash').progress === 90 && wTool('toolu_bash').since === T0 - 90000, JSON.stringify([wTool('toolu_grep'), wTool('toolu_bash')]));
check('watch: a result\'s first 3 lines and "+N lines", at most 300 characters; an error\'s row and its tool marked',
    wRes('toolu_bash').text === 'line 1\nline 2\nline 3' && wRes('toolu_bash').more === 2 && wRes('toolu_bash').error && wTool('toolu_bash').error &&
    wRes('toolu_read').text === 'z'.repeat(300) + '...' && wRes('toolu_read').more === 0 && !wTool('toolu_read').error,
    JSON.stringify([wRes('toolu_bash'), wRes('toolu_read').text.length]));
check('watch: an edit\'s size - Edit +2 -1, Write +3 - and the denial, the limit\'s reset, the end\'s turns and time',
    JSON.stringify(wTool('toolu_edit').edit) === '{"plus":2,"minus":1}' && JSON.stringify(wTool('toolu_write').edit) === '{"plus":3,"minus":0}' &&
    wItems.some(i => i.kind === 'denied' && i.tool === 'Write') && wItems.some(i => i.kind === 'limit' && i.resetsAt === 1790000000) &&
    wItems.some(i => i.kind === 'result' && i.subtype === 'success' && i.turns === 7 && i.durationMs === 754000),
    JSON.stringify([wTool('toolu_edit').edit, wTool('toolu_write').edit]));
check('watch: the latest TodoWrite pinned - what is being done, and how far along the list; none, nothing pinned',
    wv.pinnedTodo(wItems) === 'Now: Fixing the parser (3/4)' && wv.pinnedTodo([]) === '' &&
    wv.pinnedTodo(wv.watchItems([JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'x', name: 'TodoWrite', input: { todos: [{ content: 'a', status: 'completed' }] } }] } })])) === 'Todo: 1/1 done',
    wv.pinnedTodo(wItems));
const openRows = wv.watchItems(wLines.slice(0, wLines.findIndex(l => /"type":"result"/.test(l))), T0);
const closedRows = wItems;
check('watch: a tool still running carries its own clock (data-since) until its result - or the run\'s end - comes',
    /data-since="1000000000000"/.test(wv.itemHtml(openRows.find(i => i.id === 'toolu_open'))) && closedRows.find(i => i.id === 'toolu_open').done === true &&
    !/data-since/.test(wv.itemHtml(closedRows.find(i => i.id === 'toolu_open'))) && !/data-since/.test(wv.itemHtml(wTool('toolu_bash'))),
    wv.itemHtml(openRows.find(i => i.id === 'toolu_open')));
const bigLine = JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_big', content: 'q'.repeat(300 * 1024) }] } });
const bigRows = wv.watchItems([JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'toolu_big', name: 'Read', input: { file_path: 'x' } }] } }), bigLine]);
check('watch: a line over 256 KB is never parsed - "(large result)", its tool closed, found by the id near its end',
    bigLine.length > wv.LARGE && bigRows[1].kind === 'toolResult' && bigRows[1].text === '(large result)' && bigRows[1].large && bigRows[0].done,
    JSON.stringify(bigRows.map(r => [r.kind, r.text, r.done])));
const cItems = wv.watchItems(fx('watch-codex.jsonl'), T0);
check('watch: a Codex run as Get-ChatqLogEntries reads it - its commands (a failed one marked), its message, a failed turn and an error',
    cItems.map(i => i.kind).join() === 'tool,tool,text,error,error' && cItems[0].name === 'shell' && cItems[0].arg === 'git status' && cItems[0].done && !cItems[0].error &&
    cItems[1].error && cItems[2].text === 'The build fails.' && cItems[3].text === 'stream disconnected',
    JSON.stringify(cItems));
const escRow = wv.itemHtml(wItems.find(i => i.kind === 'text'));
check('watch: every text escaped - a reply\'s <tags> and & read as typed, never as the page\'s own',
    escRow.includes('Running the &lt;suite&gt; &amp; fixing it.') && !escRow.includes('<suite>') &&
    wv.itemHtml({ i: 0, kind: 'tool', name: '<b>', arg: '"x"', done: true }).includes('&lt;b&gt;') && wv.esc('\'"') === '&#39;&quot;', escRow);
const tl = { rest: null };
const tl1 = wv.takeLines(tl, Buffer.from('{"a":1}\n{"b":'));
const tl2 = wv.takeLines(tl, Buffer.from('2}\r\n\xc3', 'latin1'));
const tl3 = wv.takeLines(tl, Buffer.from([0xa9, 0x0a]));
check('watch: the log read in pieces - a line taken only once its newline has come, a character split between two reads kept whole',
    tl1.join('|') === '{"a":1}' && tl2.join('|') === '{"b":2}' && tl3.join('|') === '\u00e9', [tl1, tl2, tl3].map(x => x.join('|')).join(' / '));
const jobRun = { id: 'j', seq: 15, title: 'Parser <fix>', state: 'running', startedAt: '2026-09-28T10:00:00Z', provider: 'claude', sessionId: 'x',
    permitWaiting: { tool: 'Bash', until: '2026-09-28T10:05:00Z' } };
const hRun = wv.headerHtml(jobRun, { prompt: 'fix the parser', lastAt: 5 });
const hDone = wv.headerHtml(Object.assign({}, jobRun, { state: 'done', permitWaiting: null }), {});
const hCodex = wv.headerHtml(Object.assign({}, jobRun, { state: 'failed', provider: 'codex', result: { reason: 'boom' } }), {});
const hLimit = wv.stateText({ state: 'queued', startedAt: 'x', history: [{ state: 'queued', why: 'limited mid-run, continues at 14:05' }] });
check('watch: the header - #15, the title escaped, running with its clock and the time since the last output, the phone\'s question in the warning colour, the prompt; Cancel and Log while it runs',
    hRun.includes('#15 \u00b7 Parser &lt;fix&gt; \u00b7') && /class="tick" data-since="\d+"/.test(hRun) && hRun.includes('class="ago" data-at="5"') &&
    hRun.includes('<div class="permit">waits for your answer on the phone: Bash, until ' + wv.hhmm('2026-09-28T10:05:00Z') + '</div>') &&
    hRun.includes('fix the parser') && hRun.includes('data-act="cancel"') && hRun.includes('data-act="log"') && !hRun.includes('data-act="open"'), hRun);
check('watch: once it ended - no Cancel, Open chat - never for a Codex chat, whose reason is said; a job back in the queue at the limit says when it goes on',
    !hDone.includes('data-act="cancel"') && hDone.includes('data-act="open"') && !hDone.includes('permit') &&
    !hCodex.includes('data-act="open"') && hCodex.includes('failed - boom') && hLimit === 'stopped at the limit - back in the queue, continues at 14:05',
    hDone + ' | ' + hCodex + ' | ' + hLimit);
const page = wv.pageHtml('N0nce', 'job</script>');
check('watch: the page - a policy that loads nothing and runs only its own nonce\'d script and style, VS Code\'s theme colours, the job id kept in its state, a bad one never closing the script',
    page.includes('content="default-src \'none\'; style-src \'nonce-N0nce\'; script-src \'nonce-N0nce\';"') && page.includes('<script nonce="N0nce">') &&
    page.includes('<style nonce="N0nce">') && !/unsafe-inline|https?:/.test(page) && /var\(--vscode-editor-background\)/.test(page) &&
    page.includes('api.setState({jobId:"job\\u003c/script>"})') && (page.match(/<\/script>/g) || []).length === 1 &&
    page.includes('api.postMessage({type:"ready"})'), page.slice(0, 300));
check('watch: times as the panel says them', wv.fmtDur(45000) === '45 s' && wv.fmtDur(372000) === '6m 12s' && wv.fmtDur(3840000) === '1h 04m' && wv.hhmm('') === '');
// a retry appends to the same log (Invoke-ChatqProcess opens it to append),
// and an attempt cut off - cancelled, its watcher gone - wrote no result
const wTu = (id) => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id, name: 'Bash', input: { command: 'npm test' } }] } });
const wInit = JSON.stringify({ type: 'system', subtype: 'init', model: 'm' });
const wRetry = wv.watchItems([wInit, wTu('toolu_cut'), wInit, wTu('toolu_new')], T0);
const wCx = (o) => JSON.stringify(o);
const wCodexRetry = wv.watchItems([wCx({ type: 'thread.started', thread_id: 't1' }), wCx({ type: 'turn.started' }),
    wCx({ type: 'item.started', item: { id: 'c1', type: 'command_execution', command: 'npm test' } }),
    wCx({ type: 'thread.started', thread_id: 't2' }), wCx({ type: 'turn.started' }), wCx({ type: 'item.started', item: { id: 'c2', type: 'command_execution', command: 'ls' } })], T0);
const wById = (items, id) => items.find(i => i.id === id) || {};
check('watch: a retry\'s init - Codex\'s thread.started or turn.started - closes every tool the cut-off attempt left open, which would read as running beside the new ones',
    wById(wRetry, 'toolu_cut').done === true && wById(wRetry, 'toolu_new').done === false && !/data-since/.test(wv.itemHtml(wById(wRetry, 'toolu_cut'))) &&
    wRetry.map(i => i.kind).join() === 'init,tool,init,tool' &&
    wById(wCodexRetry, 'c1').done === true && wById(wCodexRetry, 'c2').done === false && wCodexRetry.map(i => i.kind).join() === 'tool,tool',
    JSON.stringify([wRetry, wCodexRetry]));
// the rows kept: a run of hours makes tens of thousands
const wText = (t) => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: t }] } });
const wCap = wv.newParser({ maxRows: 5 });
wCap.push(wTu('toolu_old'), T0);
for (let i = 0; i < 7; i++) wCap.push(wText('row ' + i), T0);
wCap.push(JSON.stringify({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_old', content: 'late' }] } }), T0);
const wCapD = wCap.dirty();
const wBig = wv.newParser();
for (let i = 0; i < wv.MAX_ROWS + 3; i++) wBig.push(wText('r' + i), T0);
check('watch: only the last rows kept - 5000 - each still by its place in the whole run, how many went before said; a row changed after it went, and its tool, forgotten',
    wCap.items.length === 5 && wCap.dropped === 4 && wCap.items[0].i === 4 && wCap.items[4].kind === 'toolResult' && wCap.items[4].i === 8 &&
    wCapD.length === 5 && wCapD.every(Boolean) && wCapD[0].i === 4 &&
    wv.MAX_ROWS === 5000 && wBig.items.length === 5000 && wBig.dropped === 3 && wBig.items[0].text === 'r3',
    JSON.stringify([wCap.items.map(i => i.i), wCap.dropped, wCapD.map(i => i && i.i), wBig.items.length, wBig.dropped]));
// the pinned todo outlives its row: a TodoWrite, then more rows than are
// kept - still pinned, from the parser's own last list, and a later one
// takes its place
const wTodo = (todos) => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'td' + todos.length, name: 'TodoWrite', input: { todos } }] } });
const wPin = wv.newParser({ maxRows: 5 });
wPin.push(wTodo([{ content: 'a', status: 'completed' }, { content: 'b', activeForm: 'Doing b', status: 'in_progress' }]), T0);
for (let i = 0; i < 8; i++) wPin.push(wText('row ' + i), T0);
const wPinOld = wv.pinnedTodo(wPin), wPinRows = wv.pinnedTodo(wPin.items), wPinGone = !wPin.items.some(i => i.todos);
wPin.push(wTodo([{ content: 'a', status: 'completed' }, { content: 'b', status: 'completed' }, { content: 'c', status: 'pending' }]), T0);
check('watch: the pinned todo kept apart from the rows - a TodoWrite dropped past the kept rows still pinned, and the next one replaces it',
    wPinGone && wPinRows === '' && wPinOld === 'Now: Doing b (2/2)' && wv.pinnedTodo(wPin) === 'Todo: 2/3 done' &&
    wv.pinnedTodo(wv.newParser()) === '' && wv.pinnedTodo(null) === '',
    JSON.stringify([wPinOld, wPinRows, wv.pinnedTodo(wPin)]));
// back in the queue after a try - the limit mid-run: Open chat, the tab the
// handover closed put back by nothing else until the next run
const hBack = wv.headerHtml({ seq: 15, title: 'T', state: 'queued', startedAt: '2026-09-28T10:00:00Z', provider: 'claude', sessionId: 'x',
    history: [{ state: 'queued', why: 'limited mid-run, continues at 14:05' }], result: { kind: 'limited' } }, {});
const hNever = wv.headerHtml({ seq: 15, title: 'T', state: 'queued', provider: 'claude', sessionId: 'x' }, {});
check('watch: a job back in the queue after a try offers Open chat; one never tried does not',
    hBack.includes('data-act="open"') && !hBack.includes('data-act="cancel"') && !hNever.includes('data-act="open"') &&
    wv.headerHtml({ seq: 15, state: 'queued', attempts: 1, provider: 'claude', sessionId: 'x' }, {}).includes('data-act="open"'), hBack + ' | ' + hNever);
// the page's own script, run against a DOM of just what it touches: how
// often it looks through the page, and how many times it puts rows in
const pageRun = () => {
    const stats = { lookups: 0, rowsAppends: 0 };
    let rowsEl = null;
    class El {
        constructor(tag) { this.tag = tag; this.kids = []; this.parent = null; this.attrs = {}; this.text = ''; this.html = ''; }
        get firstElementChild() { return this.kids[0] || null; }
        appendChild(c) {
            if (this === rowsEl) stats.rowsAppends++;
            for (const k of c.frag ? c.kids.splice(0) : [c]) { if (k.parent) k.remove(); k.parent = this; this.kids.push(k); }
            return c;
        }
        replaceWith(n) { const p = this.parent; p.kids[p.kids.indexOf(this)] = n; n.parent = p; this.parent = null; }
        remove() { if (this.parent) { this.parent.kids.splice(this.parent.kids.indexOf(this), 1); this.parent = null; } }
        getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
        querySelector(sel) { stats.lookups++; const m = /data-i=\\?"(\d+)/.exec(sel); return (m && this.kids.find(k => k.attrs['data-i'] === m[1])) || null; }
        set textContent(v) { for (const k of this.kids) k.parent = null; this.kids = []; this.text = v; }
        get textContent() { return this.text; }
        set innerHTML(h) { this.html = h; }
    }
    const make = (tag) => {
        const e = new El(tag);
        if (tag === 'template') Object.defineProperty(e, 'innerHTML', { set(h) { const m = /data-i="(\d+)"/.exec(h); const el = new El('div'); if (m) el.attrs['data-i'] = m[1]; el.html = h; e.content = { firstElementChild: el }; } });
        return e;
    };
    const els = { head: new El('header'), pin: new El('div'), earlier: new El('div'), rows: new El('main') };
    rowsEl = els.rows;
    let onMsg = null;
    const doc = { getElementById: (id) => els[id], createElement: make, createDocumentFragment: () => { const f = new El('#fragment'); f.frag = true; return f; },
        querySelectorAll: () => { stats.lookups++; return []; }, addEventListener() { }, body: { scrollHeight: 0 } };
    const win = { addEventListener: (t, cb) => { if (t === 'message') onMsg = cb; }, innerHeight: 0, scrollY: 0, scrollTo() { } };
    const src = /<script nonce="[^"]*">([\s\S]*)<\/script>/.exec(wv.pageHtml('n', 'j'))[1];
    require('vm').runInNewContext(src, { document: doc, window: win, acquireVsCodeApi: () => ({ setState() { }, postMessage() { } }), setInterval: () => 0 });
    return { els, stats, send: (m) => { stats.lookups = 0; stats.rowsAppends = 0; onMsg({ data: m }); }, ids: () => els.rows.kids.map(k => Number(k.attrs['data-i'])) };
};
const pRows = (from, n, word) => Array.from({ length: n }, (_, k) => ({ i: from + k, html: '<div class="row text" data-i="' + (from + k) + '">' + (word || 'r') + '</div>' }));
const pg = pageRun();
pg.send({ reset: true, rows: pRows(0, 3000) });
// tick's own looks for the clocks: two a message, whatever the rows
const pg1 = [pg.stats.lookups, pg.stats.rowsAppends, pg.els.rows.kids.length];
pg.send({ rows: pRows(5, 1, 'changed') });
const pg2 = [pg.stats.lookups, pg.els.rows.kids.length, pg.els.rows.kids[5].html.includes('changed')];
pg.send({ rows: pRows(3000, 2010) });
const pg3 = [pg.els.rows.kids.length, pg.ids()[0], pg.ids()[4999]];
pg.send({ rows: pRows(3, 1, 'late'), earlier: '10 earlier rows are not kept here - Log has them' });
const pg4 = [pg.els.rows.kids.length, pg.ids().includes(3), pg.els.earlier.text];
pg.send({ reset: true, rows: pRows(20, 2) });
check('watch page: a full batch - the page loaded again - built apart and put in at once, with no look through the page per row; a row changed found by its place; only the last 5000 kept, one changed after it went left out; the earlier ones said',
    pg1[0] === 2 && pg1[1] === 1 && pg1[2] === 3000 && pg2[0] === 2 && pg2[1] === 3000 && pg2[2] &&
    pg3[0] === 5000 && pg3[1] === 10 && pg3[2] === 5009 && pg4[0] === 5000 && pg4[1] === false && /^10 earlier rows/.test(pg4[2]) &&
    pg.ids().join() === '20,21' && pg.stats.rowsAppends === 1,
    JSON.stringify([pg1, pg2, pg3, pg4, pg.ids().slice(0, 5)]));

const dec = (args) => Buffer.from(args[args.length - 1], 'base64').toString('utf16le');
const [vExe, vArgs] = ext._verdictCommand('C:\\t\\Charlie-and-the-chat-factory.ps1', { sessionId: SID, cwd: "D:\\it's here", home: 'D:\\h\u2019s' });
const vText = dec(vArgs);
check('Show it\'s check: marked as the overlay, every value quoted, curly ones too',
    vText.startsWith("$env:CHATQ_OVERLAY='1'") && vText.includes("-Cwd 'D:\\it''s here'") && vText.includes("-ConfigDir 'D:\\h\u2019\u2019s'") &&
    vText.includes('-Via button') && vText.includes('ConvertTo-ChatFreshVerdict') && vArgs.includes('-NoProfile') && !!vExe, vText);
const v1Text = dec(ext._verdictCommand('C:\\t\\x.ps1', { sessionId: SID, cwd: 'C:\\w' }, { judgeOnly: true })[1]);
const v2Text = dec(ext._verdictCommand('C:\\t\\x.ps1', { sessionId: SID, cwd: 'C:\\w' }, { grace: 8, hostPid: 4321, startedBefore: '2026-09-28T10:00:00.000Z' })[1]);
check('Show it\'s two checks: the first judges only; the second waits 8 s for the process to leave, and ends only this window\'s, started before the tab was opened',
    /-Via button -SessionId '[^']+' -Cwd 'C:\\w' -JudgeOnly\)/.test(v1Text) && !/GraceSeconds|HostPid/.test(v1Text) &&
    v2Text.includes(" -GraceSeconds 8 -HostPid 4321 -StartedBefore '2026-09-28T10:00:00.000Z')") && !v2Text.includes('-JudgeOnly'), v1Text + ' / ' + v2Text);
let threw = false;
try { ext._verdictCommand('x.ps1', { sessionId: "x'; Remove-Item C:\\ -Recurse; '", cwd: 'C:\\' }); } catch (e) { threw = true; }
check('and a session id that is no GUID is never put in one', threw);
const good = '{"busy":false,"oldProcess":"ended","outcome":"ok","hostPids":[1234]}';
check('the verdict: the last JSON line, noise before it ignored', (ext._parseVerdict('loading\r\nWARNING: x\r\n' + good + '\r\n') || {}).oldProcess === 'ended');
check('bad JSON, or a field of the wrong type, is no verdict', ext._parseVerdict('{"busy":fals') === null &&
    ext._parseVerdict('{"busy":"no","oldProcess":"ended","outcome":"ok","hostPids":[]}') === null &&
    ext._parseVerdict('{"busy":false,"oldProcess":"gone","outcome":"ok","hostPids":[]}') === null &&
    ext._parseVerdict('{"busy":false,"oldProcess":"ended","outcome":"ok","hostPids":["1"]}') === null && ext._parseVerdict('') === null);
const of = ext._openFiles();
check('the open requests: data/open-request beside the reload one', of.length === 1 && of[0].endsWith(path.join('Charlie-and-the-chat-factory', 'data', 'open-request')));
cfgVals['chatManager.folder'] = path.resolve('/t/tool');
check('both follow chatManager.folder', ext._signalFiles()[0] === path.resolve('/t/tool/data/reload-request') &&
    ext._openFiles()[0] === path.resolve('/t/tool/data/open-request'));
cfgVals['chatManager.folder'] = '~/elsewhere';
check('and a folder under ~ is under the home folder', ext._toolFolder() === path.join(require('os').homedir(), 'elsewhere'), ext._toolFolder());
delete cfgVals['chatManager.folder'];
cfgVals['chatManagerReload.signalFile'] = path.resolve('/x/data/reload-request');
check('unset, the old extension\'s signalFile still places them', ext._openFiles()[0] === path.resolve('/x/data/open-request'));
cfgVals['chatManager.folder'] = path.resolve('/t/tool');
check('but chatManager.folder wins over it', ext._toolFolder() === path.resolve('/t/tool'));
delete cfgVals['chatManager.folder'];
delete cfgVals['chatManagerReload.signalFile'];
cfgVals['chatManagerReload.showFresh'] = false;
const oldOff = ext._showFresh();
cfgVals['chatManager.showFresh'] = true;
const newOn = ext._showFresh();
delete cfgVals['chatManagerReload.showFresh'];
delete cfgVals['chatManager.showFresh'];
check('an old chatManagerReload setting is read where the new one is unset, and the new one wins', oldOff === false && newOn === true && ext._showFresh() === true);

// the whole path, request file to reload, with what the window would do recorded
(async () => {
    const fs = require('fs');
    const calls = [];
    stub.commands.executeCommand = (c) => { calls.push(c); };
    stub.window.showInformationMessage = async (m) => { calls.push('ask'); };
    stub.window.showWarningMessage = async (m) => { calls.push('warn'); };
    const state = {};
    // VS Code's Memento, over a plain object
    const memo = (o) => ({ get: (k) => o[k], update: async (k, v) => { o[k] = v; } });
    const context = { globalState: memo(state) };
    const dir = path.join(__dirname, '.sandbox');
    fs.mkdirSync(dir, { recursive: true });
    // a Claude home holding no chats: a label is looked up in the folder's
    // chats, and a test never reads the real ~/.claude
    const noHome = path.join(dir, 'ext-nohome');
    process.env.CLAUDE_CONFIG_DIR = noHome;
    const file = path.join(dir, 'extension-check-request.json');
    const put = (id) => fs.writeFileSync(file, JSON.stringify(ran({ id, cwd: path.resolve('/work/projA'), at: new Date().toISOString() })));
    const tick = () => new Promise(r => setTimeout(r, 20));
    put('r1');
    ext._check(context, file, true);
    await tick();
    check('a window just opened takes a recent queued run as seen, and neither asks nor reloads',
        calls.length === 0 && state['chatManagerReload.lastSeenId'] === 'r1');
    fs.writeFileSync(file, JSON.stringify({ id: 'n1', kind: 'new', title: 'T', cwd: path.resolve('/work/projA'), at: new Date().toISOString() }));
    ext._check(context, file, true);
    await tick();
    check('and the new chat a run started too - no reload would list it anyway',
        calls.length === 0 && state['chatManagerReload.lastSeenId'] === 'n1');
    put('r2');
    ext._check(context, file, false);
    await tick();
    check('one that was open reloads by itself', calls.join() === 'workbench.action.reloadWindow' && state['chatManagerReload.lastSeenId'] === 'r2');
    calls.length = 0;
    folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
    put('r3');
    ext._check(context, file, false);
    await tick();
    folders.pop();
    check('a multi-root one asks instead', calls.join() === 'ask');
    calls.length = 0;
    const newButtons = [];
    const plainInfo = stub.window.showInformationMessage;
    stub.window.showInformationMessage = async (m, ...b) => { calls.push('ask'); newButtons.push(b.length); };
    fs.writeFileSync(file, JSON.stringify({ id: 'n2', kind: 'new', title: 'T', cwd: path.resolve('/work/projA'), at: new Date().toISOString() }));
    ext._check(context, file, false);
    await tick();
    stub.window.showInformationMessage = plainInfo;
    check('a new chat a run started, in a window open on its folder: said, with no reload offered - it would cut off what works here and list nothing',
        calls.join() === 'ask' && newButtons.join() === '0', calls.join() + ' ' + newButtons.join());

    // two requests inside one poll: the newest is the file, the one before it
    // under earlier (Save-ChatRequest) - each taken once, oldest first
    const del = (id, title, x) => Object.assign({ id, kind: 'deleted', title, busy: false, cwd: path.resolve('/work/projA'), at: new Date().toISOString() }, x);
    const saidDel = [];
    stub.window.showInformationMessage = async (m) => { calls.push('ask'); saidDel.push(m); };
    calls.length = 0;
    fs.writeFileSync(file, JSON.stringify(Object.assign(del('d2', 'B'), { earlier: [del('d1', 'A'), { kind: 'deleted', title: 'no id' }] })));
    const rq2 = ext._requestsOf(file);
    ext._check(context, file, false);
    await tick();
    const d2Calls = calls.join(), d2Said = saidDel.slice();
    ext._check(context, file, false);
    await tick();
    const d2Again = calls.join();
    const d2Last = state['chatManagerReload.lastSeenId'], d2Seen = state['chatManager.seenIds'].slice(-2).join();
    // the script's next write: the newest on top, the last one carried
    fs.writeFileSync(file, JSON.stringify(Object.assign(del('d3', 'C'), { earlier: [del('d2', 'B')] })));
    calls.length = 0;
    saidDel.length = 0;
    ext._check(context, file, false);
    await tick();
    stub.window.showInformationMessage = plainInfo;
    check('a file of two requests: each asked once, the earlier first - one with no id passed by - and taken as seen, the newest in the one key an older extension reads',
        rq2.map(r => r.id || '-').join() === 'd1,d2' && rq2[1].earlier === undefined &&
        d2Calls === 'ask,ask' && /^Deleted "A"\./.test(d2Said[0]) && /^Deleted "B"\./.test(d2Said[1]) && d2Again === d2Calls &&
        d2Last === 'd2' && d2Seen === 'd1,d2', d2Calls + ' | ' + d2Said.join(' | ') + ' | ' + d2Last + ' ' + d2Seen);
    check('the next write carries the last: only the new one asked', calls.join() === 'ask' && /^Deleted "C"\./.test(saidDel[0]) &&
        state['chatManagerReload.lastSeenId'] === 'd3', calls.join() + ' | ' + saidDel.join(' | '));
    // what another window's write of the list dropped: this window's own
    // memory still has it
    state['chatManager.seenIds'] = [];
    delete state['chatManagerReload.lastSeenId'];
    calls.length = 0;
    ext._check(context, file, false);
    await tick();
    const lostList = calls.join();
    const state2 = {};
    const many = { globalState: memo(state2) };
    for (let i = 0; i < 20; i++) {
        fs.writeFileSync(file, JSON.stringify(del('m' + i, 'M', { kind: 'new' })));
        ext._check(many, file, true);
    }
    await tick();
    check('seen ids: this window\'s own kept beside globalState; globalState keeps the last 16',
        lostList === '' && state2['chatManager.seenIds'].length === 16 && state2['chatManager.seenIds'][15] === 'm19' && state2['chatManager.seenIds'][0] === 'm4',
        lostList + ' ' + JSON.stringify(state2['chatManager.seenIds']));
    check('an older script\'s file, or one no object, is one request or none', ext._requestsOf(file).length === 1 &&
        (fs.writeFileSync(file, '[{"id":"x"}]'), ext._requestsOf(file).length === 0) && (fs.writeFileSync(file, 'nope'), ext._requestsOf(file).length === 0));
    // the first look after an update from an extension that kept one id: no
    // list yet, and every request up to that id was the old extension's -
    // taken as seen, never asked again; an id the file no longer holds is
    // older than all it does, and none is
    const upTry = (legacy) => {
        const st = { 'chatManagerReload.lastSeenId': legacy };
        const ctx = { globalState: memo(st) };
        fs.writeFileSync(file, JSON.stringify(Object.assign(del('g3', 'C'), { earlier: [del('g1', 'A'), del('g2', 'B')] })));
        saidDel.length = 0;
        ext._check(ctx, file, true);
        return st;
    };
    stub.window.showInformationMessage = async (m) => { saidDel.push(m); };
    const upSt = upTry('g2');
    await tick();
    const upSaid = saidDel.map(m => m.slice(0, 11)).join('|');
    const goneSt = upTry('gone');
    await tick();
    const goneSaid = saidDel.map(m => m.slice(0, 11)).join('|');
    stub.window.showInformationMessage = plainInfo;
    check('after an update from an extension that kept one id: what the file carries up to it taken as seen, only the newer asked; an id it no longer holds - all asked',
        upSaid === 'Deleted "C"' && upSt['chatManager.seenIds'].join() === 'g1,g2,g3' &&
        goneSaid === 'Deleted "A"|Deleted "B"|Deleted "C"' && goneSt['chatManager.seenIds'].join() === 'g1,g2,g3', upSaid + ' / ' + goneSaid);

    // --- the commands each way runs -------------------------------------------
    // every wait to nothing; the ages a request may have stay what they are.
    // labelBudget 0 is no limit: a slow machine never answers shared for it
    for (const k of ['retry', 'tabSettle', 'tabRecount', 'startupOpen', 'commandTimeout', 'labelBudget']) ext._timing[k] = 0;
    claudeHere = true;
    // the Claude extension as S29 saw it: editor.open (pinned to a tab) and
    // primaryEditor.open each reveal a panel the chat has, or make one, loaded
    // from disk
    // two groups, side by side; the second one empty and never shown until
    // a test puts it there
    const tabs = [], tabs2 = [];
    const active = { tab: undefined }, active2 = { tab: undefined };
    // peek: called each time the first group's front tab is read, for a tab
    // that turns up between two looks
    let peek = null;
    // isActive as VS Code's own TabGroup has it, the same answer activeTabGroup gives
    const group = { viewColumn: 1, get tabs() { return tabs; }, get activeTab() { if (peek) peek(); return active.tab; }, get isActive() { return activeGroup === group; } };
    const group2 = { viewColumn: 2, get tabs() { return tabs2; }, get activeTab() { return active2.tab; }, get isActive() { return activeGroup === group2; } };
    const slot = (g) => (g === group2 ? { list: tabs2, act: active2 } : { list: tabs, act: active });
    let groupsNow = [group], activeGroup = group, makeIn = group;
    const titles = { [SID]: 'T' };
    let fail = {};
    let makeLater = 0;
    // onMake: called with the chat's id as an open makes its new tab - where
    // the Claude extension would start the tab's claude process
    let onMake = null;
    let revealMode = 'normal';
    // never: the command given never settles
    let never = '';
    const claudeTab = (sid, label, g) => ({ label, sid, input: new TabInputWebview('claudeVSCodePanel'), group: g || group });
    // the chat's tab put in the first group, and the first tab of it in front
    const frontTab = () => { tabs.push(claudeTab(SID, 'T')); active.tab = tabs[0]; };
    stub.window.tabGroups = {
        get all() { return groupsNow; }, get activeTabGroup() { return activeGroup; },
        close: async (t) => {
            calls.push('close:' + t.label);
            const s = slot(t.group);
            s.list.splice(s.list.indexOf(t), 1);
            if (s.act.tab === t) s.act.tab = s.list[0];
            return true;
        }
    };
    const bars = [];
    stub.window.setStatusBarMessage = (m, ms) => { bars.push(m); return { dispose() { } }; };
    // every open's arguments after the command, as the Claude extension got
    // them, refused or not; onFail: called as a command is refused
    const openArgs = [];
    let onFail = null;
    stub.commands.executeCommand = async (c, sid, ...rest) => {
        calls.push(c);
        const isOpen = c === 'claude-vscode.editor.open' || c === 'claude-vscode.primaryEditor.open';
        if (isOpen) openArgs.push([sid, ...rest]);
        if (never === c) return new Promise(() => { });
        if (fail[c]) { fail[c]--; if (onFail) onFail(c); throw new Error('boom'); }
        if (isOpen) {
            const have = tabs.concat(tabs2).find(t => t.sid === sid);
            if (revealMode === 'nothing') return;
            if (have) { slot(have.group).act.tab = have; return; }
            const make = () => { const t = claudeTab(sid, titles[sid], makeIn); const s = slot(makeIn); s.list.push(t); s.act.tab = t; if (onMake) onMake(sid); };
            if (makeLater) setTimeout(make, makeLater); else make();
        }
    };
    let answer, warnAnswer;
    const asked = [];
    stub.window.showInformationMessage = async (m, ...b) => { calls.push('ask'); asked.push(m); return b.includes(answer) ? answer : undefined; };
    stub.window.showWarningMessage = async (m, ...b) => { calls.push('warn'); asked.push(m); return b.includes(warnAnswer) ? warnAnswer : undefined; };
    const reqT = { kind: 'ran', sessionId: SID, title: 'T' };
    // the chip's open of the chat, nothing holding it unless x says so
    const openT = (x) => ext._openTab(Object.assign({ kind: 'open', sessionId: SID, title: 'T', oldProcess: 'none', hostPids: [] }, x));
    const reset = () => {
        calls.length = 0; asked.length = 0; tabs.length = 0; tabs2.length = 0; active.tab = undefined; active2.tab = undefined; fail = {}; makeLater = 0;
        revealMode = 'normal'; peek = null; groupsNow = [group]; activeGroup = group; makeIn = group; never = ''; warnAnswer = undefined;
        openArgs.length = 0; claudeVer = '2.1.283'; onFail = null;
    };
    // the chat's tab up, and its group - Claude tabs alone - unlocked
    const OPEN = 'claude-vscode.editor.open';
    const OPEN_FULL = 'claude-vscode.primaryEditor.open';
    const UNLOCK = 'workbench.action.unlockEditorGroup';
    const OPENED = OPEN + ',' + UNLOCK;

    check('Reload Webviews and the side bar\'s focus are gone', ext._showWebviews === undefined && ext._focus === undefined);

    reset();
    const r1 = await ext._showTab(reqT);
    check('a tab: none open - one open, loaded from disk, nothing closed, and its group of Claude tabs unlocked', r1 === 'new' && calls.join() === OPENED, calls.join());
    // an ordinary tab, never a full editor: primaryEditor.open's has no header
    // - no title, no Session history, no New session
    const pin = (col) => JSON.stringify([SID, null, col, null, false, { programmatic: 'pin-to-panel' }]);
    check('the open: editor.open with the chat id, no prompt, a column, no group, fullEditor false, pinned to a tab',
        openArgs.length === 1 && JSON.stringify(openArgs[0]) === pin(-1) && openArgs[0].length === 6 &&
        openArgs[0][1] === undefined && openArgs[0][3] === undefined, JSON.stringify(openArgs));
    const note = (g) => ({ label: 'notes.md', input: new TabInputText('x'), group: g || group });
    const SID2x = '33333333-3333-4333-8333-333333333333';
    const col = (setup) => { reset(); setup(); return ext._claudeColumn(); };
    const cols = [
        col(() => { tabs.push(claudeTab(SID2x, 'A')); }),
        col(() => { groupsNow = [group, group2]; tabs.push(claudeTab(SID2x, 'A'), note()); tabs2.push(claudeTab(SID2x, 'B', group2)); }),
        col(() => { tabs.push(claudeTab(SID2x, 'A'), note()); }),
        col(() => { tabs.push(note()); }),
        col(() => { groupsNow = [group, group2]; activeGroup = group2; tabs.push(claudeTab(SID2x, 'A')); tabs2.push(claudeTab(SID2x, 'B', group2)); }),
        col(() => { groupsNow = [group, group2]; activeGroup = group2; tabs.push(claudeTab(SID2x, 'A')); tabs2.push(note(group2)); }),
        col(() => { activeGroup = undefined; tabs.push(note()); }),
        // a group holding a Claude tab among others counts only while active
        col(() => { groupsNow = [group, group2]; activeGroup = group2; tabs.push(claudeTab(SID2x, 'A'), note()); tabs2.push(note(group2)); }),
        // an empty group is no group of Claude tabs alone
        col(() => { groupsNow = [group, group2]; activeGroup = group2; tabs2.push(note(group2)); })
    ];
    check('the column, as primaryEditor.open picks it: a group of Claude tabs alone, the active one first; else the active group when it holds one; else the active group',
        cols.join() === '1,2,1,-1,2,1,-1,-1,-1', cols.join());
    // editor.open refused, not timed out: primaryEditor.open once, as before
    // 0.8.1 - a tab without its header beats none
    reset();
    logged.length = 0;
    fail[OPEN] = 1;
    const fb1 = await openT();
    const fb1Calls = calls.join(), fb1Logged = logged.slice();
    reset();
    fail[OPEN] = 1;
    const fb2 = await ext._showTab(reqT);
    check('editor.open refused: primaryEditor.open with the chat id alone, the tab opens, and the log says it has no header - for the chip and Show it alike',
        fb1 === 'new' && fb1Calls === OPEN + ',' + OPEN_FULL + ',' + UNLOCK && fb1Logged.some(l => /^claude-vscode\.editor\.open failed: boom/.test(l)) &&
        fb1Logged.includes('opened with ' + OPEN_FULL + ' instead - that tab has no header') &&
        fb2 === 'new' && calls.join() === OPEN + ',' + OPEN_FULL + ',' + UNLOCK && JSON.stringify(openArgs[1]) === JSON.stringify([SID]),
        fb1 + ' ' + fb1Calls + ' / ' + fb2 + ' ' + calls.join() + ' | ' + fb1Logged.join(' | '));
    // both refused, and the groups change before the retry: the column is
    // worked out again
    reset();
    fail[OPEN] = 1;
    fail[OPEN_FULL] = 1;
    onFail = (c) => { if (c === OPEN) { groupsNow = [group, group2]; tabs2.push(claudeTab(SID2x, 'B', group2)); } };
    const rt = await openT();
    check('both refused once: tried again, the column worked out again for the retry',
        rt !== 'failed' && calls.slice(0, 3).join() === OPEN + ',' + OPEN_FULL + ',' + OPEN && openArgs[0][2] === -1 && openArgs[2][2] === 2,
        rt + ' ' + calls.join() + ' ' + JSON.stringify(openArgs));
    reset();
    claudeVer = '2.1.280';
    const oldCall = JSON.stringify(ext._openCall(SID));
    claudeVer = '';
    const noVer = JSON.stringify(ext._openCall(SID));
    claudeVer = '2.1.281';
    const atMin = ext._openCall(SID)[0];
    claudeVer = '2.1.200';
    const oldOpen = await openT();
    check('a Claude extension before 2.1.281, or of no version: primaryEditor.open with the chat id alone, and the tab opens; from 2.1.281 editor.open',
        oldCall === JSON.stringify([OPEN_FULL, SID]) && noVer === oldCall && atMin === OPEN && oldOpen === 'new' && calls.join() === OPEN_FULL + ',' + UNLOCK,
        oldCall + ' ' + noVer + ' ' + atMin + ' ' + oldOpen + ' ' + calls.join());
    check('versions: major, minor and patch as numbers, a suffix left aside; no version is none',
        ext._versionAtLeast('2.1.281', '2.1.281') && ext._versionAtLeast('2.1.290', '2.1.281') && ext._versionAtLeast('2.2.0', '2.1.281') &&
        ext._versionAtLeast('10.0.0', '2.1.281') && ext._versionAtLeast('2.1.283-beta.1', '2.1.281') && !ext._versionAtLeast('2.1.280', '2.1.281') &&
        !ext._versionAtLeast('2.0.999', '2.1.281') && !ext._versionAtLeast('', '2.1.281') && !ext._versionAtLeast(undefined, '2.1.281') && !ext._versionAtLeast('2.1', '2.1.281'));
    reset();
    const other = { label: 'notes.md', input: new TabInputText('x'), group };
    tabs.push(claudeTab(SID, 'T'), other);
    active.tab = other;
    const r2 = await ext._showTab(reqT);
    check('a stale tab brought forward, with the chat\'s title - closed and opened again',
        r2 === 'reopened' && calls.join() === OPEN + ',close:T,' + OPEN && tabs.length === 2, calls.join());
    check('and the column worked out again for the second open: the stale tab\'s group, then - that tab closed - the active group',
        openArgs.map(a => a[2]).join() === '1,-1', openArgs.map(a => a[2]).join());
    reset();
    tabs.push(claudeTab(SID, 'Some other title'), other);
    active.tab = other;
    const r3 = await ext._showTab(reqT);
    check('a title that does not match: nothing closed, and says so', r3 === 'stale' && !calls.some(c => c.startsWith('close:')) &&
        asked[0] === '"T" is already open in a tab that could not be refreshed. Close that tab and open the chat again.', calls.join());
    reset();
    // the chat of 27 characters whose tab read "Extension icon IMG_8588." and an ellipsis
    const longT = 'Extension icon IMG_8588.jpg';
    const shortT = ext._claudeTabLabel(longT);
    tabs.push(claudeTab(SID, shortT), other);
    active.tab = other;
    const r3b = await ext._showTab(Object.assign({}, reqT, { title: longT }));
    check('a stale tab whose label the Claude extension shortened - closed and opened again',
        r3b === 'reopened' && calls.join() === OPEN + ',close:' + shortT + ',' + OPEN, calls.join());
    reset();
    tabs.push(claudeTab(SID, 'Claude Code'), other);
    active.tab = other;
    const r3c = await ext._showTab(Object.assign({}, reqT, { title: '' }));
    check('a chat of no title: an untitled Claude tab is never taken for it', r3c === 'stale' && !calls.some(c => c.startsWith('close:')), calls.join());
    reset();
    const textT = { label: 'T', input: new TabInputText('x'), group };
    tabs.push(textT);
    active.tab = textT;
    revealMode = 'nothing';
    const r4 = await ext._showTab(reqT);
    check('an editor that is no Claude tab is never closed, whatever its title', r4 === 'stale' && !calls.some(c => c.startsWith('close:')), calls.join());
    reset();
    ext._timing.tabRecount = 40;
    makeLater = 10;
    const r5 = await ext._showTab(reqT);
    ext._timing.tabRecount = 0;
    check('a slow new tab, caught by the second look: nothing closed', r5 === 'new' && !calls.some(c => c.startsWith('close:')) && tabs.length === 1, calls.join());
    reset();
    // two chats whose titles share their first 24 characters: one label for
    // both, the other chat's tab in front, and the open doing nothing
    const SID2 = '22222222-2222-4222-8222-222222222222';
    const twinA = claudeTab(SID, shortT), twinB = claudeTab(SID2, shortT);
    tabs.push(twinA, twinB);
    active.tab = twinB;
    revealMode = 'nothing';
    const r6 = await ext._showTab(Object.assign({}, reqT, { title: longT }));
    check('two chats of one shortened label, the other one\'s tab in front: never closed, and says so',
        r6 === 'stale' && !calls.some(c => c.startsWith('close:')) && tabs.length === 2 && asked[0] === ext._texts.staleTab({ title: longT }), r6 + ' ' + calls.join());
    reset();
    frontTab();
    ext._timing.tabRecount = 100;
    revealMode = 'nothing';
    // the chat's new tab comes only after both looks the first one takes
    setTimeout(() => { const t = claudeTab(SID2, 'T2'); tabs.push(t); active.tab = t; }, 150);
    const r7 = await ext._showTab(reqT);
    ext._timing.tabRecount = 0;
    check('the front tab unchanged: one more look before closing it, and a new tab found then is left', r7 === 'new' && !calls.some(c => c.startsWith('close:')), r7 + ' ' + calls.join());
    reset();
    const other2 = { label: 'notes.md', input: new TabInputText('x'), group };
    tabs.push(other2);
    active.tab = other2;
    const r8 = await openT();
    check('a tab in a group holding other editors: the group left as it is', r8 === 'new' && calls.join() === OPEN, calls.join());
    reset();
    fail[UNLOCK] = 1;
    logged.length = 0;
    let r9, unlockThrew = false;
    try { r9 = await openT(); } catch (e) { unlockThrew = true; }
    check('an unlock that fails is logged, never thrown, and the tab stands', r9 === 'new' && !unlockThrew && logged.some(l => /^unlocking the group failed/.test(l)),
        r9 + ' ' + logged.join(' | '));
    // the chat's tab made in a second group, while the first stays active:
    // the command would unlock the first
    reset();
    logged.length = 0;
    groupsNow = [group, group2];
    makeIn = group2;
    tabs.push(claudeTab(SID2, 'T2'));
    active.tab = tabs[0];
    const gr1 = await openT();
    const gr1Calls = calls.join();
    reset();
    groupsNow = [group, group2];
    makeIn = group2;
    activeGroup = group2;
    tabs.push(claudeTab(SID2, 'T2'));
    const gr2 = await openT();
    check('group: the one holding the chat\'s tab, and only while it is the active group - the command acts on that one',
        gr1 === 'new' && gr1Calls === OPEN && logged.some(l => l === 'group left as it is: the chat\'s tab is not in the active group') &&
        gr2 === 'new' && calls.join() === OPENED, gr1Calls + ' / ' + calls.join() + ' | ' + logged.join(' | '));
    reset();
    logged.length = 0;
    activeGroup = undefined;
    const gr3 = await openT();
    check('group: no active group - nothing unlocked, and logged as that', gr3 === 'new' && calls.join() === OPEN &&
        logged.includes('group left as it is: no active group'), calls.join() + ' | ' + logged.join(' | '));
    reset();
    logged.length = 0;
    cfgVals['claudeCode.lockEditorGroups'] = true;
    const gr4 = await openT();
    const gr4Calls = calls.join();
    reset();
    cfgVals['claudeCode.lockEditorGroups'] = false;
    const gr5 = await openT();
    delete cfgVals['claudeCode.lockEditorGroups'];
    check('group: claudeCode.lockEditorGroups set true is the user\'s choice, and left locked; set false, or unset, it is unlocked',
        gr4 === 'new' && gr4Calls === OPEN && logged.some(l => /lockEditorGroups is set true/.test(l)) && gr5 === 'new' && calls.join() === OPENED,
        gr4Calls + ' / ' + calls.join());
    reset();
    frontTab();
    const gr6 = await ext._showTab(reqT);
    check('group: a stale tab closed and opened again - the new one\'s group of Claude tabs unlocked too',
        gr6 === 'reopened' && calls.join() === OPEN + ',close:T,' + OPENED && tabs.length === 1 && tabs[0].sid === SID, gr6 + ' ' + calls.join());
    // a new tab that turns up after the looks and before the close: the one
    // in front is not closed
    reset();
    tabs.push(claudeTab(SID, 'T'), other);
    active.tab = other;
    let looks = 0;
    peek = () => { if (++looks === 2) tabs.push(claudeTab(SID2, 'T2')); };
    const late = await ext._showTab(reqT);
    peek = null;
    check('a tab: one that came late, just before the close - taken as the chat\'s new tab, and nothing closed',
        late === 'new' && !calls.some(c => c.startsWith('close:')) && tabs.length === 3, late + ' ' + calls.join());
    // held working: a tab here is the chat's only when exactly one reads as it
    const heldHere = (x) => openT(Object.assign({ oldProcess: 'held', hostPids: [process.pid] }, x));
    reset();
    tabs.push(claudeTab(SID, 'T'), claudeTab(SID2, 'T'));
    const w1 = await heldHere({});
    const w1Calls = calls.join();
    reset();
    tabs.push(claudeTab(SID, 'Claude Code'));
    const w2 = await heldHere({ title: '' });
    check('an open held working here, with two tabs of its label, or of no title: counted as in no tab, and not opened',
        w1 === 'working' && w1Calls === 'ask' && w2 === 'working' && calls.join() === 'ask', w1 + ' ' + w1Calls + ' / ' + w2 + ' ' + calls.join());
    // on a Mac the window cannot be told: hostPids is empty
    reset();
    const w3 = await heldHere({ hostPids: [] });
    const w3Calls = calls.join();
    reset();
    tabs.push(claudeTab(SID, 'T'));
    const w4 = await heldHere({ hostPids: [] });
    check('an open held working where no window can be told (a Mac): refused as held here - unless exactly one tab reads as it',
        w3 === 'working' && w3Calls === 'ask' && asked.length === 0 && w4 === 'revealed' && calls.join() === OPENED, w3 + ' ' + w3Calls + ' / ' + w4 + ' ' + calls.join());
    // a command that never settles: the show queue moves on
    reset();
    logged.length = 0;
    ext._timing.commandTimeout = 30;
    never = OPEN;
    const nv1 = await ext._enqueue(() => openT());
    const nv2 = await ext._enqueue(() => ext._showTab(reqT));
    never = '';
    const nv3 = await ext._enqueue(async () => 'next');
    ext._timing.commandTimeout = 0;
    check('a command that never settles: timed out, logged, taken as failed and not asked again - and the queue goes on',
        nv1 === 'failed' && nv2 === undefined && nv3 === 'next' && calls.filter(c => c === OPEN).length === 2 &&
        logged.filter(l => l === OPEN + ' timed out after 30 ms').length === 2 && asked[0] === ext._texts.notOpened({ title: 'T' }) &&
        logged.some(l => /^show failed: .*timed out/.test(l)), nv1 + ' ' + nv2 + ' ' + nv3 + ' ' + calls.join() + ' | ' + logged.join(' | '));

    reset();
    const order = [];
    const slow = (n) => async () => { order.push(n + '1'); await new Promise(r => setTimeout(r, 15)); order.push(n + '2'); };
    const q1 = ext._enqueue(slow('a'));
    const q2 = ext._enqueue(slow('b'));
    await Promise.all([q1, q2]);
    check('two shows queued together never interleave', order.join() === 'a1,a2,b1,b2', order.join());

    // end to end, the run's request, fresh
    const fresh = (id, x) => fs.writeFileSync(file, JSON.stringify(Object.assign({ id, kind: 'ran', title: 'T', sessionId: SID, cwd: path.resolve('/work/projA'),
        away: true, busy: false, oldProcess: 'ended', hostPids: [], at: new Date().toISOString() }, x)));
    const settle = async () => { await tick(); await tick(); };
    // a show's tab work runs on the show queue, after any check: waited for,
    // or a tab closed and opened again leaks into the next check's calls
    // - three rounds, since a question and a check come before the queue
    const drain = async () => { for (let i = 0; i < 3; i++) { await settle(); await ext._enqueue(async () => { }); } };
    reset();
    fresh('f1');
    ext._check(context, file, false);
    await drain();
    check('a run into a quiet exact window: a tab of its own, by itself, and says on what',
        calls.join() === OPENED && logged.some(l => l === 'ran 11111111 by itself: busy false, oldProcess ended') && asked.length === 0, calls.join());
    reset();
    folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
    answer = 'Show it';
    ext._getVerdict = async () => ({ busy: false, oldProcess: 'ended', outcome: 'ok', hostPids: [] });
    fresh('f2');
    ext._check(context, file, false);
    await drain();
    folders.pop();
    answer = undefined;
    check('a multi-root window asks Show it, checks again, and shows it in a tab of its own',
        calls.join() === 'ask,' + OPENED && asked[0].endsWith('Show it?') && bars[0] === ext._texts.checking &&
        bars.length === 1 && logged.includes('Show it 11111111: busy false, oldProcess ended, outcome ok'), calls.join());
    // the chat's old view here was outside the tabs: its process ended, and a
    // new tab made, that view is dead
    aliveSet.add(process.pid);
    reset();
    fresh('f2b', { hostPids: [process.pid] });
    ext._check(context, file, false);
    await drain();
    const f2b = calls.join(), f2bAsked = asked.slice();
    reset();
    folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
    answer = 'Show it';
    ext._getVerdict = async () => ({ busy: false, oldProcess: 'ended', outcome: 'ok', hostPids: [process.pid] });
    fresh('f2c', { hostPids: [] });
    ext._check(context, file, false);
    await drain();
    folders.pop();
    answer = undefined;
    const f2c = calls.join(), f2cAsked = asked.slice();
    reset();
    frontTab();
    fresh('f2d', { hostPids: [process.pid] });
    ext._check(context, file, false);
    await drain();
    aliveSet.clear();
    check('a run\'s new tab where this window held the chat - by the request, or by Show it\'s check: the side bar\'s copy said stale, once',
        f2b === OPENED + ',ask' && f2bAsked.length === 1 && f2bAsked[0] === ext._texts.sideBarStale({ title: 'T' }) &&
        f2c === 'ask,' + OPENED + ',ask' && f2cAsked.length === 2 && f2cAsked[1] === ext._texts.sideBarStale({ title: 'T' }), f2b + ' / ' + f2c);
    check('but not when the tab here showed it, and was opened again', !asked.includes(ext._texts.sideBarStale({ title: 'T' })) &&
        calls.some(c => c.startsWith('close:')), calls.join());
    reset();
    fresh('f3', { at: new Date(Date.now() - 60000).toISOString() });
    ext._check(context, file, false);
    await settle();
    check('a verdict a minute old: it asks, it does not act', calls.join() === 'ask', calls.join());
    // a run into a chat this window shows on an idle process: Show it by
    // itself, at the PC and with another chat busy - its tab closed and
    // opened again, so the next message goes on from the run, not from the
    // tab's own memory
    aliveSet.add(process.pid);
    const liveHere = (id, x) => fresh(id, Object.assign({ away: false, busy: true, oldProcess: 'live', hostPids: [process.pid] }, x));
    // Show it's two checks, each recorded among the calls: the first judges
    // only, and the second - the tab closed - ends a process that outlived
    // the close. What each was asked is kept.
    const vAsked = [];
    const twoChecks = (v1, v2) => async (r, f, o) => {
        const x = o || {};
        vAsked.push(x);
        calls.push(x.judgeOnly ? 'check:judge' : 'check:end');
        return x.judgeOnly ? v1 : v2;
    };
    const liveV = (x) => Object.assign({ busy: true, oldProcess: 'live', outcome: 'ok', hostPids: [process.pid], judged: 'only' }, x);
    const endedV = (x) => Object.assign({ busy: true, oldProcess: 'ended', outcome: 'ok', hostPids: [process.pid] }, x);
    reset();
    logged.length = 0;
    vAsked.length = 0;
    frontTab();
    ext._getVerdict = twoChecks(liveV(), endedV());
    const sBefore = Date.now();
    liveHere('s1');
    ext._check(context, file, false);
    await drain();
    check('a run into a chat open here on an idle process: Show it by itself, at the PC and with another chat busy - judged only, its tab closed, THEN its process ended if it outlived the close, then the tab opened again, nothing asked',
        calls.join() === 'check:judge,' + OPEN + ',close:T,check:end,' + OPENED && asked.length === 0 &&
        logged.includes('ran 11111111 by itself: Show it, its idle process here (away false, busy true)') &&
        logged.includes('Show it 11111111: busy true, oldProcess live, outcome ok, judged only') &&
        logged.includes('Show it 11111111: its tab closed') && logged.includes('Show it 11111111: then oldProcess ended, outcome ok') &&
        logged.includes('Show it 11111111: opened again'), calls.join() + ' | ' + asked.join(' | ') + ' | ' + logged.join(' | '));
    check('and the second check: an 8 s grace, this window\'s host alone, only processes started before the tab was looked at',
        vAsked.length === 2 && vAsked[0].judgeOnly === true && vAsked[1].grace === 8 && vAsked[1].hostPid === process.pid &&
        Date.parse(vAsked[1].startedBefore) >= sBefore - 1000 && Date.parse(vAsked[1].startedBefore) <= Date.now() && !vAsked[1].judgeOnly,
        JSON.stringify(vAsked));
    reset();
    ext._getVerdict = twoChecks(liveV({ busy: true, oldProcess: 'held', outcome: 'held' }), endedV());
    liveHere('s1b');
    ext._check(context, file, false);
    await drain();
    check('and the first check finding it working by then: nothing closed, ended or opened, the held wording - no second check',
        calls.join() === 'check:judge,warn' && asked[0] === ext._message(fr({ oldProcess: 'held' }), true) && !calls.includes(OPEN), calls.join() + ' | ' + asked.join(' | '));
    // the chat had no panel here - its process in the side bar: the open
    // made a new tab, loaded from disk, which is never closed; the second
    // check ends the side bar's process alone, and the stale copy is said
    reset();
    logged.length = 0;
    ext._getVerdict = twoChecks(liveV(), endedV());
    const sn = await ext._showLive(reqT, file);
    const snCalls = calls.join(), snAsked = asked.slice();
    // twins: the front tab one of two of the chat's label, and the open
    // bringing nothing forward - never closed
    reset();
    tabs.push(claudeTab(SID, 'T'), claudeTab(SID2x, 'T'));
    active.tab = tabs[1];
    revealMode = 'nothing';
    ext._getVerdict = twoChecks(liveV(), endedV());
    const su1 = await ext._showLive(reqT, file);
    const su1Calls = calls.join(), su1Asked = asked.slice();
    // a remembered tab revealed by its label: the front tab changed, but its
    // label is another chat's - never closed
    reset();
    tabs.push(claudeTab(SID, 'T'), claudeTab(SID2x, 'Other chat'));
    active.tab = tabs[0];
    revealMode = 'nothing';
    peek = () => { active.tab = tabs[1]; };
    ext._getVerdict = twoChecks(liveV(), endedV());
    const su2 = await ext._showLive(reqT, file);
    peek = null;
    const su2Calls = calls.join();
    // left open, the tab keeps its process: the second check, which ends
    // one that outlives the grace, is never run under it - that was the dead
    // tab, "Claude Code process exited with code 1"
    check('Show it: a new tab - the chat had no panel here - left, the side bar\'s copy said stale; a front tab that is not surely the chat\'s - a twin, another\'s label - never closed, never ended under the tab left open, and said',
        sn === 'new' && snCalls === OPEN + ',check:end,' + UNLOCK + ',ask' && snAsked.length === 1 && snAsked[0] === ext._texts.sideBarStale(reqT) &&
        su1 === 'stale' && !su1Calls.includes('close:') && su1Calls === OPEN + ',ask' && su1Asked[0] === ext._texts.staleTab(reqT) &&
        su2 === 'stale' && !su2Calls.includes('close:') && !su2Calls.includes('check:end'),
        [sn, snCalls, su1, su1Calls, su2, su2Calls].join(' | '));
    // An extension-host restart, told from a reload as Claude Code tells
    // it: vscode.env.sessionId the same as the last activation's. Claude
    // Code reopens the tabs it lost after one - most within restartHold -
    // and such a tab looks like the new one an open makes - over a process
    // of this window started before the open, which the second check would
    // end
    check('an extension-host restart told from a reload: the window\'s session id the same as the last activation\'s; none kept - unknown; VS Code\'s placeholder, or none - untracked',
        ext._hostStartOf('s-1', 's-1') === 'restart' && ext._hostStartOf('s-1', 's-2') === 'reload' && ext._hostStartOf(undefined, 's-2') === 'unknown' &&
        ext._hostStartOf('', 's-2') === 'unknown' && ext._hostStartOf('s-1', 'someValue.sessionId') === 'untracked' && ext._hostStartOf('s-1', undefined) === 'untracked');
    {
        const hws = {};
        const hctx = { workspaceState: memo(hws) };
        stub.env = { sessionId: 'win-1' };
        const hs1 = ext._noteHostStart(hctx);
        await settle();
        const hs2 = ext._noteHostStart(hctx);
        stub.env = { sessionId: 'win-2' };
        const hs3 = ext._noteHostStart(hctx);
        await settle();
        stub.env = { sessionId: 'someValue.sessionId' };
        const hs4 = ext._noteHostStart(hctx);
        await settle();
        const hsKept = hws[ext._hostKey];
        delete stub.env;
        const hs5 = ext._noteHostStart({});
        check('each activation keeps its session id in workspaceState for the next: the first unknown, the same id a restart, a new one a reload; a placeholder kept nowhere; no workspaceState - nothing written, nothing thrown',
            hs1 === 'unknown' && hs2 === 'restart' && hs3 === 'reload' && hs4 === 'untracked' && hsKept === 'win-2' && hs5 === 'untracked' &&
            ext._hostKey === 'chatManager.lastActivationSessionId', JSON.stringify([hs1, hs2, hs3, hs4, hsKept, hs5]));
        const T = 1000000;
        ext._runClock.activatedAt = T;
        const held = (start, at) => { ext._runClock.hostStart = start; return ext._restartHeld(at); };
        check('held for restartHold (30 s) after a restart - or an unknown start, as Claude Code counts it - never after a reload or an untracked one',
            ext._timing.restartHold === 30000 && held('restart', T + 29999) && held('unknown', T + 1) && !held('restart', T + 30000) &&
            !held('reload', T + 1) && !held('untracked', T + 1) && !held(null, T + 1));
        ext._runClock.activatedAt = 0;
        ext._runClock.hostStart = null;
    }
    const restarted = async (start, at, withTab) => {
        reset();
        logged.length = 0;
        vAsked.length = 0;
        if (withTab) { tabs.push(claudeTab(SID, 'T')); active.tab = tabs[0]; }
        ext._runClock.activatedAt = at;
        ext._runClock.hostStart = start;
        ext._getVerdict = twoChecks(liveV(), endedV());
        try {
            const r = await ext._showLive(reqT, file);
            return { r, calls: calls.join(), asked: asked.slice(), v: vAsked.slice(), logged: logged.slice() };
        } finally { ext._runClock.activatedAt = 0; ext._runClock.hostStart = null; }
    };
    const sr1 = await restarted('restart', Date.now(), false);
    const sr2 = await restarted('unknown', Date.now(), false);
    const sr3 = await restarted('reload', Date.now(), false);
    const sr4 = await restarted('restart', Date.now() - 31000, false);
    const sr5 = await restarted('restart', Date.now(), true);
    check('Show it within 30 s of an extension-host restart, a new tab come up: the second check only judges - nothing ended, the tab maybe one Claude Code reopened by itself - and said so, not the side bar\'s copy as stale; an unknown start the same',
        sr1.r === 'new' && sr1.calls === OPEN + ',check:judge,' + UNLOCK + ',ask' && sr1.v.length === 1 && sr1.v[0].judgeOnly === true && !sr1.v[0].grace &&
        sr1.asked[0] === ext._texts.restartNew(reqT) && sr1.logged.some(l => /a new tab within 30 s of an extension-host restart \(restart\) - maybe one Claude Code reopened: judged only, nothing ended/.test(l)) &&
        sr2.r === 'new' && sr2.calls === sr1.calls && sr2.asked[0] === ext._texts.restartNew(reqT),
        JSON.stringify([sr1, sr2]));
    check('and after a reload, or past the 30 s, a new tab\'s second check ends the side bar\'s process as ever; the chat\'s own tab closed within the 30 s - ended as ever too',
        sr3.calls === OPEN + ',check:end,' + UNLOCK + ',ask' && sr3.asked[0] === ext._texts.sideBarStale(reqT) && sr3.v[0].grace === 8 &&
        sr4.calls === sr3.calls && sr4.asked[0] === ext._texts.sideBarStale(reqT) &&
        sr5.r === 'reopened' && sr5.calls.includes('close:T,check:end'),
        JSON.stringify([sr3, sr4, sr5]));
    check('the restart\'s word: in a new tab, nothing ended, the side bar\'s copy stale if there is one',
        /^"T" is in a new tab\. VS Code restarted its extensions a moment ago, and Claude Code reopens the tabs it lost then, so nothing of the chat was ended\. .*side bar.* stale and can be closed\.$/.test(ext._texts.restartNew({ title: 'T' })));
    // the second check finding a process still there, or failing: the tab
    // stays closed, nothing opened beside the process, and said
    reset();
    frontTab();
    ext._getVerdict = twoChecks(liveV(), { busy: true, oldProcess: 'held', outcome: 'held', hostPids: [process.pid] });
    const sh = await ext._showLive(reqT, file);
    const shCalls = calls.join(), shAsked = asked.slice();
    reset();
    frontTab();
    ext._getVerdict = twoChecks(liveV(), null);
    const sh2 = await ext._showLive(reqT, file);
    check('Show it: the second check finding the process held working, or failing - its tab closed, not opened again beside it, and said',
        sh === 'working' && shCalls === OPEN + ',close:T,check:end,ask' && shAsked[0] === ext._texts.working(reqT) &&
        sh2 === 'working' && calls.join() === OPEN + ',close:T,check:end,ask', sh + ' ' + shCalls + ' / ' + sh2 + ' ' + calls.join());
    // scripts older than the extension: the first check ended the process
    // already (no "judged":"only") - the tab shown as before, one check only
    reset();
    frontTab();
    ext._getVerdict = twoChecks(endedV(), endedV());
    liveHere('s1c');
    ext._check(context, file, false);
    await drain();
    check('Show it on scripts too old to judge only - the process ended by the first check: the tab closed and opened again as before, no second check',
        calls.join() === 'check:judge,' + OPEN + ',close:T,' + OPENED, calls.join());
    // idle in another window alone - opened there after the run, so up to
    // date: nothing ended, nothing opened here, and said
    reset();
    frontTab();
    ext._getVerdict = twoChecks(liveV({ hostPids: [999991] }), endedV());
    const sE = await ext._showIt(reqT, file);
    check('Show it, the first check finding it idle in another window only: left there - no second check, no tab closed or opened here - and said',
        sE === 'elsewhere' && calls.join() === 'check:judge,ask' && asked[0] === ext._texts.liveElsewhere(reqT), sE + ' ' + calls.join());
    reset();
    cfgVals['chatManager.autoReloadAfterRun'] = false;
    liveHere('s2');
    ext._check(context, file, false);
    await settle();
    delete cfgVals['chatManager.autoReloadAfterRun'];
    const auOff = calls.join();
    reset();
    liveHere('s3', { at: new Date(Date.now() - 60000).toISOString() });
    ext._check(context, file, false);
    await settle();
    const auOld = calls.join();
    reset();
    aliveSet.add(999991);
    liveHere('s4', { hostPids: [999991] });
    ext._check(context, file, false);
    await settle();
    aliveSet.delete(999991);
    check('but asks with autoReloadAfterRun off, on a word a minute old, and leaves another window\'s chat to that window',
        auOff === 'ask' && auOld === 'ask' && calls.join() === '', auOff + ' / ' + auOld + ' / ' + calls.join());
    aliveSet.clear();
    // away, the run's check having ended the process: a tab by itself even
    // while another chat works - a tab cuts none off; a window of more than
    // the chat's folder still asks
    reset();
    logged.length = 0;
    fresh('s5', { busy: true });
    ext._check(context, file, false);
    await drain();
    const auBusy = calls.join(), auBusyLogged = logged.slice();
    reset();
    folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
    fresh('s6', { busy: true });
    ext._check(context, file, false);
    await settle();
    folders.pop();
    check('away, its process ended by the run\'s check: a tab by itself though another chat works; a multi-root window asks',
        auBusy === OPENED && auBusyLogged.includes('ran 11111111 by itself: busy true, oldProcess ended') && calls.join() === 'ask', auBusy + ' / ' + calls.join());
    check('showsItself: Show it only for a chat live in this window; a tab only away, exact, nothing holding it; neither for new chats, held, other or kept',
        ext._showsItself({ kind: 'ran', oldProcess: 'live', hostPids: [process.pid] }, undefined, false, 0) === 'show it' &&
        ext._showsItself({ kind: 'ran', oldProcess: 'live', hostPids: [] }, undefined, true, 0) === null &&
        ext._showsItself({ kind: 'ran', oldProcess: 'none', away: true, busy: true }, undefined, true, 0) === 'tab' &&
        ext._showsItself({ kind: 'ran', oldProcess: 'none', away: false }, undefined, true, 0) === null &&
        ext._showsItself({ kind: 'ran', oldProcess: 'ended', away: true }, undefined, false, 0) === null &&
        ['held', 'other', 'kept'].every(o => ext._showsItself({ kind: 'ran', oldProcess: o, away: true, hostPids: [process.pid] }, undefined, true, 0) === null) &&
        ext._showsItself({ kind: 'new', oldProcess: 'live', hostPids: [process.pid] }, undefined, true, 0) === null &&
        ext._showsItself({ kind: 'ran', oldProcess: 'live', hostPids: [process.pid] }, false, true, 0) === null);
    // a run's offer answered Show it, its request finding the chat's process
    // left running; first: what Show it's first check answers
    const offerLive = async (id, first) => {
        reset();
        answer = 'Show it';
        ext._getVerdict = twoChecks(first, endedV());
        fresh(id, { away: false, oldProcess: 'live' });
        ext._check(context, file, false);
        await settle();
        answer = undefined;
    };
    await offerLive('f4', null);
    check('Show it with the first check failing on a process left running: the reload offer - nothing closed, no second check', calls.join() === 'ask,check:judge,warn' &&
        asked[1] === 'chatq could not end the old process of "T", so only a reload shows the run.' &&
        logged.includes('Show it 11111111: the check failed; the request\'s oldProcess live'), calls.join());
    for (const outcome of ['missing', 'bad']) {
        // what an early return prints - before 0.6.0's fix it said none, and a tab opened beside the live process
        await offerLive('f5' + outcome, { busy: null, oldProcess: 'none', outcome, hostPids: [], judged: 'only' });
        check('Show it on a first check that judged nothing (' + outcome + '), a process left running: the reload offer, never a tab beside it, no second check',
            calls.join() === 'ask,check:judge,warn' && !calls.includes(OPEN) && !calls.includes(OPEN_FULL), calls.join());
    }
    await offerLive('f6', { busy: true, oldProcess: 'held', outcome: 'running', hostPids: [], judged: 'only' });
    check('Show it while a print-mode run not chatq\'s goes into the chat: nothing closed, shown or reloaded, and says why',
        calls.join() === 'ask,check:judge,ask' && asked[1] === ext._texts.running(reqT), calls.join());
    // the check finds the chat held working, or another chat busy: the
    // reload the plan gives is asked as the offer asks it
    const heldSaid = ext._message(fr({ oldProcess: 'held' }), true);
    reset();
    answer = 'Show it';
    warnAnswer = 'Reload anyway';
    ext._getVerdict = async () => ({ busy: true, oldProcess: 'held', outcome: 'held', hostPids: [] });
    fresh('f7', { away: false });
    ext._check(context, file, false);
    await settle();
    const f7 = calls.join(), f7Asked = asked.slice();
    reset();
    answer = 'Show it';
    warnAnswer = 'Reload anyway';
    ext._getVerdict = async () => ({ busy: true, oldProcess: 'live', outcome: 'ok', hostPids: [] });
    fresh('f8', { away: false });
    ext._check(context, file, false);
    await settle();
    const f8 = calls.join(), f8Asked = asked.slice();
    reset();
    answer = 'Show it';
    ext._getVerdict = async () => ({ busy: true, oldProcess: 'kept', outcome: 'ok', hostPids: [] });
    fresh('f8b', { away: false });
    ext._check(context, file, false);
    await settle();
    answer = undefined;
    check('Show it finding the chat held working: the held wording and Reload anyway, never "could not end" and Reload',
        f7 === 'ask,warn,workbench.action.reloadWindow' && f7Asked[1] === heldSaid, f7 + ' | ' + f7Asked.join(' | '));
    check('Show it finding another chat busy, this one not held (live or kept): that other chat\'s work named, and Reload anyway - never the held wording, never "could not end"',
        f8 === 'ask,warn,workbench.action.reloadWindow' && f8Asked[1] === ext._texts.ranBusy(reqT) && f8Asked[1] !== heldSaid &&
        /another chat in this workspace is still working/.test(f8Asked[1]) && calls.join() === 'ask,warn' && asked[1] === ext._texts.ranBusy(reqT) &&
        !f8Asked.concat(asked).includes(ext._texts.couldNotEnd(reqT)), f8 + ' / ' + calls.join() + ' | ' + f8Asked.join(' | ') + ' | ' + asked.join(' | '));
    // the check failing, or judging nothing, on a request that found another
    // chat busy: that busy still stands
    const busyFallback = async (id, verdict) => {
        reset();
        answer = 'Show it';
        warnAnswer = 'Reload anyway';
        ext._getVerdict = async () => verdict;
        fresh(id, { away: false, busy: true, oldProcess: 'live' });
        ext._check(context, file, false);
        await settle();
        answer = undefined;
        return [calls.join(), asked.slice()];
    };
    const [f9, f9Asked] = await busyFallback('f9', null);
    const [f9b, f9bAsked] = await busyFallback('f9b', { busy: null, oldProcess: 'none', outcome: 'missing', hostPids: [] });
    check('Show it with the check failing, or judging nothing, on a request that found another chat busy: that chat\'s work named, and Reload anyway - never "could not end" and Reload',
        f9 === 'ask,warn,workbench.action.reloadWindow' && f9Asked[1] === ext._texts.ranBusy(reqT) &&
        f9b === 'ask,warn,workbench.action.reloadWindow' && f9bAsked[1] === ext._texts.ranBusy(reqT),
        f9 + ' | ' + f9Asked.join(' | ') + ' / ' + f9b + ' | ' + f9bAsked.join(' | '));
    check('says: a print-mode run going into the chat, either kind named, and no offer promised that only a queued one brings',
        [ext._texts.running(reqT), ext._texts.pickRunning(reqT)].every(t => t.startsWith('A print-mode run (a queued prompt, or claude -p) is going into "T"') &&
            !/offer|show it again|chatq/i.test(t) && /Open it once that run finishes\.$/.test(t)),
        ext._texts.running(reqT) + ' | ' + ext._texts.pickRunning(reqT));

    // end to end, the overlay's open request
    const ofile = path.join(dir, 'extension-check-open.json');
    const openReq = (id, sid, title) => ({ id, kind: 'open', title, sessionId: sid, cwd: path.resolve('/work/projA'), home: null, busy: null,
        oldProcess: 'none', hostPids: [], at: new Date().toISOString() });
    const open = (id, x) => fs.writeFileSync(ofile, JSON.stringify(Object.assign(openReq(id, SID, 'T'), x)));
    reset();
    logged.length = 0;
    open('o1');
    const o1 = await ext._checkOpen(context, ofile, false);
    await settle();
    check('an open: a new tab, by editor.open pinned to a tab - never primaryEditor.open, never Reload Webviews, and logged',
        o1 === 'new' && calls.join() === OPENED && tabs.length === 1 &&
        logged.includes('open 11111111: new (oldProcess none, hostPids none)'), calls.join() + ' | ' + logged.join(' | '));
    reset();
    tabs.push(claudeTab(SID, 'T'));
    open('o2', { oldProcess: 'live' });
    const o2 = await ext._checkOpen(context, ofile, false);
    await settle();
    check('an open the chat has a tab for: that tab brought forward, nothing closed, nothing said',
        o2 === 'revealed' && calls.join() === OPENED && tabs.length === 1 && asked.length === 0, calls.join());
    reset();
    aliveSet.add(process.pid);
    logged.length = 0;
    open('o2b', { oldProcess: 'live', hostPids: [process.pid] });
    const o2b = await ext._checkOpen(context, ofile, false);
    await settle();
    check('an open held idle by a process of this window, and a new tab: said once, it now runs in two places, the side bar\'s copy idle',
        o2b === 'new' && calls.join() === OPENED + ',ask' && asked.length === 1 && asked[0] === ext._texts.twoPlaces({ title: 'T', oldProcess: 'live' }) &&
        logged.includes('open 11111111: new (oldProcess live, hostPids ' + process.pid + ')'), calls.join() + ' | ' + logged.join(' | '));
    reset();
    tabs.push(claudeTab(SID, 'T'));
    open('o2c', { oldProcess: 'held', hostPids: [process.pid] });
    const o2c = await ext._checkOpen(context, ofile, false);
    await settle();
    const o2cSaid = calls.join() + ' ' + asked.length;
    reset();
    open('o2d', { oldProcess: 'none', hostPids: [process.pid] });
    const o2d = await ext._checkOpen(context, ofile, false);
    await settle();
    const o2dSaid = calls.join() + ' ' + asked.length;
    aliveSet.clear();
    reset();
    const o2e = await openT({ oldProcess: 'live', hostPids: [999991] });
    const o2eSaid = calls.join() + ' ' + asked.length;
    check('but not when a tab here showed it, when no process held it, nor when another window\'s held it',
        o2c === 'revealed' && o2cSaid === OPENED + ' 0' && o2d === 'new' && o2dSaid === OPENED + ' 0' && o2e === 'new' && o2eSaid === OPENED + ' 0',
        o2c + ' ' + o2cSaid + ' / ' + o2d + ' ' + o2dSaid + ' / ' + o2e + ' ' + o2eSaid);
    // working here outside the tabs, most likely the side bar: a tab now
    // would start a second process mid-turn
    aliveSet.add(process.pid);
    reset();
    logged.length = 0;
    open('o2w', { oldProcess: 'held', hostPids: [process.pid] });
    const o2w = await ext._checkOpen(context, ofile, false);
    await settle();
    const o2wSaid = calls.join(), o2wAsked = asked.slice();
    reset();
    tabs.push(claudeTab(SID, shortT));
    open('o2x', { oldProcess: 'held', hostPids: [process.pid], title: longT });
    const o2x = await ext._checkOpen(context, ofile, false);
    await settle();
    aliveSet.clear();
    check('an open working in a process of this window, and no tab here of its title: not opened, and says to click open again once it finishes',
        o2w === 'working' && o2wSaid === 'ask' && o2wAsked[0] === ext._texts.working({ title: 'T' }) &&
        logged.some(l => /^open 11111111: not opened - working here outside the tabs/.test(l)), o2w + ' ' + o2wSaid + ' | ' + logged.join(' | '));
    check('but a tab of its shortened title is opened - it is the chat\'s', o2x === 'revealed' && calls.join() === OPENED, o2x + ' ' + calls.join());
    reset();
    fail[OPEN] = 2;
    fail[OPEN_FULL] = 2;
    const o2f = await openT();
    check('an open the Claude extension refuses twice, both ways: said, and nothing else tried',
        o2f === 'failed' && calls.join() === [OPEN, OPEN_FULL, OPEN, OPEN_FULL, 'ask'].join() && asked[0] === ext._texts.notOpened({ title: 'T' }), calls.join());
    reset();
    claudeHere = false;
    open('o2g');
    await ext._checkOpen(context, ofile, false);
    await settle();
    claudeHere = true;
    check('an open with no Claude extension here: said, no command, no reload offer',
        calls.join() === 'ask' && asked[0] === ext._texts.noClaude({ title: 'T' }), calls.join());
    reset();
    cfgVals['chatManager.showFresh'] = false;
    open('o2h');
    await ext._checkOpen(context, ofile, false);
    await settle();
    delete cfgVals['chatManager.showFresh'];
    check('showFresh off does not stop an open: nothing was ended, so a tab still', calls.join() === OPENED, calls.join());
    reset();
    folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
    open('o3');
    await ext._checkOpen(context, ofile, false);
    await settle();
    folders.pop();
    check('an open is not for a window that is not exactly its folder', calls.length === 0 && state['chatManagerReload.lastOpenId'] !== 'o3', calls.join());
    reset();
    open('o4', { at: new Date(Date.now() - 30000).toISOString() });
    await ext._checkOpen(context, ofile, true);
    await settle();
    check('a window just opened for it shows the chat in a tab, and nothing else', calls.join() === OPENED, calls.join());
    reset();
    open('o5', { at: new Date(Date.now() - 300000).toISOString() });
    await ext._checkOpen(context, ofile, true);
    await settle();
    check('one five minutes old is left, and taken as seen', calls.length === 0 && state['chatManagerReload.lastOpenId'] === 'o5', calls.join());
    reset();
    open('o6', { oldProcess: 'none' });
    await ext._checkOpen(context, ofile, false);
    await ext._checkOpen(context, ofile, false);
    await settle();
    check('the same open twice acts once', calls.join() === OPENED, calls.join());
    // two clicks inside one poll: both chats opened, the earlier first
    reset();
    fs.writeFileSync(ofile, JSON.stringify(Object.assign(openReq('o7b', SID, 'T'), { earlier: [openReq('o7a', SID2x, 'A')] })));
    const o7 = await ext._checkOpen(context, ofile, false);
    await settle();
    const o7Calls = calls.join(), o7Args = openArgs.map(a => a[0]).join();
    calls.length = 0;
    await ext._checkOpen(context, ofile, false);
    await settle();
    check('an open file of two: both opened once, the earlier first, and what the newest came to returned',
        o7 === 'new' && o7Calls === OPENED + ',' + OPENED && o7Args === SID2x + ',' + SID && calls.length === 0 &&
        state['chatManagerReload.lastOpenId'] === 'o7b' && state['chatManager.openSeenIds'].slice(-2).join() === 'o7a,o7b', o7 + ' ' + o7Calls + ' ' + o7Args);
    // A run's Show it offered here and not taken: the chat's tab shows it
    // from before the run. The chip's open of it goes Show it's way - judged,
    // its tab closed, what outlived the close ended, opened again from disk -
    // and once that is done the next open only brings the tab forward.
    reset();
    logged.length = 0;
    aliveSet.add(process.pid);
    frontTab();
    ext._getVerdict = twoChecks(liveV(), endedV());
    liveHere('u1', { at: new Date(Date.now() - 60000).toISOString() });
    ext._check(context, file, false);
    await drain();
    const sn1Calls = calls.join(), sn1Asked = asked.slice(), sn1Kept = ext._unshown.has(SID);
    calls.length = 0;
    open('u2', { oldProcess: 'live', hostPids: [process.pid] });
    const sn2 = await ext._checkOpen(context, ofile, false);
    await drain();
    const sn2Calls = calls.join();
    calls.length = 0;
    open('u3', { oldProcess: 'live', hostPids: [process.pid] });
    const sn3 = await ext._checkOpen(context, ofile, false);
    await drain();
    const sn3Calls = calls.join();
    // a newer run's request, handled by itself, takes the place of one not taken
    reset();
    frontTab();
    liveHere('u4', { at: new Date(Date.now() - 60000).toISOString() });
    ext._check(context, file, false);
    await drain();
    liveHere('u5');
    ext._check(context, file, false);
    await drain();
    const sn5Kept = ext._unshown.has(SID);
    aliveSet.clear();
    check('Show it offered and not taken, then the chip: its tab closed, its process ended if it outlived the close, opened again - and said in the log',
        sn1Calls === 'ask' && /Show it\?$/.test(sn1Asked[0]) && sn1Kept && sn2 === 'reopened' &&
        sn2Calls === 'check:judge,' + OPEN + ',close:T,check:end,' + OPENED && !ext._unshown.has(SID) &&
        logged.includes('open 11111111: its run\'s Show it was not taken here - shown its way'),
        sn1Calls + ' ' + sn2 + ' ' + sn2Calls + ' | ' + logged.join(' | '));
    check('then the next open only brings the tab forward; and a newer run\'s request, shown by itself, takes the place of one not taken',
        sn3 === 'revealed' && sn3Calls === OPENED && !sn5Kept, sn3 + ' ' + sn3Calls);
    // its notice answered Show it only once the chip went its way: passed by -
    // shown again, the fresh tab would close and its new process end
    reset();
    logged.length = 0;
    aliveSet.add(process.pid);
    frontTab();
    ext._getVerdict = twoChecks(liveV(), endedV());
    const askBefore = stub.window.showInformationMessage;
    let answerLate = () => { };
    stub.window.showInformationMessage = (m, ...b) => {
        calls.push('ask'); asked.push(m);
        return new Promise(r => { answerLate = () => r(b.includes('Show it') ? 'Show it' : undefined); });
    };
    liveHere('u5b', { at: new Date(Date.now() - 60000).toISOString() });
    const lateOffer = ext._check(context, file, false);
    await drain();
    stub.window.showInformationMessage = askBefore;
    open('u5c', { oldProcess: 'live', hostPids: [process.pid] });
    const snLateChip = await ext._checkOpen(context, ofile, false);
    await drain();
    const snLateCalls = calls.join();
    calls.length = 0;
    answerLate();
    const snLate = await lateOffer;
    await drain();
    aliveSet.clear();
    check('its notice\'s Show it clicked once the chip went its way: passed by, nothing checked, closed or opened again',
        snLateChip === 'reopened' && snLateCalls === 'ask,check:judge,' + OPEN + ',close:T,check:end,' + OPENED && snLate === 'shown' &&
        calls.length === 0 && logged.includes('Show it 11111111: shown already, by the open chip - passed by'),
        snLateChip + ' ' + snLate + ' ' + snLateCalls + ' | ' + calls.join());
    // Show it's way only while the chip finds the old process idle here: none
    // left (its tab closed), or working (typed into since) - a plain open, the
    // offer forgotten; unjudged, or no window to tell (a Mac) - a plain open,
    // the offer kept
    const notTaken = { id: 'u0', kind: 'ran', title: 'T', sessionId: SID, cwd: path.resolve('/work/projA'), home: null, busy: false,
        away: false, oldProcess: 'live', hostPids: [process.pid], at: new Date(Date.now() - 60000).toISOString() };
    aliveSet.add(process.pid);
    const snWay = [];
    for (const [id, x] of [['u6', { oldProcess: 'none', hostPids: [] }], ['u7', { oldProcess: 'held', hostPids: [process.pid] }],
        ['u8', { oldProcess: 'kept', hostPids: [process.pid] }], ['u9', { oldProcess: 'live', hostPids: [] }]]) {
        reset();
        tabs.push(claudeTab(SID, 'T'));
        ext._unshown.set(SID, notTaken);
        open(id, x);
        const r = await ext._checkOpen(context, ofile, false);
        await drain();
        snWay.push(r + ':' + calls.join('+') + ':' + ext._unshown.has(SID));
    }
    // Show it's way, its check finding the chat working by then, or failing:
    // where Show it would ask to reload, the chip's own open - no ask
    const snAsk = [];
    for (const [id, v] of [['u10', liveV({ oldProcess: 'held', outcome: 'held' })], ['u11', null]]) {
        reset();
        tabs.push(claudeTab(SID, 'T'));
        ext._unshown.set(SID, notTaken);
        ext._getVerdict = twoChecks(v, endedV());
        open(id, { oldProcess: 'live', hostPids: [process.pid] });
        const r = await ext._checkOpen(context, ofile, false);
        await drain();
        snAsk.push(r + ':' + calls.join('+') + ':' + asked.length + ':' + ext._unshown.has(SID));
    }
    aliveSet.clear();
    ext._unshown.clear();
    check('a Show it not taken: the chip finding no process, or one working, opens as ever and forgets it; unjudged, or no window to tell, opens as ever and keeps it',
        snWay.join() === ['revealed:' + OPENED.replace(',', '+') + ':false', 'revealed:' + OPENED.replace(',', '+') + ':false',
            'revealed:' + OPENED.replace(',', '+') + ':true', 'revealed:' + OPENED.replace(',', '+') + ':true'].join(), snWay.join(' | '));
    check('a Show it not taken, the chip\'s check then finding the chat working, or failing: the chip\'s own open, never a reload asked',
        snAsk.join() === ['revealed:check:judge+' + OPENED.replace(',', '+') + ':0:false', 'revealed:check:judge+' + OPENED.replace(',', '+') + ':0:false'].join(),
        snAsk.join(' | '));

    // --- the chat picker: Chat Manager: Open chat... ---------------------------
    // a Claude home of its own, its transcripts and its registry written here
    const os = require('os');
    const pk = path.join(dir, 'ext-pick');
    fs.rmSync(pk, { recursive: true, force: true });
    const home = path.join(pk, 'home');
    const projA = path.resolve('/work/projA'), projB = path.resolve('/work/projB');
    check('pick: a folder\'s project, named as Get-ChatSlug names it', ext._chatSlug('C:\\work\\projA') === 'C--work-projA' &&
        ext._chatSlug('C:\\work\\projA\\') === 'C--work-projA' && ext._chatSlug('C:\\') === 'C--' && ext._chatSlug('/home/me/x.y') === '-home-me-x-y' &&
        ext._chatSlug('D:\\a b\\c_d') === 'D--a-b-c-d', ext._chatSlug('C:\\'));
    check('pick: noise and titles, as Test-ChatNoise and Format-ChatTitle have them',
        ext._isNoise('<command-name>') && ext._isNoise('Caveat: x') && ext._isNoise('a <SYSTEM-REMINDER> b') && ext._isNoise('[Request interrupted by user]') &&
        !ext._isNoise('fix it') && ext._formatTitle('') === '(empty)' && ext._formatTitle('  a \n b  ') === 'a b' &&
        ext._formatTitle('x'.repeat(59) + ' yz') === 'x'.repeat(59) + '...' && ext._formatTitle('y'.repeat(60)) === 'y'.repeat(60));
    const G = (n) => n.toString(16).padStart(8, '0') + '-0000-4000-8000-000000000000';
    const jl = (o) => JSON.stringify(o) + '\n';
    const user = (content, x) => jl(Object.assign({ type: 'user', isSidechain: false, message: { role: 'user', content } }, x));
    const asst = (text) => jl({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } });
    const pnow = Date.now();
    const MIN = 60000, HOUR = 3600000, DAY = 86400000;
    const mkChat = (d, id, text, ago) => {
        fs.mkdirSync(d, { recursive: true });
        const f = path.join(d, id + '.jsonl');
        fs.writeFileSync(f, text);
        const t = new Date(pnow - ago);
        fs.utimesSync(f, t, t);
        return f;
    };
    // projA's folder in lower case, as another window's Claude may have made
    // it; projB's as it is
    const dirA = path.join(home, 'projects', ext._chatSlug(projA).toLowerCase());
    const dirB = path.join(home, 'projects', ext._chatSlug(projB));
    const S = { custom: G(1), ai: G(2), prompt: G(3), side: G(4), empty: G(5), big: G(6), sidecar: G(7), long: G(8), inB: G(9), bigHead: G(10) };
    // a quarter of a megabyte and more between a big file's ends
    const filler = asst('y'.repeat(1000)).repeat(700);
    const longPrompt = 'a long first prompt that goes on and on past the sixty characters a title keeps';
    mkChat(dirA, S.custom, user('first prompt') + asst('x') + jl({ type: 'ai-title', aiTitle: 'ai name' }) +
        jl({ type: 'custom-title', customTitle: 'my name' }) + jl({ type: 'ai-title', aiTitle: 'later ai name' }), 4 * MIN);
    mkChat(dirA, S.ai, user('p') + asst('x') + jl({ type: 'ai-title', aiTitle: 'old ai' }) + jl({ type: 'ai-title', aiTitle: 'new ai' }), 3 * HOUR);
    mkChat(dirA, S.prompt, user('<command-name>/clear</command-name>') + user('Caveat: the messages below') + user('<system-reminder>x</system-reminder> hi') +
        user('[Request interrupted by user]') + user([{ type: 'tool_result', content: 'r' }]) + user('meta', { isMeta: true }) +
        user([{ type: 'text', text: '  fix the\n  bug ' }, { type: 'text', text: 'please' }]) + asst('ok') + user('a later prompt'), 2 * DAY);
    mkChat(dirA, S.side, user('agent work', { isSidechain: true }) + asst('x'), 5 * MIN);
    mkChat(dirA, S.empty, jl({ type: 'ai-title', aiTitle: 'ghost' }) + jl({ type: 'mode', mode: 'x' }), 6 * MIN);
    mkChat(dirA, S.big, user('head prompt') + jl({ type: 'ai-title', aiTitle: 'head ai' }) + filler + jl({ type: 'ai-title', aiTitle: 'tail ai' }) + asst('z'), 7 * MIN);
    mkChat(dirA, S.sidecar, user('a prompt') + jl({ type: 'ai-title', aiTitle: 'ai one' }), 8 * MIN);
    fs.mkdirSync(path.join(dirA, S.sidecar), { recursive: true });
    fs.writeFileSync(path.join(dirA, S.sidecar, 'custom-title.json'), '\uFEFF{"customTitle":"from the side"}');
    mkChat(dirA, S.bigHead, user('only in the head') + filler, 9 * MIN);
    mkChat(dirA, S.long, user(longPrompt), 10 * MIN);
    mkChat(dirB, S.inB, user('in B'), 1 * MIN);
    // not chats: another name, another type, and one a folder deeper
    mkChat(dirA, 'notes', user('n'), 0);
    fs.writeFileSync(path.join(dirA, G(11) + '.json'), user('j'));
    mkChat(path.join(dirA, 'sub'), G(12), user('deep'), 0);
    const reg = path.join(home, 'sessions');
    fs.mkdirSync(reg, { recursive: true });
    // a live entry started just now: one from before the machine started is
    // dropped as a crash's leftover, and a CI runner booted only minutes
    // before the tests - so no fixed age, not even an hour, is safe
    const regPut = (pid, x) => fs.writeFileSync(path.join(reg, pid + '.json'),
        JSON.stringify(Object.assign({ pid, cwd: projA, startedAt: pnow, procStart: '1', status: 'idle', entrypoint: 'claude-vscode' }, x)));
    regPut(999101, { sessionId: S.custom });
    regPut(999102, { sessionId: S.ai, entrypoint: 'cli' });
    regPut(999112, { sessionId: S.ai });
    regPut(999103, { sessionId: S.prompt, status: 'busy' });
    regPut(999104, { sessionId: S.sidecar });
    regPut(999105, { sessionId: S.long, startedAt: pnow + HOUR });
    regPut(999106, { sessionId: S.big, status: 'waiting', startedAt: pnow - (os.uptime() + 3600) * 1000 });
    regPut(999107, { sessionId: S.inB, status: 'waiting' });
    fs.writeFileSync(path.join(reg, '999108.json'), '{not json');
    fs.writeFileSync(path.join(reg, 'x.json'), JSON.stringify({ pid: 999101, sessionId: S.bigHead, entrypoint: 'cli' }));
    // every pid but 999104's is running
    for (const p of [999101, 999102, 999112, 999103, 999105, 999106, 999107]) aliveSet.add(p);
    folders.push({ uri: { fsPath: projB } });
    const listed = await ext._listChats(home, folders);
    const newest = [S.inB, S.custom, S.side, S.empty, S.big, S.sidecar, S.bigHead, S.long, S.ai, S.prompt];
    check('pick: every folder\'s <GUID>.jsonl, newest first - a project folder of another case found, nothing else and nothing deeper listed',
        listed.map(c => c.sid).join() === newest.join() && listed[0].folder === 'projB' && listed[1].folder === 'projA',
        listed.map(c => c.sid.slice(0, 8)).join());
    ext._titleCache.clear();
    const realReadChat = ext._readChat;
    let reads = 0;
    ext._readChat = (c) => { reads++; return realReadChat(c); };
    const desc = {};
    for (const c of listed) desc[c.sid] = await ext._describeChat(c);
    const tl = (sid) => (desc[sid] || {}).title;
    check('pick: a rename first, the newest; then the newest ai-title; then the first prompt typed, past the noise',
        tl(S.custom) === 'my name' && tl(S.ai) === 'new ai' && tl(S.prompt) === 'fix the bug please' && tl(S.inB) === 'in B', JSON.stringify(desc));
    check('pick: the sidecar\'s rename over an ai-title; a big file\'s ai-title from its tail, its prompt from its head',
        tl(S.sidecar) === 'from the side' && tl(S.big) === 'tail ai' && tl(S.bigHead) === 'only in the head', JSON.stringify(desc));
    check('pick: a side transcript, and a small one holding no message, are left out',
        desc[S.side].skip === 'side' && desc[S.empty].skip === 'empty' && tl(S.long) === longPrompt, JSON.stringify(desc));
    // a big file's rename, or Claude's title, written only near its start:
    // the head looked in where the tail has none of that kind, as the
    // index's Describe does. Files of their own, outside the folders listed
    const headDir = path.join(home, 'heads');
    const headChat = async (n, text) => {
        const f = mkChat(headDir, G(n), text, 0);
        return (await realReadChat({ file: f, dir: headDir, sid: G(n), size: fs.statSync(f).size })) || {};
    };
    const hRename = await headChat(41, user('p') + jl({ type: 'custom-title', customTitle: 'renamed early' }) + filler + jl({ type: 'ai-title', aiTitle: 'tail ai' }) + asst('z'));
    const hAi = await headChat(42, user('p') + jl({ type: 'ai-title', aiTitle: 'early ai' }) + filler + asst('z'));
    const hTail = await headChat(43, user('p') + jl({ type: 'custom-title', customTitle: 'old name' }) + filler + jl({ type: 'custom-title', customTitle: 'new name' }) + asst('z'));
    fs.mkdirSync(path.join(headDir, G(44)), { recursive: true });
    fs.writeFileSync(path.join(headDir, G(44), 'custom-title.json'), '{"customTitle":"side name"}');
    const hSide = await headChat(44, user('p') + jl({ type: 'ai-title', aiTitle: 'early ai' }) + filler + asst('z'));
    check('pick: a big file\'s rename, or Claude\'s title, written only near its start - read from its head where its tail has none; the tail\'s still first, and a sidecar\'s rename over the head\'s ai-title',
        hRename.title === 'renamed early' && hAi.title === 'early ai' && hTail.title === 'new name' && hSide.title === 'side name',
        [hRename.title, hAi.title, hTail.title, hSide.title].join(' | '));
    const readsFirst = reads;
    for (const c of listed) await ext._describeChat(c);
    const readsAgain = reads;
    const tLong = new Date(pnow - 10 * MIN + 1000);
    fs.appendFileSync(path.join(dirA, S.long + '.jsonl'), jl({ type: 'ai-title', aiTitle: 'now titled' }));
    fs.utimesSync(path.join(dirA, S.long + '.jsonl'), tLong, tLong);
    const relisted = (await ext._listChats(home, folders)).find(c => c.sid === S.long);
    const retitled = await ext._describeChat(relisted);
    check('pick: titles kept by path, size and write time - read again only once the file changes',
        readsFirst === listed.length && readsAgain === readsFirst && reads === readsFirst + 1 && retitled.title === 'now titled', readsFirst + ' ' + readsAgain + ' ' + reads);
    const reg1 = ext._readRegistry(home, Date.now());
    const st = (sid) => ext._chatState(reg1.get(sid));
    check('pick: what runs each chat - a panel idle is open, busy or waiting is working, a terminal wins, and nothing is closed',
        st(S.custom) === 'open' && st(S.prompt) === 'working' && st(S.inB) === 'working' && st(S.ai) === 'terminal' && st(S.bigHead) === 'closed',
        [S.custom, S.prompt, S.inB, S.ai, S.bigHead].map(st).join());
    check('pick: an entry whose pid is gone, whose startedAt is ahead, or from before the machine started, runs nothing',
        st(S.sidecar) === 'closed' && st(S.long) === 'closed' && st(S.big) === 'closed' && !reg1.has('999108'), [S.sidecar, S.long, S.big].map(st).join());
    check('pick: a run nobody types in - a kind set and not interactive, as chatq\'s claude -p - is running, never a terminal; an interactive one still is',
        ext._chatState([{ kind: 'print', entrypoint: 'sdk-cli', status: 'busy' }]) === 'running' &&
        ext._chatState([{ kind: 'print', entrypoint: 'sdk-cli' }, { entrypoint: 'claude-vscode', status: 'idle' }]) === 'running' &&
        ext._chatState([{ kind: 'interactive', entrypoint: 'cli' }]) === 'terminal' &&
        ext._chatState([{ kind: 'interactive', entrypoint: 'claude-vscode', status: 'busy' }]) === 'working',
        ext._chatState([{ kind: 'print', entrypoint: 'sdk-cli', status: 'busy' }]));
    check('pick: an entry naming no entrypoint is no terminal - as the script\'s where has it, only another entrypoint is',
        ext._chatState([{ status: 'idle' }]) === 'open' && ext._chatState([{ entrypoint: '', status: 'busy' }]) === 'working' &&
        ext._chatState([{ status: 'idle' }, { entrypoint: 'cli' }]) === 'terminal',
        ext._chatState([{ status: 'idle' }]) + ' ' + ext._chatState([{ entrypoint: '', status: 'busy' }]));
    check('pick: only a whole codicon pattern is escaped, as VS Code\'s escapeIcons does - any other "$(" left as typed, and one escaped already kept',
        ext._noIcons('x $(a b)') === 'x $(a b)' && ext._noIcons('echo $(git rev-parse HEAD)') === 'echo $(git rev-parse HEAD)' &&
        ext._noIcons('$(terminal)') === '\\$(terminal)' && ext._noIcons('$(sync~spin) and $(x') === '\\$(sync~spin) and $(x' &&
        ext._noIcons('\\$(terminal)') === '\\$(terminal)',
        [ext._noIcons('x $(a b)'), ext._noIcons('echo $(git rev-parse HEAD)'), ext._noIcons('$(terminal)')].join(' | '));
    const escItem = ext._pickItem({ sid: G(1), mtimeMs: pnow, folder: 'f$(x)' }, { title: 'use $(terminal) here' }, 'open', true, pnow);
    check('pick: a "$(" in a title, or a folder\'s name, is kept as typed - never drawn as a codicon',
        escItem.label === '$(window) use \\$(terminal) here' && escItem.detail === 'f\\$(x)', escItem.label + ' ' + escItem.detail);
    check('pick: the age, as Get-ChatAge gives it', ext._ageText(30000) === 'now' && ext._ageText(4 * MIN) === '4m' && ext._ageText(3 * HOUR) === '3h' &&
        ext._ageText(2 * DAY) === '2d' && ext._ageText(40 * DAY) === '1mo');
    // a chat only opened since its last turn: written now, by records with
    // no time - its age is the turn's, read with its title
    {
        const opened = path.join(__dirname, '.sandbox', 'ext-pick-opened', G(9) + '.jsonl');
        fs.mkdirSync(path.dirname(opened), { recursive: true });
        const turnAt = pnow - 3 * HOUR;
        fs.writeFileSync(opened, '{"type":"user","message":{"role":"user","content":"old ask"},"timestamp":"' + new Date(turnAt - 1000).toISOString() + '"}\n' +
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"timestamp":"' + new Date(turnAt).toISOString() + '"}\n' +
            '{"type":"last-prompt","lastPrompt":"old ask"}\n{"type":"cost-state"}\n');
        const st = fs.statSync(opened);
        const oc = { file: opened, dir: path.dirname(opened), sid: G(9), size: st.size, mtimeMs: st.mtimeMs, folder: 'f' };
        const od = await ext._readChat(oc);
        const oi = ext._pickItem(oc, od, 'closed', false, st.mtimeMs);
        const unread = ext._pickItem(oc, undefined, 'closed', false, st.mtimeMs);
        check('pick: a chat only opened since is as old as its last turn, not its write time; until read, by its write time',
            od && Math.abs(od.activeMs - turnAt) < 2 && oi.description === '3h' && unread.description === 'now', [od && od.activeMs, turnAt, oi.description, unread.description].join(' | '));
        check('pick: the time is the shared reader\'s - the last timestamp, never later than the cap, NaN for none',
            safe.lastStamp('{"timestamp":"2020-01-01T00:00:00Z"}\n{"timestamp":"2020-01-02T00:00:00Z"}\n{"type":"mode"}') === Date.parse('2020-01-02T00:00:00Z') &&
            safe.lastStamp('{"timestamp":"2099-01-01T00:00:00Z"}', 5) === 5 && Number.isNaN(safe.lastStamp('{"type":"mode"}')));
    }
    // the QuickPick, each assignment of its items recorded
    const qps = [];
    // called as each list is put in, for what a test wants to know just then
    let atSet = () => undefined;
    stub.window.createQuickPick = () => {
        let items = [];
        const qp = {
            activeItems: [], selectedItems: [], busy: false, sets: [], disposed: false,
            show() { }, hide() { if (this.hideCb) this.hideCb(); }, dispose() { this.disposed = true; },
            onDidAccept(cb) { this.acceptCb = cb; }, onDidHide(cb) { this.hideCb = cb; }
        };
        Object.defineProperty(qp, 'items', { get: () => items, set: (v) => { items = v; qp.sets.push({ at: Date.now(), labels: v.map(i => i.label), mark: atSet() }); } });
        qps.push(qp);
        return qp;
    };
    // up to 10 s: a slow machine only waits longer, it never fails for it
    const waitFor = async (fn) => {
        for (const end = Date.now() + 10000; !fn() && Date.now() < end;) await new Promise(r => setTimeout(r, 4));
        return fn();
    };
    const accept = (qp, sid) => { qp.selectedItems = [qp.items.find(i => i.chat.sid === sid)]; qp.acceptCb(); };
    reset();
    logged.length = 0;
    process.env.CLAUDE_CONFIG_DIR = home;
    warnAnswer = 'Cancel';
    const p1 = ext._openChat();
    const qp1 = qps[qps.length - 1];
    await waitFor(() => qp1.sets.length && !qp1.busy);
    const shownItems = qp1.items;
    const label = (sid) => (shownItems.find(i => i.chat.sid === sid) || {}).label;
    const descr = (sid) => (shownItems.find(i => i.chat.sid === sid) || {}).description;
    check('pick: the chats listed, newest first, each by its title, the side and empty ones left out',
        shownItems.map(i => i.chat.sid).join() === [S.inB, S.custom, S.big, S.sidecar, S.bigHead, S.long, S.ai, S.prompt].join() &&
        label(S.sidecar) === 'from the side' && label(S.long) === 'now titled', shownItems.map(i => i.label).join(' | '));
    check('pick: a codicon for what runs it - $(terminal), $(sync~spin), $(window), none when closed',
        label(S.ai) === '$(terminal) new ai' && label(S.prompt) === '$(sync~spin) fix the bug please' && label(S.inB) === '$(sync~spin) in B' &&
        label(S.custom) === '$(window) my name' && label(S.big) === 'tail ai', shownItems.map(i => i.label).join(' | '));
    check('pick: the age and what runs it beside it, nothing for closed; and the folder, in a multi-root window',
        descr(S.custom) === '4m \u00b7 open' && descr(S.ai) === '3h \u00b7 in a terminal' && descr(S.prompt) === '2d \u00b7 working' && descr(S.big) === '7m' &&
        (shownItems.find(i => i.chat.sid === S.inB) || {}).detail === 'projB' && (shownItems.find(i => i.chat.sid === S.custom) || {}).detail === 'projA',
        shownItems.map(i => i.description + ' ' + i.detail).join(' | '));
    accept(qp1, S.custom);
    const pick1 = await p1;
    check('pick: open idle elsewhere in VS Code, no tab here - asked, with Open here too and Cancel; Cancel opens nothing',
        pick1 === 'cancelled' && calls.join() === 'warn' && asked[0] === ext._texts.pickElsewhere({ title: 'my name' }) && qp1.disposed &&
        logged.includes('pick 00000001: open -> cancelled'), pick1 + ' ' + calls.join() + ' | ' + logged.join(' | '));
    const chatOf = (sid) => listed.find(c => c.sid === sid);
    Object.assign(titles, { [S.custom]: 'my name', [S.prompt]: 'fix the bug please', [S.sidecar]: 'from the side' });
    reset();
    warnAnswer = 'Open here too';
    const a1 = await ext._acceptChat(chatOf(S.custom));
    check('pick: Open here too - opened, through the open chip\'s core', a1 === 'new' && calls.join() === 'warn,' + OPENED &&
        logged.includes('open 00000001: new (picked, open)'), a1 + ' ' + calls.join());
    reset();
    tabs.push(claudeTab(S.custom, 'my name'));
    const a2 = await ext._acceptChat(chatOf(S.custom));
    check('pick: open, and its one tab here - brought forward, nothing asked', a2 === 'revealed' && calls.join() === OPENED && asked.length === 0, a2 + ' ' + calls.join());
    reset();
    logged.length = 0;
    const a3 = await ext._acceptChat(chatOf(S.ai));
    check('pick: in a terminal - refused, and said', a3 === 'refused' && calls.join() === 'ask' && asked[0] === ext._texts.pickTerminal({ title: 'new ai' }) &&
        logged.includes('pick 00000002: terminal -> refused'), a3 + ' ' + calls.join());
    reset();
    const a4 = await ext._acceptChat(chatOf(S.prompt));
    const a4Calls = calls.join(), a4Asked = asked[0];
    reset();
    tabs.push(claudeTab(S.prompt, 'fix the bug please'), claudeTab(SID2, 'fix the bug please'));
    const a5 = await ext._acceptChat(chatOf(S.prompt));
    const a5Calls = calls.join();
    reset();
    tabs.push(claudeTab(S.prompt, 'fix the bug please'));
    const a6 = await ext._acceptChat(chatOf(S.prompt));
    check('pick: working - refused and told to open it once it finishes, twin tabs too; its one tab here only brought forward',
        a4 === 'refused' && a4Calls === 'ask' && a4Asked === ext._texts.pickWorking({ title: 'fix the bug please' }) && /once it finishes/.test(a4Asked) &&
        a5 === 'refused' && a5Calls === 'ask' && a6 === 'revealed' && calls.join() === OPENED, a4 + ' ' + a5 + ' ' + a6 + ' ' + calls.join());
    reset();
    logged.length = 0;
    const a7 = await ext._acceptChat(chatOf(S.sidecar));
    check('pick: closed - opened from disk, and logged', a7 === 'new' && calls.join() === OPENED && asked.length === 0 &&
        logged.includes('pick 00000007: closed -> new') && logged.includes('open 00000007: new (picked, closed)'), a7 + ' ' + calls.join() + ' | ' + logged.join(' | '));
    // titles slow to come: the chats listed at once by their ids, filled in
    // later, the item under the cursor kept
    reset();
    ext._titleCache.clear();
    ext._timing.pickBudget = 0;
    ext._readChat = async (c) => { await new Promise(r => setTimeout(r, 150)); return realReadChat(c); };
    const p2 = ext._openChat();
    const qp2 = qps[qps.length - 1];
    await waitFor(() => qp2.sets.length);
    const firstLabels = qp2.sets[0].labels.slice();
    const cursor = qp2.items.find(i => i.chat.sid === S.sidecar);
    qp2.activeItems = [cursor];
    await waitFor(() => !qp2.busy);
    const lastLabels = qp2.items.map(i => i.label);
    const kept = qp2.activeItems[0];
    qp2.hide();
    const p2r = await p2;
    check('pick: titles slow to read - listed at once by id, filled in as they come, the item under the cursor kept',
        firstLabels.includes(S.sidecar) && firstLabels.includes(S.side) && !lastLabels.includes(S.sidecar) && !lastLabels.includes(S.side) &&
        lastLabels.includes('from the side') && kept !== cursor && kept.chat.sid === S.sidecar && p2r === 'none',
        firstLabels.join(' | ') + ' / ' + lastLabels.join(' | '));
    // the cap, and listed before every title is read: 205 chats, none read
    // before, each read taking a few ms more than it would. Timers fire in
    // the order they fall due, so a budget of 20 ms is up well before 200
    // reads 16 at a time, 5 ms each, can be done - however slow the machine
    // - and no wall-clock limit is asserted.
    const home2 = path.join(pk, 'home2');
    const dir2 = path.join(home2, 'projects', ext._chatSlug(projA));
    for (let i = 0; i < 205; i++) mkChat(dir2, G(0x1000 + i), user('chat number ' + i) + asst('x'), i * 1000);
    folders.pop();
    const capped = await ext._listChats(home2, folders);
    process.env.CLAUDE_CONFIG_DIR = home2;
    ext._titleCache.clear();
    ext._timing.pickBudget = 20;
    let readsDone = 0;
    ext._readChat = async (c) => { await new Promise(r => setTimeout(r, 5)); const d = await realReadChat(c); readsDone++; return d; };
    atSet = () => readsDone;
    const pickT0 = Date.now();
    const p3 = ext._openChat();
    const qp3 = qps[qps.length - 1];
    await waitFor(() => qp3.sets.length);
    const first3 = qp3.sets[0];
    await waitFor(() => !qp3.busy);
    const all3 = qp3.items;
    qp3.hide();
    await p3;
    atSet = () => undefined;
    ext._readChat = realReadChat;
    ext._timing.pickBudget = 250;
    check('pick: the newest 200 only, listed before every title was read - the rest by id - and then every title read',
        capped.length === 200 && capped[0].sid === G(0x1000) && capped[199].sid === G(0x1000 + 199) &&
        first3.labels.length === 200 && first3.mark < 200 && first3.labels.some(l => ext._isGuid(l)) && readsDone === 200 && all3.length === 200 &&
        all3[0].label === 'chat number 0' && all3.every(i => /^chat number \d+$/.test(i.label)) && !all3[0].detail,
        capped.length + ' first list after ' + (first3.at - pickT0) + ' ms, ' + first3.mark + ' read then, ' + readsDone + ' in all, ' + all3.length + ' listed');
    process.env.CLAUDE_CONFIG_DIR = noHome;

    // --- a tab label another chat shares ---------------------------------------
    // A Claude tab carries no session id, only its label: a lone tab of the
    // chat's label may be another chat's, of the same title or of the same
    // first 24 characters, and this chat have no tab here at all.
    const home3 = path.join(pk, 'home3');
    const dir3 = path.join(home3, 'projects', ext._chatSlug(projA));
    const L = { a: G(0x2001), b: G(0x2002), long1: G(0x2003), long2: G(0x2004), solo: G(0x2005) };
    mkChat(dir3, L.a, user('T') + asst('x'), 1 * MIN);
    mkChat(dir3, L.b, user('something else') + asst('x') + jl({ type: 'custom-title', customTitle: 'T' }), 2 * MIN);
    mkChat(dir3, L.long1, user(longT) + asst('x'), 3 * MIN);
    mkChat(dir3, L.long2, user('Extension icon IMG_8588.png') + asst('x'), 4 * MIN);
    mkChat(dir3, L.solo, user('only me') + asst('x'), 5 * MIN);
    Object.assign(titles, { [L.a]: 'T', [L.solo]: 'only me' });
    ext._titleCache.clear();
    // a window on projB alone, for a chat of projB: projA's chats are no
    // tab of it
    folders.splice(0, folders.length, { uri: { fsPath: projB } });
    const lsB = await ext._labelShared('T', projB, L.a, home3);
    folders.splice(0, folders.length, { uri: { fsPath: projA } });
    check('label: shared where another chat of the folder has the same title, or the same first 24 characters - never with itself, nor for no title, nor in a folder neither the window\'s nor the chat\'s',
        await ext._labelShared('T', projA, L.a, home3) && await ext._labelShared(longT, projA, L.long1, home3) &&
        !(await ext._labelShared('only me', projA, L.solo, home3)) && !(await ext._labelShared('', projA, L.a, home3)) &&
        !lsB && !(await ext._labelShared('T', projA, L.a)));
    // twins in two folders of a multi-root window: a tab may come from any
    const dir3b = path.join(home3, 'projects', ext._chatSlug(projB));
    const L2 = { a: G(0x2101), b: G(0x2102) };
    mkChat(dir3b, L2.b, user('Twins across the folders') + asst('x'), 6 * MIN);
    mkChat(dir3, L2.a, user('Twins across the folders') + asst('x'), 7 * MIN);
    const lsMulti1 = await ext._labelShared('Twins across the folders', projA, L2.a, home3);
    folders.push({ uri: { fsPath: projB } });
    const lsMulti2 = await ext._labelShared('Twins across the folders', projA, L2.a, home3);
    const lsMulti3 = await ext._labelShared('T', projB, L.a, home3);
    folders.pop();
    const lsOwn = await ext._labelShared('Twins across the folders', projB, L2.b, home3);
    check('label: every folder of the window looked in, and the chat\'s own beside them - a twin in another folder of a multi-root window is shared',
        !lsMulti1 && lsMulti2 && lsMulti3 && lsOwn, lsMulti1 + ' ' + lsMulti2 + ' ' + lsMulti3 + ' ' + lsOwn);
    fs.unlinkSync(path.join(dir3b, L2.b + '.jsonl'));
    fs.unlinkSync(path.join(dir3, L2.a + '.jsonl'));
    // the cost: each folder's newest 200 only, and a time budget
    ext._titleCache.clear();
    let labelReads = 0;
    ext._readChat = (c) => { labelReads++; return realReadChat(c); };
    const lsCap = await ext._labelShared('no chat has this title', projA, G(0x9999), home2);
    check('label: each folder\'s newest 200 transcripts read, what the picker lists - never all 205', !lsCap && labelReads === 200, lsCap + ' ' + labelReads);
    ext._titleCache.clear();
    ext._readChat = async (c) => { await new Promise(r => setTimeout(r, 200)); return realReadChat(c); };
    ext._timing.labelBudget = 30;
    logged.length = 0;
    const lsLate = await ext._labelShared('only me', projA, L.solo, home3);
    const lateLog = logged.slice();
    ext._timing.labelBudget = 0;
    const lsNoLimit = await ext._labelShared('only me', projA, L.solo, home3);
    ext._readChat = realReadChat;
    check('label: not all read within labelBudget - shared, the safe side, and logged; 0 is no limit',
        lsLate === true && lateLog.some(l => l === 'label ' + L.solo.slice(0, 8) + ': its folders\' chats not all read in 30 ms - taken as shared') && lsNoLimit === false,
        lsLate + ' ' + lsNoLimit + ' | ' + lateLog.join(' | '));
    ext._titleCache.clear();
    // showTab: the request names its Claude home
    reset();
    tabs.push(claudeTab(L.a, 'T'), other);
    active.tab = other;
    const ls1 = await ext._showTab({ kind: 'ran', sessionId: L.a, title: 'T', cwd: projA, home: home3 });
    const ls1Calls = calls.join(), ls1Asked = asked.slice();
    reset();
    tabs.push(claudeTab(L.solo, 'only me'), other);
    active.tab = other;
    const ls2 = await ext._showTab({ kind: 'ran', sessionId: L.solo, title: 'only me', cwd: projA, home: home3 });
    check('label shared: a stale tab of that label is never closed - stale, and says so; a label of its own is closed and opened again',
        ls1 === 'stale' && !ls1Calls.includes('close:') && ls1Asked[0] === ext._texts.staleTab({ title: 'T' }) &&
        ls2 === 'reopened' && calls.includes('close:only me'), ls1 + ' ' + ls1Calls + ' / ' + ls2 + ' ' + calls.join());
    // openTab: this window's Claude home, the request naming none
    process.env.CLAUDE_CONFIG_DIR = home3;
    const heldOpen = (sid, title) => ext._openTab({ kind: 'open', sessionId: sid, title, cwd: projA, home: null, oldProcess: 'held', hostPids: [process.pid] });
    reset();
    tabs.push(claudeTab(L.a, 'T'));
    const lw1 = await heldOpen(L.a, 'T');
    const lw1Calls = calls.join(), lw1Asked = asked.slice();
    reset();
    tabs.push(claudeTab(L.solo, 'only me'));
    const lw2 = await heldOpen(L.solo, 'only me');
    check('label shared: an open held working here, its label\'s one tab maybe another chat\'s - counted as in no tab, and not opened; a label of its own is',
        lw1 === 'working' && lw1Calls === 'ask' && lw1Asked[0] === ext._texts.working({ title: 'T' }) && lw2 === 'revealed' && calls.join() === OPENED,
        lw1 + ' ' + lw1Calls + ' / ' + lw2 + ' ' + calls.join());
    // the picker's accept: what runs each chat from home3's own registry
    const reg3 = path.join(home3, 'sessions');
    // a registry folder emptied, then an entry written for each [pid, fields],
    // each pid alive; entry(pid): the fields every entry starts from
    const regFill = (d, entry) => (entries) => {
        fs.rmSync(d, { recursive: true, force: true });
        fs.mkdirSync(d, { recursive: true });
        for (const [pid, x] of entries) {
            aliveSet.add(pid);
            fs.writeFileSync(path.join(d, pid + '.json'), JSON.stringify(Object.assign(entry(pid), x)));
        }
    };
    // started just now, as regPut's - a runner may have booted minutes ago
    const regSet = regFill(reg3, (pid) => ({ pid, cwd: projA, startedAt: pnow, status: 'idle', entrypoint: 'claude-vscode' }));
    const chats3 = await ext._listChats(home3, folders);
    const c3 = (sid) => chats3.find(c => c.sid === sid);
    reset();
    regSet([[999201, { sessionId: L.a, status: 'busy' }]]);
    tabs.push(claudeTab(L.a, 'T'));
    const la1 = await ext._acceptChat(c3(L.a));
    const la1Calls = calls.join(), la1Asked = asked.slice();
    reset();
    regSet([[999201, { sessionId: L.a }]]);
    tabs.push(claudeTab(L.a, 'T'));
    warnAnswer = 'Cancel';
    const la2 = await ext._acceptChat(c3(L.a));
    check('label shared: a pick working, or open, whose label\'s one tab may be another chat\'s - as with no tab here: refused, or asked',
        la1 === 'refused' && la1Calls === 'ask' && la1Asked[0] === ext._texts.pickWorking({ title: 'T' }) &&
        la2 === 'cancelled' && calls.join() === 'warn' && asked[0] === ext._texts.pickElsewhere({ title: 'T' }), la1 + ' ' + la1Calls + ' / ' + la2 + ' ' + calls.join());
    // the question sits a while, and the chat begins to work meanwhile
    reset();
    regSet([[999202, { sessionId: L.solo }]]);
    warnAnswer = 'Open here too';
    const plainWarn = stub.window.showWarningMessage;
    stub.window.showWarningMessage = async (m, ...b) => { const r = await plainWarn(m, ...b); regSet([[999202, { sessionId: L.solo, status: 'busy' }]]); return r; };
    const lq1 = await ext._acceptChat(c3(L.solo));
    stub.window.showWarningMessage = plainWarn;
    const lq1Calls = calls.join(), lq1Asked = asked.slice();
    // closed when picked, and a terminal takes it while the open waits in
    // the queue behind another show
    reset();
    regSet([]);
    let release;
    const blocker = ext._enqueue(() => new Promise(r => { release = r; }));
    const pq = ext._acceptChat(c3(L.solo));
    await tick();
    regSet([[999203, { sessionId: L.solo, entrypoint: 'cli' }]]);
    release();
    await blocker;
    const lq2 = await pq;
    check('pick: read again after the question, and again right before the open - working, or in a terminal, by then: refused as it would have been at once',
        lq1 === 'refused' && lq1Calls === 'warn,ask' && lq1Asked[1] === ext._texts.pickWorking({ title: 'only me' }) &&
        lq2 === 'refused' && calls.join() === 'ask' && asked[0] === ext._texts.pickTerminal({ title: 'only me' }) && !calls.includes(OPEN),
        lq1 + ' ' + lq1Calls + ' / ' + lq2 + ' ' + calls.join());
    reset();
    logged.length = 0;
    regSet([[999204, { sessionId: L.solo, kind: 'print', entrypoint: 'sdk-cli', status: 'busy' }]]);
    const lr1 = await ext._acceptChat(c3(L.solo));
    check('pick: a queued prompt going into it (a print-mode run) - refused as running, not as a terminal',
        lr1 === 'refused' && calls.join() === 'ask' && asked[0] === ext._texts.pickRunning({ title: 'only me' }) &&
        logged.includes('pick ' + L.solo.slice(0, 8) + ': running -> refused'), lr1 + ' ' + calls.join() + ' | ' + asked.join(' | '));

    // --- this window's Claude tabs, for the overlay (writeTabs) ---------------
    // the tabs that name one chat each, from home3's chats of projA: 'T' is
    // two chats' (L.a, L.b), longT's label two's (L.long1, L.long2), 'only
    // me' one's, and 'Lonely tab' one's but on two tabs
    process.env.CLAUDE_CONFIG_DIR = home3;
    ext._titleCache.clear();
    const lonely = G(0x2006);
    mkChat(dir3, lonely, user('Lonely tab') + asst('x'), 8 * MIN);
    reset();
    groupsNow = [group, group2];
    tabs.push(claudeTab(L.solo, 'only me'), claudeTab(L.a, 'T'), claudeTab(L.long1, ext._claudeTabLabel(longT)), claudeTab(null, 'Claude Code'),
        claudeTab(lonely, 'Lonely tab'), other);
    tabs2.push(claudeTab(lonely, 'Lonely tab', group2));
    const tabsOf1 = await ext._openTabChats();
    check('open tabs: a label on one tab that one chat gives is that chat; an untitled tab, a label two tabs carry, and one two chats give are none',
        JSON.stringify(tabsOf1) === JSON.stringify([{ sessionId: L.solo, cwd: projA, label: 'only me' }]), JSON.stringify(tabsOf1));
    const tf = ext._tabsFile();
    fs.rmSync(path.dirname(tf), { recursive: true, force: true });
    ext._tabsIo.last = null;
    const realRename = fs.renameSync;
    const renamed = [];
    fs.renameSync = (a, b) => { renamed.push(path.basename(a) + '>' + path.basename(b)); return realRename(a, b); };
    const tw1 = await ext._lookTabs();
    const tb1 = JSON.parse(fs.readFileSync(tf, 'utf8'));
    check('open tabs: data/open-tabs/<host pid>.json - v, pid, started as reload-pending\'s, the window, the tabs - written whole and moved into place',
        tw1 === 'written' && path.dirname(tf) === path.join(reloadData, 'open-tabs') && path.basename(tf) === process.pid + '.json' &&
        tb1.v === 1 && tb1.pid === process.pid && Math.abs(tb1.started - (Date.now() - process.uptime() * 1000)) < 5000 && tb1.window === 'projA' &&
        JSON.stringify(tb1.tabs) === JSON.stringify(tabsOf1) && renamed.join() === process.pid + '.json.tmp>' + process.pid + '.json' && !fs.existsSync(tf + '.tmp'),
        tw1 + ' ' + JSON.stringify(tb1) + ' | ' + renamed.join());
    const tw2 = await ext._lookTabs();
    // the tab's twin closed: its label is one tab's now; listed by id, so a
    // tab moved changes nothing
    tabs2.length = 0;
    const tw3 = await ext._lookTabs();
    const tb3 = JSON.parse(fs.readFileSync(tf, 'utf8'));
    tabs.reverse();
    const tw4 = await ext._lookTabs();
    check('open tabs: written only when what it says changed - a look with nothing new, or a tab moved, writes nothing',
        tw2 === 'same' && tw3 === 'written' && tb3.tabs.map(t => t.sessionId).join() === [L.solo, lonely].join() && tw4 === 'same' && renamed.length === 2,
        [tw2, tw3, tw4, renamed.length].join() + ' ' + JSON.stringify(tb3.tabs));
    fs.unlinkSync(tf);
    const tw5 = await ext._lookTabs();
    const tf5 = fs.existsSync(tf);
    tabs.length = 0;
    tabs.push(claudeTab(null, 'Claude Code'), other);
    const tw6 = await ext._lookTabs();
    const tf6 = fs.existsSync(tf);
    const tw7 = await ext._lookTabs();
    check('open tabs: the file gone, it is written again; no tab named, it goes - and stays gone',
        tw5 === 'written' && tf5 && tw6 === 'removed' && !tf6 && tw7 === 'same' && !fs.existsSync(tf), [tw5, tf5, tw6, tf6, tw7].join());
    // a look past labelBudget: the file as it was, said once - the reads held
    // until both looks are done, since one let go on a timer could land
    // before a slow second look and make it a cache hit in time; at most
    // 10 s, so a look that waited for them fails rather than hangs
    tabs.length = 0;
    tabs.push(claudeTab(L.solo, 'only me'));
    await ext._lookTabs();
    tabs.push(claudeTab(lonely, 'Lonely tab'));
    ext._titleCache.clear();
    let freeReads;
    const readsHeld = new Promise(r => { const t = setTimeout(r, 10000); freeReads = () => { clearTimeout(t); r(); }; });
    ext._readChat = async (c) => { await readsHeld; return realReadChat(c); };
    ext._timing.labelBudget = 30;
    logged.length = 0;
    ext._tabsIo.late = false;
    if (ext._tabsIo.timer) { clearTimeout(ext._tabsIo.timer); ext._tabsIo.timer = null; }
    const tw8 = await ext._lookTabs();
    const soon8 = !!ext._tabsIo.timer;
    if (ext._tabsIo.timer) { clearTimeout(ext._tabsIo.timer); ext._tabsIo.timer = null; }
    const tw9 = await ext._lookTabs();
    const soon9 = !!ext._tabsIo.timer;
    const lateSaid = logged.filter(l => /^open-tabs: /.test(l));
    ext._timing.labelBudget = 0;
    ext._readChat = realReadChat;
    freeReads();
    const tb9 = JSON.parse(fs.readFileSync(tf, 'utf8'));
    check('open tabs: the folders\' chats not all read within labelBudget - the file left as it was, and said once; the first late looks again soon, the next not',
        tw8 === 'late' && tw9 === 'late' && tb9.tabs.map(t => t.sessionId).join() === L.solo && soon8 && !soon9 &&
        lateSaid.join() === 'open-tabs: the folders\' chats not all read in 30 ms - the tabs looked at again later', [tw8, tw9, soon8, soon9].join() + ' | ' + lateSaid.join(' | '));
    // watched: soon after activation, as the tabs change, and gone with the
    // window
    ext._timing.tabsSettle = 0;
    ext._timing.tabsEvery = 0;
    let onTabs = null;
    stub.window.tabGroups.onDidChangeTabs = (fn) => { onTabs = fn; return { dispose() { } }; };
    const ctxT = { subscriptions: [] };
    tabs.length = 0;
    tabs.push(claudeTab(L.solo, 'only me'));
    fs.unlinkSync(tf);
    ext._tabsIo.last = null;
    ext._watchTabs(ctxT);
    for (let i = 0; i < 50 && !fs.existsSync(tf); i++) await tick();
    const wt1 = fs.existsSync(tf) ? JSON.parse(fs.readFileSync(tf, 'utf8')).tabs.length : 0;
    tabs.push(claudeTab(lonely, 'Lonely tab'));
    if (onTabs) { onTabs(); onTabs(); }
    for (let i = 0; i < 50 && JSON.parse(fs.readFileSync(tf, 'utf8')).tabs.length < 2; i++) await tick();
    const wt2 = JSON.parse(fs.readFileSync(tf, 'utf8')).tabs.length;
    for (const s of ctxT.subscriptions) s.dispose();
    const wt3 = fs.existsSync(tf);
    if (onTabs) onTabs();
    await tick();
    await tick();
    check('open tabs: looked at after activation and as the tabs change; the window gone, its file goes, and a change after looks no more',
        typeof onTabs === 'function' && wt1 === 1 && wt2 === 2 && !wt3 && !fs.existsSync(tf), [typeof onTabs, wt1, wt2, wt3].join());
    fs.renameSync = realRename;
    delete stub.window.tabGroups.onDidChangeTabs;
    // the activations below look at no tabs: the tabs here are the tests'
    ext._timing.tabsSettle = 3600000;
    reset();
    fs.unlinkSync(path.join(dir3, lonely + '.jsonl'));
    ext._titleCache.clear();

    // --- the picker: each registry entry's process, as the OS has it ----------
    // procFacts' PowerShell stood in for: procOf, by pid, what CIM would
    // say - a start as a FILETIME, the parent's pid and start, the names
    const ft = (ms) => ((BigInt(Math.round(ms)) + 11644473600000n) * 10000n).toString();
    const procOf = new Map();
    const realProcIo = ext._procIo;
    const procLine = (p, f) => ['proc', p, f.start, f.ppid, f.parentStart, f.name, f.parentName].join('|');
    ext._procIo = {
        platform: () => 'win32',
        run: async (script) => {
            procRuns.push(script);
            return [...procOf].filter(([p]) => new RegExp('ProcessId=' + p + '\\b').test(script)).map(([p, f]) => procLine(p, f)).join('\r\n');
        }
    };
    const facts = (p, x) => procOf.set(p, Object.assign({ start: ft(pnow), ppid: 999301, parentStart: ft(pnow - HOUR), name: 'claude.exe', parentName: 'Code' }, x));
    const parsed = ext._parseProcs('proc|12|133000000000000000|34|132000000000000000|claude.exe|Code\r\nnoise\r\nproc|56|0|0|0|Code Helper.exe|\nproc 78 0 0 0 old.exe\n');
    check('proc: CIM\'s lines by pid, FILETIMEs kept as strings, a name with a space whole, a parent of no name, anything else passed over',
        parsed.size === 2 && parsed.get(12).start === '133000000000000000' && parsed.get(12).ppid === 34 && parsed.get(12).parentName === 'Code' &&
        parsed.get(56).name === 'Code Helper.exe' && parsed.get(56).parentName === '' &&
        /ProcessId=7 OR ProcessId=8/.test(ext._procScript([7, 8])) && /ToFileTimeUtc/.test(ext._procScript([7])) && /ProcessName/.test(ext._procScript([7])),
        JSON.stringify([...parsed]));
    const fits = (o, f) => ext._startFits(Object.assign({ startedAt: pnow }, o), Object.assign({ start: ft(pnow), name: 'claude.exe' }, f));
    check('proc: an entry\'s process still its own - a claude or node, started within 3 s of a FILETIME procStart, never over 10 s after startedAt; a start not read says nothing',
        fits({ procStart: ft(pnow + 2000) }, {}) && fits({ procStart: ft(pnow) }, { name: 'node.exe' }) && fits({ procStart: 'Tue Sep 30 2026' }, { start: ft(pnow + 5000) }) &&
        !fits({ procStart: ft(pnow - 4000) }, {}) && !fits({ procStart: ft(pnow) }, { name: 'notepad.exe' }) && !fits({}, { start: ft(pnow + 11000) }) &&
        fits({ procStart: ft(pnow - HOUR) }, { start: '0' }) && fits({}, { start: ft(pnow - HOUR) }));
    const vs = { entrypoint: 'claude-vscode' };
    aliveSet.add(999301);
    const code = (x) => Object.assign({ start: ft(pnow), ppid: 999301, parentStart: ft(pnow - HOUR), parentName: 'Code' }, x);
    check('proc: a panel\'s window by its parent - this extension host is here, another Code that is there is another window; a terminal\'s, a parent gone, of another name, or younger than its child cannot be told',
        ext._whereOf(vs, code({ ppid: process.pid })) === 'here' && ext._whereOf(vs, code({})) === 'window' &&
        ext._whereOf(vs, code({ parentName: 'Code - Insiders' })) === 'window' &&
        ext._whereOf({ entrypoint: 'cli' }, code({ ppid: process.pid })) === '' &&
        ext._whereOf(vs, code({ ppid: 999302 })) === '' && ext._whereOf(vs, code({ parentName: 'pwsh' })) === '' &&
        ext._whereOf(vs, code({ parentName: '' })) === '' &&
        ext._whereOf(vs, code({ parentStart: ft(pnow + MIN) })) === '' && ext._whereOf(vs, code({ parentStart: '0' })) === '');
    check('proc: a chat\'s place - every panel here, every one in other windows, else none; and those windows\' hosts',
        ext._placeOf([{ where: 'here' }, { where: 'here' }]) === 'here' && ext._placeOf([{ where: 'window', host: 5 }]) === 'window' &&
        ext._placeOf([{ where: 'here' }, { where: 'window' }]) === '' && ext._placeOf([{ where: 'window' }, {}]) === '' && ext._placeOf(undefined) === '' &&
        ext._hostsOf([{ where: 'window', host: 5 }, { where: 'window', host: 5 }, { where: 'here', host: 6 }, { where: 'window', host: 7 }]).join() === '5,7');
    // the look: once per pid within procFresh, a failed one not kept, and
    // none at all off Windows
    ext._procSeen.clear();
    procRuns.length = 0;
    facts(999211);
    aliveSet.add(999211);
    const pf1 = await ext._procFacts([999211, 999212], pnow);
    const pf2 = await ext._procFacts([999211, 999212], pnow + 5000);
    const runsKept = procRuns.length, firstRun = procRuns[0] || '';
    await ext._procFacts([999211], pnow + ext._timing.procFresh + 1);
    const runsLater = procRuns.length;
    ext._procSeen.clear();
    procOf.clear();
    procRuns.length = 0;
    logged.length = 0;
    const pfFail = await ext._procFacts([999211], pnow);
    await ext._procFacts([999211], pnow + 1);
    const failRuns = procRuns.length;
    const winIo = ext._procIo;
    ext._procIo = { platform: () => 'darwin', run: winIo.run };
    const pfMac = await ext._procFacts([999211], pnow);
    const macRuns = procRuns.length;
    ext._procIo = winIo;
    check('proc: every pid asked in one run, kept procFresh - a pid not there kept as unknown too; a look that found nothing kept not, and logged; off Windows, none',
        pf1.get(999211).name === 'claude.exe' && !pf1.has(999212) && pf2.size === 1 && runsKept === 1 && /ProcessId=999211 OR ProcessId=999212/.test(firstRun) &&
        runsLater === 2 && pfFail.size === 0 && failRuns === 2 && logged.some(l => /^processes 999211: their start and parent could not be read$/.test(l)) &&
        pfMac.size === 0 && macRuns === 2, runsKept + ' ' + runsLater + ' ' + failRuns + ' ' + macRuns + ' | ' + logged.join(' | '));
    // a pick while the picker's look is still out waits for it; and a look
    // that fails never hands back an answer older than procFresh
    ext._procSeen.clear();
    procRuns.length = 0;
    facts(999213);
    const [pfA, pfB] = await Promise.all([ext._procFacts([999213, 999214], pnow), ext._procFacts([999213], pnow + 1)]);
    const sharedRuns = procRuns.length;
    procOf.clear();
    ext._procSeen.set(999215, { at: pnow - 3 * ext._timing.procFresh, f: { start: ft(pnow), ppid: 1, parentStart: '0', name: 'claude.exe', parentName: '' } });
    const pfOld = await ext._procFacts([999215], pnow);
    check('proc: a second look while one is out waits for that one - one PowerShell, the same answer; a failed look gives no older answer back',
        sharedRuns === 1 && pfA.get(999213).name === 'claude.exe' && pfB.get(999213).name === 'claude.exe' && pfOld.size === 0,
        sharedRuns + ' ' + pfA.size + ' ' + pfB.size + ' ' + pfOld.size);
    // the registry with it: a pid handed on since boot is no chat's
    ext._procSeen.clear();
    regSet([[999221, { sessionId: L.a, procStart: ft(pnow) }], [999222, { sessionId: L.solo, procStart: ft(pnow) }], [999223, { sessionId: L.b, procStart: ft(pnow) }]]);
    facts(999221, { start: ft(pnow + 20 * MIN) });
    facts(999222, { name: 'svchost.exe' });
    facts(999223, { ppid: process.pid, parentStart: ft(pnow - DAY) });
    const lr = await ext._liveRegistry(home3, Date.now());
    const plain = ext._readRegistry(home3, Date.now());
    check('proc: the registry, each process looked at - a pid a later process has, or one of no claude\'s, runs nothing; a panel here is here, and the plain read still counts all three',
        !lr.has(L.a) && !lr.has(L.solo) && lr.get(L.b)[0].where === 'here' && lr.get(L.b)[0].host === process.pid && plain.size === 3,
        [...lr.keys()].join() + ' / ' + plain.size);
    // the middle dot between the age and the state
    const dotSp = ' ' + String.fromCharCode(0xb7) + ' ';
    check('proc: the picker says where - in this window, in another window - for a chat open or working; nothing more for the rest',
        ext._pickItem({ sid: G(1), mtimeMs: pnow, folder: 'f' }, { title: 't' }, 'open', false, pnow, 'window').description === 'now' + dotSp + 'open in another window' &&
        ext._pickItem({ sid: G(1), mtimeMs: pnow, folder: 'f' }, { title: 't' }, 'working', false, pnow, 'here').description === 'now' + dotSp + 'working in this window' &&
        ext._pickItem({ sid: G(1), mtimeMs: pnow, folder: 'f' }, { title: 't' }, 'terminal', false, pnow, 'here').description === 'now' + dotSp + 'in a terminal' &&
        ext._pickItem({ sid: G(1), mtimeMs: pnow, folder: 'f' }, { title: 't' }, 'open', false, pnow, '').description === 'now' + dotSp + 'open');
    // the accept, and the chat handed to the window that has it: its
    // open-request in a tool folder of the sandbox's own
    const handTool = path.join(pk, 'tool');
    cfgVals['chatManager.folder'] = handTool;
    const handFile = path.join(handTool, 'data', 'open-request');
    const handed = () => { try { return JSON.parse(fs.readFileSync(handFile, 'utf8')); } catch (e) { return null; } };
    const inOther = (pid, x) => { ext._procSeen.clear(); procOf.clear(); regSet([[pid, Object.assign({ sessionId: L.solo }, x)]]); facts(pid); };
    reset();
    logged.length = 0;
    fs.rmSync(handTool, { recursive: true, force: true });
    inOther(999231, { status: 'busy' });
    const hw1 = await ext._acceptChat(c3(L.solo));
    const hq1 = handed();
    check('hand: working in another window, no tab here - handed to that window through data/open-request, as the chip hands one, and said; nothing opened here',
        hw1 === 'handed to 999301' && calls.join() === 'ask' && asked[0] === ext._texts.pickHanded({ title: 'only me' }) &&
        !!hq1 && hq1.kind === 'open' && hq1.sessionId === L.solo && hq1.oldProcess === 'held' && hq1.hostPids.join() === '999301' && hq1.busy === null &&
        hq1.title === 'only me' && hq1.cwd === projA && ext._isGuid(hq1.id) && Math.abs(Date.parse(hq1.at) - Date.now()) < 60000 && !ext._isTarget(hq1) &&
        logged.includes('pick ' + L.solo.slice(0, 8) + ': working -> handed to 999301'), hw1 + ' ' + calls.join() + ' ' + JSON.stringify(hq1));
    reset();
    fs.rmSync(handTool, { recursive: true, force: true });
    inOther(999232);
    warnAnswer = 'Show it there';
    const hw2 = await ext._acceptChat(c3(L.solo));
    const hq2 = handed(), hw2Calls = calls.join(), hw2Asked = asked.slice();
    reset();
    fs.rmSync(handTool, { recursive: true, force: true });
    inOther(999233);
    warnAnswer = 'Open here too';
    const hw3 = await ext._acceptChat(c3(L.solo));
    check('hand: open idle in another window - asked, Show it there handing it over (live), Open here too opening a second copy here as before',
        hw2 === 'handed to 999301' && hw2Calls === 'warn,ask' && hw2Asked[0] === ext._texts.pickThere({ title: 'only me' }) && hq2 && hq2.oldProcess === 'live' &&
        hw3 === 'new' && calls.join() === 'warn,' + OPENED && handed() === null, hw2 + ' ' + hw2Calls + ' / ' + hw3 + ' ' + calls.join());
    // this window's own side bar: said so, and never handed anywhere
    reset();
    inOther(999234, { status: 'busy' });
    facts(999234, { ppid: process.pid });
    const hh1 = await ext._acceptChat(c3(L.solo));
    const hh1Asked = asked.slice();
    reset();
    inOther(999235);
    facts(999235, { ppid: process.pid });
    warnAnswer = 'Cancel';
    const hh2 = await ext._acceptChat(c3(L.solo));
    check('hand: held in this window outside its tabs - working refused as this window\'s side bar, idle asked as it; nothing handed',
        hh1 === 'refused' && hh1Asked[0] === ext._texts.pickWorkingHere({ title: 'only me' }) &&
        hh2 === 'cancelled' && asked[0] === ext._texts.pickSideBar({ title: 'only me' }) && handed() === null, hh1 + ' ' + hh2 + ' ' + asked.join(' | '));
    // Show it there, and the chat left that window meanwhile
    reset();
    inOther(999236);
    warnAnswer = 'Show it there';
    stub.window.showWarningMessage = async (m, ...b) => { const r = await plainWarn(m, ...b); ext._procSeen.clear(); facts(999236, { ppid: process.pid }); return r; };
    const hm1 = await ext._acceptChat(c3(L.solo));
    stub.window.showWarningMessage = plainWarn;
    check('hand: Show it there, the chat since in this window\'s side bar - nothing done, and said; no second copy unasked',
        hm1 === 'moved' && calls.join() === 'warn,ask' && asked[1] === ext._texts.pickMoved({ title: 'only me' }) && handed() === null && !calls.includes(OPEN),
        hm1 + ' ' + calls.join());
    // Show it there, and the chat closed meanwhile: nothing holds it now,
    // so it opens here from disk - the only place left to show it
    reset();
    logged.length = 0;
    inOther(999238);
    warnAnswer = 'Show it there';
    stub.window.showWarningMessage = async (m, ...b) => { const r = await plainWarn(m, ...b); ext._procSeen.clear(); regSet([]); return r; };
    const hc1 = await ext._acceptChat(c3(L.solo));
    stub.window.showWarningMessage = plainWarn;
    check('hand: Show it there, the chat closed since - opened here from disk, as a closed chat is; nothing handed',
        hc1 === 'new' && calls.join() === 'warn,' + OPENED && handed() === null && logged.includes('pick ' + L.solo.slice(0, 8) + ': closed -> new'),
        hc1 + ' ' + calls.join() + ' | ' + logged.join(' | '));
    // the picker itself: its list put again once the look comes back - the
    // look held back here until the titles are listed, so only that second
    // put can say where a chat is, or drop a pid a later process has
    reset();
    ext._procSeen.clear();
    procOf.clear();
    regSet([[999241, { sessionId: L.solo }], [999242, { sessionId: L.long2, procStart: ft(pnow) }]]);
    facts(999241);
    facts(999242, { start: ft(pnow + 20 * MIN) });
    let lookGo;
    const lookHeld = new Promise(r => { lookGo = r; });
    const lookIo = ext._procIo;
    ext._procIo = { platform: lookIo.platform, run: async (s) => { await lookHeld; return lookIo.run(s); } };
    procRuns.length = 0;
    const pp = ext._openChat();
    const qpL = qps[qps.length - 1];
    const descL = (sid) => (qpL.items.find(i => i.chat.sid === sid) || {}).description || '';
    await waitFor(() => qpL.sets.length && !qpL.busy);
    const lookBefore = [descL(L.solo), descL(L.long2)];
    const setsBefore = qpL.sets.length;
    lookGo();
    await waitFor(() => qpL.sets.length > setsBefore);
    const lookAfter = [descL(L.solo), descL(L.long2)];
    const ppRuns = procRuns.slice();
    qpL.hide();
    const ppr = await pp;
    ext._procIo = lookIo;
    check('proc: the picker puts its list again once the look is back - a chat in another window says so, one whose pid a later process has drops to no state',
        lookBefore[0].endsWith(dotSp + 'open') && lookBefore[1].endsWith(dotSp + 'open') &&
        lookAfter[0].endsWith(dotSp + 'open in another window') && lookAfter[1] !== '' && !lookAfter[1].includes(dotSp) &&
        ppRuns.length === 1 && /ProcessId=999241\b/.test(ppRuns[0]) && /ProcessId=999242\b/.test(ppRuns[0]) && ppr === 'none',
        lookBefore.join(' | ') + ' / ' + lookAfter.join(' | ') + ' / ' + ppRuns.length + ' run(s)');
    // the open-request that cannot be written: said, nothing opened here
    reset();
    logged.length = 0;
    fs.rmSync(handTool, { recursive: true, force: true });
    fs.writeFileSync(handTool, 'a file where the tool folder would be');
    inOther(999237, { status: 'busy' });
    const hn1 = await ext._acceptChat(c3(L.solo));
    check('hand: data/open-request that cannot be written - not handed, said, and logged; nothing opened here',
        hn1 === 'not handed' && calls.join() === 'ask' && asked[0] === ext._texts.pickNotHanded({ title: 'only me' }) &&
        logged.some(l => l.startsWith('pick ' + L.solo.slice(0, 8) + ': ') && /could not be written/.test(l)), hn1 + ' ' + calls.join() + ' | ' + logged.join(' | '));
    fs.rmSync(handTool, { force: true });
    delete cfgVals['chatManager.folder'];
    ext._procSeen.clear();
    procOf.clear();
    ext._procIo = realProcIo;

    // --- the queue, in the status bar ------------------------------------------
    // data/ of a tool folder of the sandbox's own: job files as New-ChatqJobSlot
    // names them, data/state.json as Save-ChatqWatchState writes it
    const qTool = path.join(pk, 'qtool'), qData = path.join(qTool, 'data');
    cfgVals['chatManager.folder'] = qTool;
    fs.rmSync(qTool, { recursive: true, force: true });
    fs.mkdirSync(path.join(qData, 'queue'), { recursive: true });
    const qJob = (id, x) => fs.writeFileSync(path.join(qData, 'queue', id + '.json'),
        JSON.stringify(Object.assign({ id, seq: Number(id.replace(/\D/g, '')) || 1, state: 'queued', provider: 'claude', home: null }, x)));
    const qState = (x) => fs.writeFileSync(path.join(qData, 'state.json'), JSON.stringify(Object.assign({ pid: 999401, blocked: {}, outage: {}, listening: false }, x)));
    const iso = (ms) => new Date(ms).toISOString();
    const qnow = Date.now();
    // the pure parts: the lanes' waits, the next send, the words
    const blk = ext._queueBlocks({ blocked: { claude: { until: iso(qnow + HOUR), type: 'session' }, 'claude|/h2': { until: iso(qnow - MIN), type: 'session' } }, outage: { codex: {} } }, true, qnow);
    check('queue: the lanes\' limits and overloads from the watcher\'s state - one ended left out; none where the watcher is down or only listening',
        blk.claude.until === Date.parse(iso(qnow + HOUR)) && !blk['claude|/h2'] && blk.codex.type === 'overloaded' &&
        Object.keys(ext._queueBlocks({ blocked: { claude: { until: iso(qnow + HOUR) } } }, false, qnow)).length === 0 &&
        Object.keys(ext._queueBlocks({ blocked: { claude: { until: iso(qnow + HOUR) } }, listening: true }, true, qnow)).length === 0, JSON.stringify(blk));
    const qn = (jobs, blocks) => ext._queueNext(jobs, blocks || {}, qnow);
    const qx1 = qn([{ state: 'queued', provider: 'claude', notBefore: iso(qnow + 2 * HOUR) }, { state: 'queued', provider: 'claude' }, { state: 'done', provider: 'claude' }]);
    const qx2 = qn([{ state: 'queued', provider: 'claude' }, { state: 'running', provider: 'claude', seq: 7 }]);
    const qx3 = qn([{ state: 'queued', provider: 'claude', notBefore: iso(qnow + 2 * HOUR) }, { state: 'queued', provider: 'claude', retryAt: iso(qnow + HOUR), notBefore: iso(qnow - HOUR) }]);
    const qx4 = qn([{ state: 'queued', provider: 'claude' }], { claude: { until: qnow + HOUR } });
    const qx5 = qn([{ state: 'queued', provider: 'claude', home: '/h2' }], { claude: { until: qnow + HOUR } });
    const qx6 = qn([{ state: 'queued', provider: 'claude' }, { state: 'queued', provider: 'codex', deferUntil: iso(qnow + 3 * HOUR) }], { claude: { type: 'overloaded' } });
    const qx7 = qn([{ state: 'queued', provider: 'claude' }], { claude: { type: 'overloaded' } });
    check('queue: the next send as Get-ChatqEta has it - one free now is next, or after the run going; else the soonest wait, each job\'s latest; a limit\'s end and a minute, by its own lane; an overload skipped, or when Claude is back',
        qx1.count === 2 && qx1.next === 'now' && qx2.next === 'after' && qx2.seq === 7 && qx3.next === 'at' && qx3.at === Date.parse(iso(qnow + HOUR)) &&
        qx4.next === 'at' && qx4.at === qnow + HOUR + MIN && qx5.next === 'now' && qx6.next === 'at' && qx6.at === Date.parse(iso(qnow + 3 * HOUR)) &&
        qx7.next === 'back' && qn([{ state: 'done' }, { state: 'running', seq: 2 }]) === null, JSON.stringify([qx1, qx2, qx3, qx4, qx5, qx6, qx7]));
    // a deferUntil that is only the next look: the board's words, no time
    const qDefer = (x) => Object.assign({ state: 'queued', provider: 'claude', deferUntil: iso(qnow + 5 * MIN) }, x);
    const qw1 = qn([qDefer({ deferWhy: 'in-use' })]);
    const qw2 = qn([qDefer({ deferWhy: 'background', deferSince: iso(qnow - MIN) }), qDefer({ provider: 'codex', deferWhy: 'in-use' })]);
    const qw3 = qn([qDefer({ deferWhy: 'in-use' }), { state: 'queued', provider: 'claude', notBefore: iso(qnow + 2 * HOUR) }]);
    const qw4 = qn([qDefer({ deferWhy: 'background', retryAt: iso(qnow + HOUR) })]);
    const qw5 = qn([qDefer({ deferWhy: 'vscode' })]);
    const qw6 = qn([qDefer({ deferWhy: 'in-use', deferUntil: iso(qnow - MIN) })]);
    const qw7 = qn([qDefer({ deferWhy: 'in-use' }), { state: 'queued', provider: 'codex' }], { codex: { type: 'overloaded' } });
    check('queue: a job put off for a tab in use or a background command - its deferUntil only the next look - the board\'s words, no time; a later retry, a vscode hold, or another job\'s real time still a time; one past, free now',
        qw1.next === 'waits' && qw1.words === 'waits for you to leave its tab' && qw2.next === 'waits' && qw2.words === 'waits for a background command' &&
        qw3.next === 'at' && qw3.at === Date.parse(iso(qnow + 2 * HOUR)) && qw4.next === 'at' && qw4.at === Date.parse(iso(qnow + HOUR)) &&
        qw5.next === 'at' && qw5.at === Date.parse(iso(qnow + 5 * MIN)) && qw6.next === 'now' && qw7.next === 'waits',
        JSON.stringify([qw1, qw2, qw3, qw4, qw5, qw6, qw7]));
    const midday = new Date(2026, 9, 1, 12, 0, 0).getTime();
    const qt = (q, up) => ext._queueText(q, up === undefined ? true : up, midday);
    check('queue: the item\'s words, the board\'s - next, after #seq, a time today, a weekday before one later, when Claude is back; the watcher stopped said instead; none queued, no item',
        qt({ count: 2, next: 'now' }).text === '$(clock) chatq 2 queued' + dotSp + 'next' &&
        qt({ count: 1, next: 'after', seq: 7 }).text === '$(clock) chatq 1 queued' + dotSp + 'after #7' &&
        qt({ count: 1, next: 'at', at: new Date(2026, 9, 1, 16, 5).getTime() }).text === '$(clock) chatq 1 queued' + dotSp + '16:05' &&
        qt({ count: 1, next: 'at', at: new Date(2026, 9, 2, 9, 0).getTime() }).text === '$(clock) chatq 1 queued' + dotSp + 'Fri 09:00' &&
        qt({ count: 3, next: 'back' }).text === '$(clock) chatq 3 queued' + dotSp + 'when Claude is back' &&
        qt({ count: 2, next: 'now' }, false).text === '$(clock) chatq 2 queued' + dotSp + 'watcher stopped' && /chatqrun/.test(qt({ count: 2, next: 'now' }, false).tooltip) &&
        /Click for the queue/.test(qt({ count: 1, next: 'after', seq: 7 }).tooltip) && qt(null) === null,
        [qt({ count: 1, next: 'at', at: new Date(2026, 9, 2, 9, 0).getTime() }).text, qt({ count: 2, next: 'now' }, false).tooltip].join(' | '));
    const qtw = qt({ count: 1, next: 'waits', words: 'waits for you to leave its tab' });
    check('queue: a wait of no time in the board\'s words - and the tooltip promises no send time',
        qtw.text === '$(clock) chatq 1 queued' + dotSp + 'waits for you to leave its tab' && /waits for you to leave its tab/.test(qtw.tooltip) && !/sends at/.test(qtw.tooltip),
        qtw.text + ' | ' + qtw.tooltip);
    // a Codex lane's outage is Codex's, never Claude's - as Get-ChatqEta
    // says it on the board and in chatqlist; both down, both named
    const qcx = qn([{ state: 'queued', provider: 'codex' }], { codex: { type: 'overloaded' } });
    const qcxh = qn([{ state: 'queued', provider: 'codex', home: '/c2' }], { 'codex|/c2': { type: 'overloaded' } });
    const qboth = qn([{ state: 'queued', provider: 'codex' }, { state: 'queued', provider: 'claude' }], { codex: { type: 'overloaded' }, claude: { type: 'overloaded' } });
    const qtc = qt(qcx), qtb = qt(qboth);
    check('queue: a Codex overload says when Codex is back, text and tooltip, with no word of Claude; both down names both; a q with no who stays Claude\'s',
        qx7.who === 'Claude' && qcx.next === 'back' && qcx.who === 'Codex' && qcxh.who === 'Codex' && qboth.who === 'Claude and Codex' &&
        qtc.text === '$(clock) chatq 1 queued' + dotSp + 'when Codex is back' && /when Codex is back from its overload/.test(qtc.tooltip) && !/Claude/.test(qtc.text + qtc.tooltip) &&
        qtb.text === '$(clock) chatq 2 queued' + dotSp + 'when Claude and Codex are back' && /from their overloads/.test(qtb.tooltip),
        [JSON.stringify([qcx, qcxh, qboth]), qtc.text, qtc.tooltip, qtb.text, qtb.tooltip].join(' | '));
    // the item itself, from data/: the watcher's lock, its state, each job
    // file read again only once it changed
    const qItems = [];
    const plainSb = stub.window.createStatusBarItem, plainAlign = stub.StatusBarAlignment;
    stub.window.createStatusBarItem = (al, pr) => { const it = { text: '', shown: false, al, pr, show() { this.shown = true; }, hide() { this.shown = false; }, dispose() { } }; qItems.push(it); return it; };
    stub.StatusBarAlignment = { Left: 1, Right: 2 };
    const qIo = Object.assign({}, ext._overlayIo);
    let lockUp = true;
    const lockAsked = [];
    Object.assign(ext._overlayIo, { platform: () => 'win32', lockHeld: (f) => { lockAsked.push(f); return lockUp; } });
    const qu0 = ext._updateQueueItem(qnow);
    qJob('j1', { notBefore: iso(qnow + 2 * HOUR) });
    qJob('j2', { state: 'done' });
    qState({});
    const qu1 = ext._updateQueueItem(qnow);
    const qi = ext._queueItem();
    const qu1Item = qi ? { text: qi.text, shown: qi.shown, command: qi.command, pr: qi.pr } : null;
    // the cache, by file reads: nothing changed, no job file read again;
    // one rewritten, only that one
    const jobReads = [];
    const plainReadFile = fs.readFileSync;
    let qReads0 = [], qReads1 = [];
    fs.readFileSync = function (f, ...rest) {
        if (path.basename(path.dirname(String(f))) === 'queue') jobReads.push(path.basename(String(f)));
        return plainReadFile.call(this, f, ...rest);
    };
    try {
        ext._updateQueueItem(qnow);
        ext._updateQueueItem(qnow);
        qReads0 = jobReads.slice();
        qJob('j2', { state: 'done', note: 'rewritten' });
        ext._updateQueueItem(qnow);
        qReads1 = jobReads.slice(qReads0.length);
    } finally { fs.readFileSync = plainReadFile; }
    check('queue: each job file read again only once it changed - none while nothing did, then only the one rewritten',
        qReads0.length === 0 && qReads1.join() === 'j2.json', qReads0.join() + ' / ' + qReads1.join());
    // a job's file rewritten: read again; one not changed is not
    const readsBefore = ext._readQueue().length;
    qJob('j1', { notBefore: iso(qnow + 2 * HOUR), state: 'running' });
    qJob('j3', {});
    const qu2 = ext._updateQueueItem(qnow);
    lockUp = false;
    const qu3 = ext._updateQueueItem(qnow);
    qJob('j3', { state: 'done' });
    const qu4 = ext._updateQueueItem(qnow);
    const qu4Shown = qi && qi.shown;
    check('queue: the item from data/ - none before anything is queued; shown, the board\'s command on a click, beside the run\'s item; a job file changed read again; the watcher\'s lock down said; nothing queued, hidden',
        qu0 === 'hidden' && qItems.length === 1 && qu1Item && qu1Item.shown && qu1Item.command === 'chatManager.showQueue' && qu1Item.pr === 49 &&
        qu1 === '$(clock) chatq 1 queued' + dotSp + ext._queueText({ count: 1, next: 'at', at: Date.parse(iso(qnow + 2 * HOUR)) }, true, qnow).text.split(dotSp)[1] &&
        readsBefore === 2 && qu2 === '$(clock) chatq 1 queued' + dotSp + 'after #1' && qu3 === '$(clock) chatq 1 queued' + dotSp + 'watcher stopped' &&
        lockAsked.every(f => f === path.join(qData, 'watcher.lock')) && qu4 === 'hidden' && qu4Shown === false,
        [qu0, qu1, qu2, qu3, qu4].join(' | ') + ' ' + qItems.length);
    // off Windows the lock is only advisory: the pid the state saved answers
    Object.assign(ext._overlayIo, { platform: () => 'darwin' });
    aliveSet.add(999401);
    const macUp = ext._watcherUp({ pid: 999401 });
    aliveSet.delete(999401);
    check('queue: off Windows the watcher is up while the pid its state saved is - not by its lock',
        macUp && !ext._watcherUp({ pid: 999401 }) && !ext._watcherUp(null) && !ext._watcherUp({ pid: 'x' }));
    // a click: the board in the Markdown preview, or said where there is none
    const qCmds = [];
    const plainExec = stub.commands.executeCommand;
    stub.commands.executeCommand = async (c, a) => { qCmds.push(c + (a && a.fsPath ? ':' + a.fsPath : '')); };
    reset();
    const sq1 = await ext._showQueue();
    fs.writeFileSync(path.join(qData, 'queue.md'), '# chatq\n');
    const sq2 = await ext._showQueue();
    check('queue: a click opens data/queue.md in the Markdown preview; no board yet - said, nothing opened',
        sq1 === 'none' && asked[0] === ext._texts.noBoard && sq2 === 'shown' && qCmds.join() === 'markdown.showPreview:' + path.join(qData, 'queue.md'),
        sq1 + ' ' + sq2 + ' ' + qCmds.join() + ' | ' + asked.join(' | '));
    stub.commands.executeCommand = plainExec;
    stub.window.createStatusBarItem = plainSb;
    stub.StatusBarAlignment = plainAlign;
    Object.assign(ext._overlayIo, qIo);
    delete cfgVals['chatManager.folder'];
    fs.rmSync(qTool, { recursive: true, force: true });

    // --- chats Claude Code leaves out of its lists -----------------------------
    // Its rule: the first entrypoint in a transcript's first 64 KB, else the
    // last in its last 64 KB; an SDK's hides the chat, and its tab opens blank.
    const ep = (s, last) => ext._entrypointIn(s, last);
    check('hidden: the first entrypoint found as Claude Code finds it - the key without a space first, wherever the other stands; the last by place; escapes read; one cut off is none',
        ep('{"entrypoint": "x"}\n{"entrypoint":"y"}', false) === 'y' && ep('{"entrypoint":"a"}\n{"entrypoint": "b"}', true) === 'b' &&
        ep('{"entrypoint": "b"}\n{"entrypoint":"a"}', true) === 'a' && ep('{"entrypoint":"s\\"x"}', false) === 's"x' &&
        ep('{"entrypoint":"sdk-c', false) === undefined && ep('{"entrypoint":"a"}\n{"entrypoint":"sdk-c', true) === 'a' && ep('none here', true) === undefined,
        [ep('{"entrypoint": "x"}\n{"entrypoint":"y"}', false), ep('{"entrypoint":"a"}\n{"entrypoint": "b"}', true)].join());
    const epl = (v) => jl({ type: 'user', entrypoint: v, message: { role: 'user', content: 'x' } });
    const uw = (h, t) => ext._unlistedWhy(h, t);
    check('hidden: an SDK\'s entrypoint first in the head hides it for good; with none in the head, the tail\'s last decides - a terminal\'s, or a window\'s, is listed',
        uw(epl('claude-vscode'), epl('sdk-cli')) === '' && uw(epl('sdk-cli'), epl('claude-vscode')) === 'head' && uw(epl('sdk-ts'), '') === 'head' &&
        uw(user('big'), epl('claude-vscode') + epl('sdk-cli')) === 'tail' && uw(user('big'), epl('sdk-cli') + epl('cli')) === '' &&
        uw(user('big'), user('no entrypoint')) === '' && uw(epl(''), epl('sdk-cli')) === '',
        [uw(epl('claude-vscode'), epl('sdk-cli')), uw(user('big'), epl('claude-vscode') + epl('sdk-cli'))].join());
    const home4 = path.join(pk, 'home4');
    const dir4 = path.join(home4, 'projects', ext._chatSlug(projA));
    const reg4 = path.join(home4, 'sessions');
    fs.mkdirSync(reg4, { recursive: true });
    // a first prompt of a pasted screenshot: 64 KB and more, and no entrypoint
    const shot = user([{ type: 'image', source: { type: 'base64', data: 'A'.repeat(70000) } }, { type: 'text', text: 'look' }]);
    const H = { tail: G(0x3001), cut: G(0x3002), held: G(0x3003), head: G(0x3004), fine: G(0x3005), open: G(0x3006), pick: G(0x3007),
        idle: G(0x3008), far: G(0x3009), busyOpen: G(0x300a) };
    const hidTail = shot + epl('claude-vscode') + asst('x') + epl('sdk-cli') + jl({ type: 'ai-title', aiTitle: 'hidden by its tail' });
    for (const k of ['tail', 'held', 'open', 'pick', 'idle', 'busyOpen']) mkChat(dir4, H[k], hidTail, 2 * MIN);
    // filed where the slug does not say: found only by the path the script sends
    const farFile = mkChat(path.join(home4, 'projects', 'named-elsewhere'), H.far, hidTail, 2 * MIN);
    mkChat(dir4, H.cut, hidTail.slice(0, -1), 2 * MIN);
    mkChat(dir4, H.head, epl('sdk-cli') + asst('x') + epl('sdk-cli'), 2 * MIN);
    mkChat(dir4, H.fine, shot + epl('claude-vscode') + epl('cli'), 2 * MIN);
    const f4 = (sid) => path.join(dir4, sid + '.jsonl');
    const read4 = (sid) => fs.readFileSync(f4(sid), 'utf8');
    const why4 = async (sid) => { const ht = await ext._headAndTail(f4(sid)); return ext._unlistedWhy(ht.head, ht.tail); };
    const req4 = (sid, x) => Object.assign({ kind: 'open', sessionId: sid, title: 'hidden by its tail', cwd: projA, home: home4, oldProcess: 'none', hostPids: [] }, x);
    logged.length = 0;
    const wasTail = await why4(H.tail);
    const mtimeTail = fs.statSync(f4(H.tail)).mtimeMs;
    const el1 = await ext._ensureListed(req4(H.tail));
    const nowTail = await why4(H.tail);
    const lastTail = read4(H.tail).trimEnd().split('\n').pop();
    const mtimeAfter = fs.statSync(f4(H.tail)).mtimeMs;
    const el1b = await ext._ensureListed(req4(H.tail));
    const linesTail = read4(H.tail).split('\n').filter(Boolean).length;
    check('hidden by its tail: one line of chatq\'s own added at the end, naming a VS Code panel, no timestamp - listed again, its write time kept, and a second look adds none',
        wasTail === 'tail' && el1 === 'relisted' && nowTail === '' &&
        lastTail === '{"type":"chatq-listed","entrypoint":"claude-vscode","sessionId":"' + H.tail + '"}' && ext._listedLine(H.tail) === lastTail + '\n' &&
        Math.abs(mtimeAfter - mtimeTail) < 2 && el1b === 'listed' && linesTail === hidTail.split('\n').filter(Boolean).length + 1 &&
        logged.includes('open ' + H.tail.slice(0, 8) + ': listed again - Claude Code had left it out, an SDK run\'s record last in it'),
        [wasTail, el1, nowTail, el1b, linesTail, lastTail, mtimeTail, mtimeAfter].join(' | '));
    const el2 = await ext._ensureListed(req4(H.cut));
    const cutLines = read4(H.cut).split('\n').filter(Boolean);
    let cutParse = true;
    for (const l of cutLines) { try { JSON.parse(l); } catch (e) { cutParse = false; } }
    check('hidden, its last line lacking its end: the added one is a line of its own - every line still parses',
        el2 === 'relisted' && cutParse && cutLines.length === hidTail.split('\n').filter(Boolean).length + 1, el2 + ' ' + cutParse + ' ' + cutLines.length);
    // started just now, as regPut's - a runner may have booted minutes ago
    const reg4Put = (pid, x) => {
        fs.writeFileSync(path.join(reg4, pid + '.json'), JSON.stringify(Object.assign({ pid, cwd: projA, startedAt: pnow, status: 'idle', entrypoint: 'claude-vscode' }, x)));
        aliveSet.add(pid);
    };
    reg4Put(999301, { sessionId: H.held, status: 'busy' });
    reg4Put(999302, { sessionId: H.idle });
    reg4Put(999303, { sessionId: H.busyOpen, kind: 'print', entrypoint: 'sdk-cli', status: 'idle' });
    const heldBefore = read4(H.held);
    const el3 = await ext._ensureListed(req4(H.held));
    const el3b = await ext._ensureListed(req4(H.idle));
    const el4 = await ext._ensureListed(req4(H.head));
    const el5 = await ext._ensureListed(req4(H.fine));
    const el6 = await ext._ensureListed(req4(G(0x3999)));
    const el7 = await ext._ensureListed({ kind: 'open', sessionId: H.tail, title: 'x' });
    check('hidden, a process busy in it: left as it is; one idle in it writes nothing - mended beside it; hidden by its head: unlistable, untouched; listed, or no transcript found: nothing written',
        el3 === 'held' && read4(H.held) === heldBefore && el3b === 'relisted' && el4 === 'unlistable' && read4(H.head) === epl('sdk-cli') + asst('x') + epl('sdk-cli') &&
        el5 === 'listed' && el6 === 'unknown' && el7 === 'unknown' && !fs.existsSync(f4(G(0x3999))), [el3, el3b, el4, el5, el6, el7].join());
    // the script's path for it: taken where the slug finds nothing - but only
    // a file named for the chat, never another the request names
    const el8 = await ext._ensureListed(req4(H.far, { cwd: projB, file: farFile }));
    const el9 = await ext._ensureListed(req4(H.far, { cwd: projB, file: f4(H.cut) }));
    check('a request\'s transcript path: mended there where the slug finds nothing; one not named for the chat is never written to',
        el8 === 'relisted' && fs.readFileSync(farFile, 'utf8').trimEnd().split('\n').pop().includes('"chatq-listed"') && el9 === 'unknown', el8 + ' ' + el9);
    // an open of each: the chip's and the picker's, through openCore
    const terms = [];
    stub.window.createTerminal = (o) => { terms.push(o); return { show() { calls.push('terminal'); } }; };
    reset();
    Object.assign(titles, { [H.open]: 'hidden by its tail' });
    // what the transcript's last line was as the open was asked for
    const plainCmd = stub.commands.executeCommand;
    let lastAtOpen = '';
    stub.commands.executeCommand = async (c, sid) => {
        if (c === OPEN && sid === H.open) lastAtOpen = read4(H.open).trimEnd().split('\n').pop();
        return plainCmd(c, sid);
    };
    const ho1 = await ext._openTab(req4(H.open));
    stub.commands.executeCommand = plainCmd;
    const ho1Calls = calls.join();
    check('the open chip on a chat hidden by its tail: listed again before the open is asked for, then opened in a tab as any other',
        ho1 === 'new' && ho1Calls === OPENED && lastAtOpen.includes('"chatq-listed"'), ho1 + ' ' + ho1Calls + ' ' + lastAtOpen.slice(0, 60));
    reset();
    const ho1b = await ext._openTab(req4(H.busyOpen));
    check('the open chip on a chat hidden by its tail while a run writes to it: not mended, not opened - no blank tab - and said',
        ho1b === 'held' && !calls.includes(OPEN) && asked[0] === ext._texts.hiddenBusy({ title: 'hidden by its tail' }) &&
        read4(H.busyOpen) === hidTail, ho1b + ' ' + calls.join());
    reset();
    answer = 'Open in a terminal';
    const ho2 = await ext._openTab(req4(H.head, { title: 'started by chatq' }));
    await settle();
    answer = undefined;
    check('the open chip on a chat hidden by its head: no blank tab - never opened - and a terminal offered, claude --resume run as its own process, in its folder and Claude home',
        ho2 === 'unlistable' && !calls.includes(OPEN) && asked[0] === ext._texts.unlistable({ title: 'started by chatq' }) &&
        terms.length === 1 && terms[0].shellPath === 'claude' && terms[0].shellArgs.join(' ') === '--resume ' + H.head &&
        terms[0].cwd === projA && terms[0].env.CLAUDE_CONFIG_DIR === home4 && calls.includes('terminal'),
        ho2 + ' ' + calls.join() + ' ' + JSON.stringify(terms));
    reset();
    const ho3 = await ext._openTab(req4(H.head, { title: 'started by chatq' }));
    await settle();
    check('and "Not now": no terminal', ho3 === 'unlistable' && terms.length === 1 && !calls.includes(OPEN), ho3 + ' ' + calls.join());
    reset();
    const ho4 = await ext._showTab({ kind: 'ran', sessionId: H.head, title: 'started by chatq', cwd: projA, home: home4 });
    await settle();
    check('Show it on a chat hidden by its head: nothing closed, nothing opened - the terminal offered', ho4 === 'unlistable' &&
        !calls.includes(OPEN) && !calls.some(c => c.startsWith('close:')) && asked[0] === ext._texts.unlistable({ title: 'started by chatq' }), ho4 + ' ' + calls.join());
    // the answer comes minutes later: what runs the chat is read again, and
    // a second click while the offer is up asks nothing more
    reset();
    reg4Put(999304, { sessionId: H.head });
    answer = 'Open in a terminal';
    const ot1 = await ext._offerTerminal(req4(H.head, { title: 'started by chatq' }));
    fs.unlinkSync(path.join(reg4, '999304.json'));
    const ot1Asked = asked.slice();
    let letGo;
    const plainAsk = stub.window.showInformationMessage;
    stub.window.showInformationMessage = (m, ...b) => new Promise(r => { letGo = () => r(undefined); });
    const ot2 = ext._offerTerminal(req4(H.head));
    const ot3 = await ext._offerTerminal(req4(H.head));
    letGo();
    const ot2r = await ot2;
    stub.window.showInformationMessage = plainAsk;
    answer = undefined;
    check('the terminal offer: taken minutes later, the chat running by then - no terminal, and said; a second offer while one is up - none',
        ot1 === 'running' && terms.length === 1 && ot1Asked[1] === ext._texts.terminalBusy({ title: 'started by chatq' }) && ot3 === 'asked' && ot2r === 'not now',
        [ot1, ot3, ot2r, terms.length].join());
    // a line that cannot be written: left out still, so not opened
    const roFile = mkChat(dir4, G(0x300b), hidTail, 2 * MIN);
    fs.chmodSync(roFile, 0o444);
    reset();
    logged.length = 0;
    const ho5 = await ext._openTab(req4(G(0x300b)));
    fs.chmodSync(roFile, 0o666);
    check('a chat hidden by its tail whose line cannot be written: not opened - no blank tab - and said',
        ho5 === 'unmended' && !calls.includes(OPEN) && asked[0] === ext._texts.unmended({ title: 'hidden by its tail' }) &&
        fs.readFileSync(roFile, 'utf8') === hidTail, ho5 + ' ' + calls.join() + ' | ' + logged.join(' | '));
    // the picker: its request names the transcript it listed
    process.env.CLAUDE_CONFIG_DIR = home4;
    const chats4 = await ext._listChats(home4, folders);
    reset();
    claudeHere = true;
    Object.assign(titles, { [H.pick]: 'hidden by its tail' });
    const hp1 = await ext._acceptChat(chats4.find(c => c.sid === H.pick));
    reset();
    const hp2 = await ext._acceptChat(chats4.find(c => c.sid === H.head));
    await settle();
    claudeHere = false;
    check('the picker: a chat hidden by its tail listed again and opened; one hidden by its head not opened, the terminal offered',
        hp1 === 'new' && read4(H.pick).trimEnd().split('\n').pop().includes('"chatq-listed"') &&
        hp2 === 'unlistable' && !calls.includes(OPEN) && asked[0] === ext._texts.unlistable({ title: 'x' }), hp1 + ' ' + hp2 + ' ' + calls.join() + ' | ' + asked.join(' | '));
    delete stub.window.createTerminal;
    process.env.CLAUDE_CONFIG_DIR = noHome;
    aliveSet.clear();
    fs.rmSync(pk, { recursive: true, force: true });

    // --- a queued run where the chat's tab was: data/run-state -----------------
    // A tool folder of its own - run-state, the job, its prompt and its log,
    // and the answers written to run-ack - with the watched files' callbacks
    // kept, to be fired by hand, the watch panel made as VS Code makes it (a
    // tab of its own in its group), and PowerShell stood in for.
    {
        const setupMod = require(path.join(__dirname, '..', 'extension', 'setup.js'));
        const realWatchFile = fs.watchFile, realUnwatchFile = fs.unwatchFile;
        const fileCbs = [];
        fs.watchFile = (f, o, cb) => { fileCbs.push([f, cb]); };
        fs.unwatchFile = (f, cb) => { for (let i = fileCbs.length - 1; i >= 0; i--) if (fileCbs[i][0] === f && (!cb || fileCbs[i][1] === cb)) fileCbs.splice(i, 1); };
        const fire = (f) => { for (const [g, cb] of fileCbs.slice()) if (g === f) cb(); };
        const rt = path.join(dir, 'ext-run');
        fs.rmSync(rt, { recursive: true, force: true });
        const rdata = path.join(rt, 'data');
        for (const d of ['queue', 'logs']) fs.mkdirSync(path.join(rdata, d), { recursive: true });
        cfgVals['chatManager.folder'] = rt;
        claudeHere = true;
        const JOB = '20260928-101500-1111', JOB2 = '20260928-101600-2222';
        const RUNNER = 999501;
        aliveSet.add(process.pid);
        aliveSet.add(RUNNER);
        const jobF = path.join(rdata, 'queue', JOB + '.json'), logF = path.join(rdata, 'logs', JOB + '.jsonl');
        let rsN = 0;
        // handoverId as Write-ChatRunState (src/chatrm.ps1) gives it: a
        // handover's own id, else null unless the write passes the one
        // before it
        const putRs = (x) => {
            const id = 'rs-' + (++rsN);
            const o = Object.assign({ id, kind: 'prompt', phase: 'handover', jobId: JOB, seq: 15,
                provider: 'claude', sessionId: SID, title: 'T', cwd: projA, home: null, hostPids: [process.pid], runnerPid: RUNNER, away: false, beside: null,
                log: logF, job: jobF, at: new Date().toISOString() }, x);
            if (!(x && 'handoverId' in x)) o.handoverId = o.phase === 'handover' ? id : null;
            fs.writeFileSync(path.join(rdata, 'run-state'), JSON.stringify(o));
            return id;
        };
        const putJob = (x, id) => fs.writeFileSync(path.join(rdata, 'queue', (id || JOB) + '.json'), JSON.stringify(Object.assign({ id: id || JOB, seq: 15,
            provider: 'claude', sessionId: SID, title: 'T', cwd: projA, kind: 'prompt', promptFile: '#15 T.md', state: 'running',
            startedAt: new Date(Date.now() - 60000).toISOString(), runnerPid: RUNNER, history: [] }, x)));
        fs.writeFileSync(path.join(rdata, 'queue', '#15 T.md'), '﻿<!-- chatq: prompt for \'T\' (claude). Everything after this comment is sent -->\n\nfix the parser\nand the tests\nline three\nline four');
        const ackOf = () => { try { return JSON.parse(fs.readFileSync(path.join(rdata, 'run-ack', process.pid + '.json'), 'utf8')); } catch (e) { return null; } };
        const ws = {};
        context.workspaceState = memo(ws);
        const recs = () => ext._handovers(context);
        const panels = [];
        stub.window.createWebviewPanel = (viewType, title, show, opts) => {
            const g = show.viewColumn === 2 ? group2 : group;
            const p = {
                viewType, title, show, opts, posted: [], revealed: [], disposed: false, active: false, viewColumn: g.viewColumn,
                webview: { html: '', postMessage(m) { p.posted.push(m); return Promise.resolve(true); }, onDidReceiveMessage(cb) { p.onMsg = cb; return { dispose() { } }; } },
                onDidDispose(cb) { p.onDispose = cb; return { dispose() { } }; },
                reveal(c, pf) { p.revealed.push([c, pf]); },
                dispose() {
                    if (p.disposed) return;
                    p.disposed = true;
                    calls.push('dispose:watch');
                    const s = slot(g), i = s.list.indexOf(p.tab);
                    if (i >= 0) s.list.splice(i, 1);
                    if (s.act.tab === p.tab) s.act.tab = s.list[0];
                    if (p.onDispose) p.onDispose();
                }
            };
            p.tab = { label: title, input: new TabInputWebview('mainThreadWebview-chatManager.watch'), group: g, panel: p };
            const s = slot(g);
            s.list.push(p.tab);
            s.act.tab = p.tab;
            calls.push('watch:' + show.viewColumn + (show.preserveFocus ? ':pf' : ''));
            panels.push(p);
            return p;
        };
        const sbItems = [];
        stub.window.createStatusBarItem = () => { const it = { text: '', shown: false, show() { this.shown = true; }, hide() { this.shown = false; }, dispose() { } }; sbItems.push(it); return it; };
        stub.StatusBarAlignment = { Left: 1, Right: 2 };
        // PowerShell, as the scripts would answer
        const psCmds = [];
        // Hand over now's: the job still waiting for its tab, or not by then
        let psHandAnswer = 'handover: now';
        const realRunPs = setupMod._runPs, realIoRun = Object.assign({}, ext._overlayIo);
        setupMod._runPs = async (exe, loader, cmd) => {
            psCmds.push(cmd + ' @ ' + loader);
            if (/Request-ChatqWatcher -Wake now/.test(cmd)) return { ok: true, stdout: 'woken\r\n' };
            if (/Set-ChatqProp \$j 'deferUntil' \$null/.test(cmd)) return { ok: true, stdout: psHandAnswer + '\r\n' };
            if (/Stop-ChatqJobRun/.test(cmd)) return { ok: true, stdout: 'stop: cancelling\r\n' };
            return { ok: true, stdout: '' };
        };
        Object.assign(ext._overlayIo, { exists: () => true, powershell: () => 'PS', platform: () => 'win32' });
        // a Claude home whose registry says what runs the chat
        const homeR = path.join(rt, 'home');
        const regR = regFill(path.join(homeR, 'sessions'), (pid) => ({ pid, sessionId: SID, cwd: projA, startedAt: Date.now(), status: 'idle', kind: 'interactive', entrypoint: 'claude-vscode' }));
        const runOnce = async () => { const r = await ext._onRunState(context); await settle(); return r; };
        const resetRun = () => {
            for (const v of [...ext._watchViews.values()]) v.panel.dispose();
            reset();
            logged.length = 0;
            answer = undefined;
            fs.rmSync(path.join(rdata, 'run-ack'), { recursive: true, force: true });
            ext._forgetRuns();
            for (const k of Object.keys(ws)) delete ws[k];
            panels.length = 0;
            psCmds.length = 0;
            stub.window.state.focused = true;
            aliveSet.add(RUNNER);
            regR([]);
        };
        const rsT = { seq: 15, title: 'T' };

        // the handover: each answer, and what this window does
        resetRun();
        putJob({});
        const idOff = putRs({});
        frontTab();
        cfgVals['chatManager.watchRuns'] = false;
        const h1 = await runOnce();
        delete cfgVals['chatManager.watchRuns'];
        check('handover: chatManager.watchRuns off - answered off in run-ack/<this pid>.json by the handover\'s id; nothing closed, nothing opened',
            h1.acted === 'off' && ackOf().answer === 'off' && ackOf().id === idOff && calls.join() === '' && tabs.length === 1,
            JSON.stringify(h1) + ' ' + JSON.stringify(ackOf()) + ' ' + calls.join());
        resetRun();
        putJob({});
        putRs({});
        const h2 = await runOnce();
        const h2Calls = calls.join(), h2Asked = asked.slice(), h2Panel = panels[0];
        resetRun();
        putJob({});
        putRs({});
        tabs.push(claudeTab(SID, 'T'), claudeTab(SID2x, 'T'));
        active.tab = tabs[0];
        const h2b = await runOnce();
        check('handover: no tab here reads as the chat, or two do - unsure; its live view beside, the old view said stale; never editor.open, which would start a second process mid-run',
            h2.acted === 'unsure' && h2Calls === 'watch:-2:pf,warn' && h2Asked[0] === ext._texts.handoverStale(rsT) && !h2Calls.includes(OPEN) &&
            h2b.acted === 'unsure' && ackOf().answer === 'unsure' && !calls.some(c => c.startsWith('close:')) && !calls.includes(OPEN),
            h2Calls + ' / ' + calls.join() + ' ' + JSON.stringify(h2b));
        check('the watch panel: its own viewType, scripts on, its page kept while hidden, no local files at all; titled by the play mark, #15 and the chat\'s title',
            !!h2Panel && h2Panel.viewType === 'chatManager.watch' && h2Panel.opts.enableScripts === true && h2Panel.opts.retainContextWhenHidden === true &&
            Array.isArray(h2Panel.opts.localResourceRoots) && h2Panel.opts.localResourceRoots.length === 0 && h2Panel.title === '▶ #15 T' &&
            /script-src 'nonce-[A-Za-z0-9]+'/.test(h2Panel.webview.html), h2Panel && JSON.stringify([h2Panel.title, h2Panel.opts]));
        // in front of you, you here: it waits, and says so once
        resetRun();
        putJob({});
        putRs({});
        frontTab();
        const h3 = await runOnce();
        const h3Calls = calls.join(), h3Asked = asked.slice(), h3Ack = ackOf();
        putRs({});
        const h3b = await runOnce();
        check('handover: its tab in front of you in a focused window, you here - in-use: nothing closed, and said once, with Hand over now',
            h3.acted === 'in-use' && h3Ack.answer === 'in-use' && h3Calls === 'ask' && h3Asked[0] === ext._texts.inUse(rsT) &&
            h3b.acted === 'in-use' && ackOf().answer === 'in-use' && calls.join() === 'ask' && tabs.length === 1,
            h3Calls + ' / ' + calls.join() + ' ' + JSON.stringify([h3, h3b]));
        // Hand over now, clicked once the watcher put the job back to wait
        // for its tab: that job's wait alone cleared, through the loader, and
        // the watcher poked - never chatqrun -Now's wake, which forgets every
        // wait of every lane
        const inUseRs = { jobId: JOB, seq: 15, title: 'T', sessionId: SID };
        const waiting = () => putJob({ state: 'queued', deferWhy: 'in-use', deferUntil: new Date(Date.now() + 60000).toISOString() });
        const handOverAgain = async () => { putJob({}); putRs({}); tabs.length = 0; frontTab(); return runOnce(); };
        resetRun();
        waiting();
        putRs({ phase: 'ended', state: 'queued' });
        answer = 'Hand over now';
        const h4 = await ext._askHandOver(inUseRs);
        answer = undefined;
        const h4Ps = psCmds.slice();
        const h4b = await handOverAgain();
        check('handover: Hand over now - only that job\'s wait cleared, while it still waits for its tab, and the watcher poked, through the tool folder\'s loader; the next handover of that job goes ahead in front of you',
            h4 === 'asked' && h4Ps.length === 1 && h4Ps[0].includes("$j = Find-ChatqJob '" + JOB + "' -Exact") && h4Ps[0].includes("$j.state -eq 'queued'") &&
            h4Ps[0].includes("(Get-ChatField $j 'deferWhy') -eq 'in-use'") && h4Ps[0].includes("Set-ChatqProp $j 'deferUntil' $null; Save-ChatqJob $j") &&
            h4Ps[0].includes('Request-ChatqWatcher -Wake poke') && !/-Wake now/.test(h4Ps[0]) && h4Ps[0].endsWith(' @ ' + path.join(rt, 'Charlie-and-the-chat-factory.ps1')) &&
            h4b.acted === 'closing' && ackOf().answer === 'closing' && calls.includes('close:T'),
            JSON.stringify([h4, h4b]) + ' ' + h4Ps.join(' | ') + ' ' + calls.join());
        // a notice left in the notification centre, clicked after its job
        // moved on - handed over, or ended: nothing run, and the job's later
        // handover keeps the rule; the same where the watcher finds it so
        resetRun();
        putJob({ state: 'done' });
        answer = 'Hand over now';
        const h4c = await ext._askHandOver(inUseRs);
        answer = undefined;
        const h4cPs = psCmds.length;
        const h4d = await handOverAgain();
        resetRun();
        waiting();
        psHandAnswer = 'handover: not waiting';
        answer = 'Hand over now';
        const h4e = await ext._askHandOver(inUseRs);
        answer = undefined;
        psHandAnswer = 'handover: now';
        const h4f = await handOverAgain();
        check('handover: Hand over now clicked on a notice gone stale - nothing run, and the job\'s next handover in front of you still waits; the job no longer waiting by the watcher\'s word - the same',
            h4c === 'stale' && h4cPs === 0 && h4d.acted === 'in-use' && !calls.includes('close:T') &&
            h4e === 'stale' && h4f.acted === 'in-use' && ackOf().answer === 'in-use',
            JSON.stringify([h4c, h4cPs, h4d, h4e, h4f]));
        resetRun();
        putJob({});
        putRs({});
        frontTab();
        stub.window.state.focused = false;
        // a Show it offered here before and not taken: the view it was for
        // goes with the tab
        ext._unshown.set(SID, { id: 'h5-ran', kind: 'ran', sessionId: SID });
        const h5 = await runOnce();
        const h5Calls = calls.join(), h5Recs = recs(), h5Unshown = ext._unshown.has(SID);
        resetRun();
        putJob({});
        putRs({ away: true });
        frontTab();
        const h5b = await runOnce();
        check('handover: the tab shown but nobody at it - its live view opened in its group first, then the tab closed; the record kept; away, in front of you - the same, the view taking the focus',
            h5.acted === 'closing' && h5Calls === 'watch:1:pf,close:T' && h5Recs.length === 1 && h5Recs[0].jobId === JOB && h5Recs[0].sessionId === SID &&
            h5Recs[0].viewColumn === 1 && h5Recs[0].wasVisible === true && !h5Recs[0].restored &&
            h5b.acted === 'closing' && calls.join() === 'watch:1,close:T' && tabs.length === 1 && ext._isWatchTab(tabs[0]),
            h5Calls + ' / ' + calls.join() + ' ' + JSON.stringify(h5Recs));
        check('handover: the tab closed forgets a Show it offered for it and not taken - the chat comes back from disk', !h5Unshown, String(h5Unshown));
        resetRun();
        putJob({});
        putRs({});
        tabs.push(claudeTab(SID, 'T'), note());
        active.tab = tabs[1];
        answer = 'Watch';
        const h6 = await runOnce();
        await settle();
        answer = undefined;
        check('handover: a tab behind others - closed, no live view put over what is shown there; said, and Watch opens it',
            h6.acted === 'closing' && calls.join() === 'close:T,ask,watch:1' && asked[0] === ext._texts.handedBack(rsT) && recs()[0].wasVisible === false,
            calls.join() + ' ' + asked.join(' | '));
        resetRun();
        regR([[999601, { status: 'busy' }]]);
        putJob({});
        putRs({ home: homeR });
        frontTab();
        stub.window.state.focused = false;
        const h7 = await runOnce();
        const h7Calls = calls.join();
        resetRun();
        putJob({});
        putRs({ hostPids: [999991] });
        frontTab();
        const h7b = await runOnce();
        const h7bAck = ackOf();
        resetRun();
        putJob({ state: 'failed' });
        putRs({});
        frontTab();
        const h7c = await runOnce();
        check('handover: the chat working by the registry - in-use, nothing said; another window\'s handover, or one whose job is not running - not answered here, nothing done',
            h7.acted === 'in-use' && h7Calls === '' && h7b.acted === null && h7bAck === null && h7c.acted === null && ackOf() === null && calls.join() === '',
            [h7Calls, JSON.stringify([h7, h7b, h7c])].join(' '));
        // no handover at all: a background command the chat started still
        // runs, and the watcher runs beside its tab - closing it would end
        // that command
        resetRun();
        putJob({});
        const hbId = putRs({ phase: 'running', beside: 'background', handoverId: null });
        frontTab();
        const hb = await runOnce();
        const hbCalls = calls.join(), hbAsked = asked.slice();
        // the same write looked at again, as the timer does: nothing more
        const hbAgain = await runOnce();
        const hbAgainCalls = calls.join();
        // the job back in the queue at the limit, and run again beside the
        // tab: a new run, said again - its live view, open already, left
        putRs({ phase: 'running', beside: 'background', handoverId: null });
        const hb2 = await runOnce();
        check('a run beside its tab, for a background command the chat runs: the tab left open, its live view beside it, the old view said stale - once a run, and again for the job\'s next run',
            hb.acted === 'beside' && hbCalls === 'watch:-2:pf,warn' && hbAsked[0] === ext._texts.besideStale(rsT) && tabs.some(t => ext._isClaudeTab(t) && t.label === 'T') &&
            !hbCalls.includes('close:') && ackOf() === null && hbAgain.acted === null && hbAgainCalls === hbCalls &&
            hb2.acted === 'beside' && calls.join() === hbCalls + ',warn' && ext._runOf({ id: hbId, handoverId: null }) === hbId,
            hbCalls + ' / ' + calls.join() + ' ' + JSON.stringify([hb, hbAgain, hb2]));

        // the run's end: the chat put back
        const handOver = async (x) => {
            resetRun();
            putJob({});
            putRs(x || {});
            frontTab();
            stub.window.state.focused = false;
            await runOnce();
            return panels[0];
        };
        const endIt = async (job, rs) => {
            putJob(Object.assign({ state: 'done', endedAt: new Date().toISOString() }, job));
            putRs(Object.assign({ phase: 'ended', state: 'done' }, rs));
            calls.length = 0;
            openArgs.length = 0;
            asked.length = 0;
            const r = await runOnce();
            await drain();
            return r;
        };

        // A late answer: the watcher stopped listening - run-state moved on to
        // the run beside the tab, or the handover is older than the watcher
        // waits for answers. Nothing written, nothing closed, and no word that
        // the job waits: it runs.
        resetRun();
        putJob({});
        putRs({});
        const lateRs = ext._readRunState();
        putRs({ phase: 'running', beside: 'unsure', handoverId: lateRs.id });
        frontTab();
        const l1 = await ext._onHandover(context, lateRs);
        await settle();
        const l1Calls = calls.join();
        stub.window.state.focused = false;
        const l2 = await ext._onHandover(context, lateRs);
        await settle();
        const l2Calls = calls.join(), l2Tabs = tabs.length, l2Recs = recs().length;
        resetRun();
        putJob({});
        putRs({ at: new Date(Date.now() - 10000).toISOString() });
        frontTab();
        stub.window.state.focused = false;
        const l3 = await runOnce();
        check('handover: an answer come late - the watcher gone on beside the tab, or its handover older than it listens for - nothing written, no tab closed, no word that the job waits',
            l1 === 'late' && l1Calls === '' && l2 === 'late' && l2Calls === '' && l2Tabs === 1 && l2Recs === 0 &&
            l3.acted === 'late' && ackOf() === null && calls.join() === '' && tabs.length === 1 && logged.some(l => /late - the watcher went on without it/.test(l)),
            JSON.stringify([l1, l1Calls, l2, l2Calls, l3, calls.join(), ackOf()]));
        // the run beside this window's view of the chat: the handover unsure,
        // or timed out - the old view said stale, once a run: a write of
        // the same run - its handoverId - says nothing more
        resetRun();
        putJob({});
        // its handover gone by before this window looked
        const l4Id = putRs({});
        putRs({ phase: 'running', beside: 'unsure', handoverId: l4Id });
        frontTab();
        const l4 = await runOnce();
        const l4Calls = calls.join(), l4Asked = asked.slice();
        putRs({ phase: 'running', beside: 'unsure', handoverId: l4Id });
        const l5 = await runOnce();
        const pT = await handOver();
        const pTId = ext._readRunState().id;
        calls.length = 0;
        asked.length = 0;
        putRs({ phase: 'running', beside: 'timed-out', handoverId: pTId });
        const l6 = await runOnce();
        const l6Calls = calls.join(), l6Asked = asked.slice(), l6Kept = !!pT && !pT.disposed && pT.revealed.length === 0;
        resetRun();
        putJob({});
        const l7Id = putRs({});
        await runOnce();
        const l7Calls = calls.join();
        putRs({ phase: 'running', beside: 'unsure', handoverId: l7Id });
        const l7 = await runOnce();
        const l7After = calls.join();
        // that job back in the queue at the limit, then run again beside the
        // tab: its next run, a handover of its own - said again, the live
        // view open already left where it is (its handover gone by unseen)
        const l8Id = putRs({});
        putRs({ phase: 'running', beside: 'unsure', handoverId: l8Id });
        const l8 = await runOnce();
        check('a run beside its tab after a handover unsure or timed out: the old view said stale, its live view beside - one open already left where it is; once a run, the handover\'s own word counting',
            l4.acted === 'beside' && l4Calls === 'watch:-2:pf,warn' && l4Asked[0] === ext._texts.handoverStale(rsT) && l5.acted === 'said' &&
            l6.acted === 'beside' && l6Calls === 'warn' && l6Asked[0] === ext._texts.handoverStale(rsT) && l6Kept &&
            l7Calls === 'watch:-2:pf,warn' && l7.acted === 'said' && l7After === l7Calls,
            JSON.stringify([l4, l4Calls, l4Asked, l5, l6, l6Calls, l6Asked, l6Kept, l7Calls, l7, l7After]));
        check('and the same job run beside the tab again, after the limit: a new run - the old view said stale again',
            l8.acted === 'beside' && calls.join() === l7Calls + ',warn' && asked[asked.length - 1] === ext._texts.handoverStale(rsT),
            JSON.stringify([l8, calls.join()]));

        const p1 = await handOver();
        p1.active = true;
        const e1 = await endIt({});
        const e1Calls = calls.join(), e1Cols = openArgs.map(a => a[2]).join(), e1Recs = recs();
        const ranReq = { id: 'ran-e1', kind: 'ran', jobId: JOB, seq: 15, sessionId: SID, title: 'T', cwd: projA, hostPids: [process.pid], oldProcess: 'none', away: false, busy: false, at: new Date().toISOString() };
        asked.length = 0;
        calls.length = 0;
        const e1ran = await ext._offer(context, ranReq, file);
        check('the end: its live view in front - the chat opened in the view\'s place, loaded from disk, then the view closed; the record kept as put back',
            JSON.stringify(e1.restored) === '["new"]' && e1Calls === OPEN + ',' + UNLOCK + ',dispose:watch' && e1Cols === '1' && p1.disposed &&
            e1Recs.length === 1 && !!e1Recs[0].restored, e1Calls + ' ' + e1Cols + ' ' + JSON.stringify([e1, e1Recs]));
        check('and the run\'s own request after it, naming the job: taken as seen, nothing asked - the end already put the chat back',
            e1ran === 'handed over' && calls.join() === '' && asked.length === 0 && state['chatManagerReload.lastSeenId'] === 'ran-e1', e1ran + ' ' + calls.join());
        const e1again = await runOnce();
        check('and put back once: a later look does nothing more', JSON.stringify(e1again.restored) === '[]' && calls.join() === '', JSON.stringify(e1again));
        const p2 = await handOver();
        const e2 = await endIt({});
        // looked at before the next handover, whose start closes every view
        const e2Calls = calls.join(), e2Kept = !p2.disposed;
        const p3 = await handOver();
        const e3 = await endIt({}, { away: true });
        check('the end: its live view not in front, you here - the view stays, showing the end with Open chat; nobody at the PC - the chat in its place',
            JSON.stringify(e2.restored) === '["shown"]' && e2Calls === '' && e2Kept &&
            JSON.stringify(e3.restored) === '["new"]' && calls.join() === OPEN + ',' + UNLOCK + ',dispose:watch' && p3.disposed,
            e2Calls + ' / ' + calls.join() + ' ' + JSON.stringify([e2, e3]));
        const p4 = await handOver();
        p4.dispose();
        const e4 = await endIt({ state: 'failed', result: { reason: 'cancelled' } });
        check('the end, its live view closed already, you here: asked, Open chat - cancelled or failed alike', JSON.stringify(e4.restored) === '["asked"]' &&
            asked[0] === ext._texts.ranClosed(rsT) && !calls.includes(OPEN), calls.join() + ' ' + JSON.stringify(e4));
        // the watcher killed mid-run: run-state still says running
        const p5 = await handOver();
        p5.active = true;
        calls.length = 0;
        aliveSet.delete(RUNNER);
        const e5 = await runOnce();
        await drain();
        aliveSet.add(RUNNER);
        check('the end: a watcher that died mid-run - run-state still running, its runner gone - is an end too, and the chat put back',
            JSON.stringify(e5.restored) === '["new"]' && calls.join() === OPEN + ',' + UNLOCK + ',dispose:watch', calls.join() + ' ' + JSON.stringify(e5));
        // the limit mid-run: back in the queue - put back all the same, the
        // view saying when it goes on
        const p6 = await handOver();
        const e6 = await endIt({ state: 'queued', history: [{ at: 'x', state: 'queued', why: 'limited mid-run, continues at 14:05' }], result: { kind: 'limited' } }, { state: 'queued' });
        fire(jobF);
        const v6 = ext._watchViews.get(JOB);
        check('the end at the limit, the job back in the queue: put back as any end - the view says it stopped there, and when it goes on',
            JSON.stringify(e6.restored) === '["shown"]' && !!v6 && /stopped at the limit - back in the queue, continues at 14:05/.test(v6.head) && !p6.disposed &&
            v6.head.includes('data-act="open"'),
            JSON.stringify(e6) + ' ' + (v6 && v6.head));
        // a process holds the chat again by the end - opened mid-run
        await handOver({ home: homeR });
        regR([[999602, {}]]);
        ext._getVerdict = twoChecks(liveV({ oldProcess: 'held', outcome: 'held' }), endedV());
        const e7 = await endIt({}, { home: homeR });
        check('the end, a process holding the chat again by then: nothing opened beside it - Show it, which judges first',
            calls[0] === 'check:judge' && !calls.includes(OPEN) && calls.includes('warn'), calls.join() + ' ' + JSON.stringify(e7));
        regR([]);
        // A question left up in the notification centre holds nothing up: a
        // second job ends while the first one's waits, and its chat is put
        // back. stuck: what would wait on the question for good - 5 s, which
        // only a hang waits out: a look and three drains take some 170 ms,
        // and a busy machine once ran them past the 300 ms this had.
        const stuck = (p) => Promise.race([p, new Promise(r => setTimeout(() => r('stuck'), 5000))]);
        const pA = await handOver();
        pA.dispose();
        const infoWas = stub.window.showInformationMessage;
        let letGoA = null;
        stub.window.showInformationMessage = (m, ...b) => {
            calls.push('ask');
            asked.push(m);
            return m === ext._texts.ranClosed(rsT) ? new Promise(r => { letGoA = () => r(undefined); }) : Promise.resolve(undefined);
        };
        const qA = await stuck(endIt({}));
        const rsU = { jobId: JOB2, seq: 16, sessionId: SID2x, title: 'U' };
        putJob({ seq: 16, sessionId: SID2x, title: 'U' }, JOB2);
        putRs(rsU);
        tabs.push(claudeTab(SID2x, 'U'));
        active.tab = tabs[tabs.length - 1];
        const qB0 = await stuck(runOnce());
        const pB = panels[panels.length - 1];
        pB.active = true;
        putJob({ seq: 16, sessionId: SID2x, title: 'U', state: 'done' }, JOB2);
        putRs(Object.assign({ phase: 'ended', state: 'done' }, rsU));
        calls.length = 0;
        const qB = await stuck(runOnce().then(async r => { await drain(); return r; }));
        const qBCalls = calls.join();
        if (letGoA) letGoA();
        stub.window.showInformationMessage = infoWas;
        await settle();
        check('the end: a question left unanswered - the first job\'s "Open it again?" - holds up no later one: the second job\'s chat put back meanwhile, each record marked once handled',
            qA !== 'stuck' && JSON.stringify(qA.restored) === '["asked"]' && qB0 !== 'stuck' && qB0.acted === 'closing' &&
            qB !== 'stuck' && JSON.stringify(qB.restored) === '["new"]' && qBCalls === OPEN + ',' + UNLOCK + ',dispose:watch' && pB.disposed &&
            recs().length === 2 && recs().every(r => !!r.restored),
            JSON.stringify([qA, qB0, qB, qBCalls, recs()]));
        // A window started again: the watch panel of a run that ended while
        // it was away comes back through the serializer - maybe after the
        // first look at run-state, and a tab behind others only once shown.
        // The chat waits for its panel, and is put back as it comes.
        const p9 = await handOver();
        // the window gone: the panel's view with it, its tab left to come back
        p9.onDispose();
        ext._runClock.activatedAt = Date.now();
        const e9 = await endIt({});
        const e9Recs = recs(), e9Calls = calls.join();
        ext._runClock.activatedAt = 0;
        const e9b = await runOnce();
        tabs.splice(tabs.indexOf(p9.tab), 1);
        const pr9 = stub.window.createWebviewPanel('chatManager.watch', 'x', { viewColumn: 1 }, {});
        pr9.active = true;
        calls.length = 0;
        await ext._watchSerializer(context).deserializeWebviewPanel(pr9, { jobId: JOB });
        await drain();
        check('the end while the window was away: nothing put back before its watch panel is here - a moment after the start, and while its tab waits to come back - then, the panel back and in front, the chat in its place; marked only then',
            JSON.stringify(e9.restored) === '[]' && e9Calls === '' && e9Recs.length === 1 && !e9Recs[0].restored && JSON.stringify(e9b.restored) === '[]' &&
            calls.join() === OPEN + ',' + UNLOCK + ',dispose:watch' && pr9.disposed && !!recs()[0].restored,
            JSON.stringify([e9, e9Calls, e9Recs, e9b]) + ' ' + calls.join());
        // its panel closed before the window went: after the moment, asked
        const p9c = await handOver();
        p9c.dispose();
        ext._runClock.activatedAt = Date.now();
        const e9c = await endIt({});
        ext._runClock.activatedAt = 0;
        const e9d = await runOnce();
        check('and a run whose panel was closed before the window went: put back once the moment after the start is over - asked, the panel gone',
            JSON.stringify(e9c.restored) === '[]' && JSON.stringify(e9d.restored) === '["asked"]' && asked.includes(ext._texts.ranClosed(rsT)),
            JSON.stringify([e9c, e9d]));
        // its watch tab kept by VS Code but never shown again: the chat
        // waits for it tabHold from the run's end, not the record's two
        // days - then put back as for a closed view, the tab left
        const p9e = await handOver();
        p9e.onDispose();
        const e9e = await endIt({});
        const e9eRecs = recs();
        ext._timing.tabHold = 40;
        await new Promise(r => setTimeout(r, 60));
        const e9g = await runOnce();
        ext._timing.tabHold = 600000;
        check('a watch tab kept but never brought back: the chat waits for it tabHold from the run\'s end, then is put back as for a closed view - asked - the tab left where it is',
            JSON.stringify(e9e.restored) === '[]' && !e9eRecs[0].restored &&
            JSON.stringify(e9g.restored) === '["asked"]' && asked.includes(ext._texts.ranClosed(rsT)) && !!recs()[0].restored && tabs.includes(p9e.tab) &&
            logged.some(l => /its watch tab not brought back in 0 s - put back without it/.test(l)),
            JSON.stringify([e9e, e9g, recs()]) + ' ' + logged.join(' | '));
        // that tab shown after the put-back: VS Code brings its panel back,
        // which says how the run ended, with Open chat - nothing opened or
        // put back again
        tabs.splice(tabs.indexOf(p9e.tab), 1);
        const pr9e = stub.window.createWebviewPanel('chatManager.watch', 'x', { viewColumn: 1 }, {});
        calls.length = 0;
        asked.length = 0;
        await ext._watchSerializer(context).deserializeWebviewPanel(pr9e, { jobId: JOB });
        await drain();
        const v9e = ext._watchViews.get(JOB);
        check('and that tab shown after it: its panel back, saying how the run ended, with Open chat - nothing opened, asked or put back again',
            !!v9e && v9e.panel === pr9e && !pr9e.disposed && /class="state ok"/.test(v9e.head) && v9e.head.includes('data-act="open"') &&
            calls.join() === '' && asked.length === 0 && ext._tabWaits.size === 0,
            calls.join() + ' ' + (v9e && v9e.head));
        // the wait ends early: the tab shown before tabHold - its panel back
        // through the serializer - or closed; either way put back once, the
        // wait gone with it
        const p9h = await handOver();
        p9h.onDispose();
        const e9h = await endIt({});
        const e9hWait = ext._tabWaits.has(JOB);
        tabs.splice(tabs.indexOf(p9h.tab), 1);
        const pr9h = stub.window.createWebviewPanel('chatManager.watch', 'x', { viewColumn: 1 }, {});
        pr9h.active = true;
        calls.length = 0;
        await ext._watchSerializer(context).deserializeWebviewPanel(pr9h, { jobId: JOB });
        await drain();
        const e9hCalls = calls.join(), e9hWaitAfter = ext._tabWaits.has(JOB);
        const e9hAgain = await runOnce();
        check('a watch tab brought back before tabHold: the wait ends - the chat put back in the panel\'s place, once, nothing left waiting',
            JSON.stringify(e9h.restored) === '[]' && e9hWait && e9hCalls === OPEN + ',' + UNLOCK + ',dispose:watch' && pr9h.disposed &&
            !e9hWaitAfter && !!recs()[0].restored && JSON.stringify(e9hAgain.restored) === '[]',
            JSON.stringify([e9h, e9hWait, e9hCalls, e9hWaitAfter, e9hAgain]));
        const p9i = await handOver();
        p9i.onDispose();
        const e9i = await endIt({});
        const e9iWait = ext._tabWaits.has(JOB);
        // closed unshown: no panel to come back
        tabs.splice(tabs.indexOf(p9i.tab), 1);
        asked.length = 0;
        const e9j = await runOnce();
        const e9jAgain = await runOnce();
        check('a watch tab closed before tabHold: the wait ends - the chat put back as for a closed view, asked, once, nothing left waiting',
            JSON.stringify(e9i.restored) === '[]' && e9iWait && JSON.stringify(e9j.restored) === '["asked"]' && asked.includes(ext._texts.ranClosed(rsT)) &&
            !ext._tabWaits.has(JOB) && JSON.stringify(e9jAgain.restored) === '[]',
            JSON.stringify([e9i, e9iWait, e9j, e9jAgain]));
        // the clock: from the first look past restoreHold that finds the run
        // over - none while a window just started still waits on the
        // serializer
        const p9k = await handOver();
        p9k.onDispose();
        ext._runClock.activatedAt = Date.now();
        const e9k = await endIt({});
        const e9kWait = ext._tabWaits.has(JOB);
        ext._runClock.activatedAt = 0;
        const t9k = Date.now();
        const e9l = await runOnce();
        const e9lAt = ext._tabWaits.get(JOB);
        check('tabHold counts from the first look past restoreHold that finds the run over: no clock while a window just started waits, one set at the next look',
            JSON.stringify(e9k.restored) === '[]' && !e9kWait && JSON.stringify(e9l.restored) === '[]' && typeof e9lAt === 'number' && e9lAt >= t9k,
            JSON.stringify([e9k, e9kWait, e9l, e9lAt, t9k]));
        // a wait begun after one run of a job, the job run again - back in
        // the queue at the limit, then on - before the tab came back: the
        // next run's end waits tabHold of its own, not what is left of the
        // first
        const p9m = await handOver();
        p9m.onDispose();
        ext._timing.tabHold = 40;
        const e9m = await endIt({});
        const e9mWait = ext._tabWaits.has(JOB);
        putJob({});
        putRs({ phase: 'running' });
        await runOnce();
        const e9mRunWait = ext._tabWaits.has(JOB);
        await new Promise(r => setTimeout(r, 60));
        const e9n = await endIt({});
        const e9nWait = ext._tabWaits.has(JOB);
        await new Promise(r => setTimeout(r, 60));
        asked.length = 0;
        const e9o = await runOnce();
        ext._timing.tabHold = 600000;
        check('a job run again while its record waits on a watch tab: the wait starts over - the next run\'s end waits tabHold of its own, then is put back',
            JSON.stringify(e9m.restored) === '[]' && e9mWait && !e9mRunWait && JSON.stringify(e9n.restored) === '[]' && e9nWait &&
            JSON.stringify(e9o.restored) === '["asked"]' && asked.includes(ext._texts.ranClosed(rsT)),
            JSON.stringify([e9m, e9mWait, e9mRunWait, e9n, e9nWait, e9o]));

        // the status bar item
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        await runOnce();
        const item = sbItems[sbItems.length - 1] || {};
        const sb1 = [item.shown, item.text, item.tooltip, item.command, item.backgroundColor];
        putJob({ permitWaiting: { tool: 'Bash', until: '2026-09-28T10:05:00Z' } });
        fire(jobF);
        await settle();
        const sb2 = [item.shown, item.text, item.tooltip, item.backgroundColor && item.backgroundColor.id];
        putJob({});
        putRs({ phase: 'running', hostPids: [999991], cwd: path.resolve('/elsewhere') });
        await runOnce();
        const sb3 = item.shown;
        putRs({ phase: 'running', hostPids: [999991] });
        aliveSet.delete(RUNNER);
        await runOnce();
        const sb4 = item.shown;
        aliveSet.add(RUNNER);
        putRs({ phase: 'ended', hostPids: [999991] });
        await runOnce();
        check('status bar: a run into a chat of this window\'s folders - "chatq #15 running", a click watches it; waiting on the phone - said, in the warning colour',
            sb1[0] === true && sb1[1] === '$(play-circle) chatq #15 running' && sb1[2] === 'T - click to watch it live' && sb1[3] === 'chatManager.watchRun' && !sb1[4] &&
            sb2[0] === true && sb2[1] === '$(bell) chatq #15 waits for your answer' && sb2[3] === 'statusBarItem.warningBackground' &&
            sb2[2] === 'T - waits for your answer on the phone: Bash, until ' + wv.hhmm('2026-09-28T10:05:00Z') + ' - click to watch it live',
            JSON.stringify([sb1, sb2]));
        check('status bar: none for another folder\'s run, for one whose watcher is gone, or once it ended', sb3 === false && sb4 === false && item.shown === false,
            [sb3, sb4, item.shown].join());

        // the panel itself: the log, the page's messages, its buttons
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        fs.writeFileSync(logF, wLines.join('\n'));
        const wv1 = ext._openWatch(JOB, {});
        const pw1 = panels[0];
        const wv1b = ext._openWatch(JOB, { viewColumn: 1 });
        pw1.onMsg({ type: 'ready' });
        await settle();
        const first = pw1.posted[0] || {};
        check('the panel: one per job - a second open brings it forward; once the page is ready, every row, the header, the pinned todo',
            panels.length === 1 && wv1b === wv1 && pw1.revealed.length === 1 && first.reset === true && first.rows.length === wItems.length &&
            first.running === true && first.pin === 'Now: Fixing the parser (3/4)' && first.head.includes('#15 · T') &&
            first.head.includes('fix the parser\nand the tests\nline three') && !first.head.includes('line four') && !first.head.includes('chatq:'),
            JSON.stringify([panels.length, first.reset, first.rows && first.rows.length, first.pin, first.head]));
        // the log's last line ended already: the newline written first comes
        // as a blank line of its own, which makes no row and sends nothing
        fs.appendFileSync(logF, '\n{"type":"assistant","message":{"content":[{"type":"text","text":"more');
        fire(logF);
        const nPart = pw1.posted.length;
        fs.appendFileSync(logF, ' to come"}]}}\n');
        fire(logF);
        const next = pw1.posted[pw1.posted.length - 1] || {};
        check('the panel: the log tailed - a line not yet whole is not shown; once it is, that row alone goes to the page',
            nPart === 1 && pw1.posted.length === 2 && !next.reset && next.rows.length === 1 && next.rows[0].html.includes('more to come'),
            nPart + ' ' + pw1.posted.length + ' ' + JSON.stringify(next.rows));
        // the first read of a long log: its last part only
        putJob({}, JOB2);
        const longLines = [];
        for (let i = 0; i < 20; i++) longLines.push(JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'row ' + i + ' ' + 'x'.repeat(60) }] } }));
        fs.writeFileSync(path.join(rdata, 'logs', JOB2 + '.jsonl'), longLines.join('\n') + '\n');
        ext._watchIo.firstRead = 500;
        const wv2 = ext._openWatch(JOB2, {});
        ext._watchIo.firstRead = 2 * 1024 * 1024;
        const texts2 = wv2.parser.items.map(i => i.text);
        check('the panel: a long log read from its last part - the line cut in two left out - and the header says so',
            wv2.cut === true && texts2.length > 0 && texts2.length < 20 && /^row 19 /.test(texts2[texts2.length - 1]) && texts2.every(t => /^row \d+ x+$/.test(t)) &&
            wv2.head.includes('the log\'s last 2 MB'), texts2.length + ' ' + wv2.head);
        // the watcher runs one job at a time: the long log's job is over, or
        // it would read as a second run going into the chat (runningJobFor)
        putJob({ state: 'done' }, JOB2);
        // A job set running before run-state says so - the seconds of its
        // handover: taken for the run going in, so nothing opens the chat
        {
            const JOB3 = '20260928-101700-3333', DEAD = 999599;
            const t0 = Date.now();
            // the block's own job alone runs meanwhile; JOB as it was after
            const jobWas = fs.readFileSync(jobF);
            putJob({ state: 'done' });
            putRs({ phase: 'ended', jobId: JOB, at: new Date(t0 - 30000).toISOString() });
            putJob({ seq: 17, state: 'running', startedAt: new Date(t0 - 5000).toISOString() }, JOB3);
            const gap = ext._liveRunFor(SID);
            aliveSet.delete(DEAD);
            putJob({ seq: 17, state: 'running', runnerPid: DEAD }, JOB3);
            const deadRunner = ext._liveRunFor(SID);
            putJob({ seq: 17, state: 'running', startedAt: new Date(t0 - 60000).toISOString() }, JOB3);
            putRs({ phase: 'ended', jobId: JOB3, at: new Date(t0 - 30000).toISOString() });
            const behind = ext._liveRunFor(SID);
            putJob({ seq: 17, state: 'running', startedAt: new Date(t0 - 5000).toISOString() }, JOB3);
            const retry = ext._liveRunFor(SID);
            const other = ext._liveRunFor(SID2x);
            putJob({ seq: 17, state: 'done' }, JOB3);
            fs.writeFileSync(jobF, jobWas);
            check('a job set running before run-state says so - its handover\'s seconds - is the run going in; not with its watcher gone, not a file behind a run-state end of that job, though a later try of it is; not for another chat',
                !!gap && gap.jobId === JOB3 && gap.seq === 17 && deadRunner === null && behind === null && !!retry && retry.jobId === JOB3 && other === null,
                JSON.stringify([gap, deadRunner, behind, retry, other]));
        }
        // Cancel: VS Code's own modal, then Stop-ChatqJobRun through the loader
        const warnWas = stub.window.showWarningMessage;
        const modal = [];
        stub.window.showWarningMessage = async (m, ...b) => { modal.push(b[0]); return warnWas(m, ...b); };
        warnAnswer = undefined;
        psCmds.length = 0;
        const c1 = await ext._onWatchMessage(wv1, { type: 'cancel' });
        const c1Ps = psCmds.length;
        warnAnswer = 'Stop the run';
        const c2 = await ext._onWatchMessage(wv1, { type: 'cancel' });
        stub.window.showWarningMessage = warnWas;
        warnAnswer = undefined;
        check('the panel: Cancel asks in a modal of VS Code\'s own - not now stops nothing; Stop the run runs Stop-ChatqJobRun on that job, as the console\'s Stop does',
            c1 === 'kept' && c1Ps === 0 && modal.length === 2 && modal.every(o => o && o.modal === true) && c2 === 'cancelling' && psCmds.length === 1 &&
            psCmds[0].includes("$j = Find-ChatqJob '" + JOB + "' -Exact") && psCmds[0].includes('Stop-ChatqJobRun $j'), [c1, c2].join() + ' ' + psCmds.join(' | '));
        calls.length = 0;
        const lg = await ext._onWatchMessage(wv1, { type: 'log' });
        check('the panel: Log opens the job\'s log', lg === 'log' && calls.join() === 'vscode.open', calls.join());
        // the end, and Open chat: in the view's place
        putJob({ state: 'done' });
        fire(jobF);
        const endHead = wv1.head;
        calls.length = 0;
        openArgs.length = 0;
        const oc = await ext._onWatchMessage(wv1, { type: 'open' });
        await drain();
        check('the panel: once the run ended, Open chat, no Cancel - the chat opened in the view\'s place, and the view closed',
            endHead.includes('data-act="open"') && !endHead.includes('data-act="cancel"') && oc === 'new' && calls.join() === OPEN + ',' + UNLOCK + ',dispose:watch' &&
            openArgs[0][2] === 1 && pw1.disposed && !ext._watchViews.has(JOB), oc + ' ' + calls.join() + ' ' + endHead);
        putJob({ state: 'done', provider: 'codex' });
        const wvc = ext._openWatch(JOB, {});
        const occ = await ext._onWatchMessage(wvc, { type: 'open' });
        check('the panel: no Open chat for a Codex chat, which no Claude tab shows', occ === 'none' && !wvc.head.includes('data-act="open"'), occ + ' ' + wvc.head);
        // a continue sends "continue", not its prompt file; a prompt file
        // named with a path is never read
        putJob({ kind: 'continue' });
        fire(jobF);
        const contHead = wvc.head;
        check('the panel: a continue headed as one - never its prompt file; a prompt file naming a path is not read',
            /continue \(after the limit\)/.test(contHead) && !contHead.includes('fix the parser') &&
            ext._promptOf({ kind: 'prompt', retryAs: 'continue', promptFile: '#15 T.md' }) === 'continue (after the limit)' &&
            ext._promptOf({ kind: 'prompt', promptFile: '..\\..\\x.md' }) === '' && ext._promptOf({ kind: 'prompt', promptFile: '#15 T.md' }).startsWith('fix the parser'),
            contHead);
        // a pasted log line of megabytes: the header goes to the page with
        // every row the log gains
        const promptHead = '<!-- chatq: prompt for \'T\' (claude). Everything after this comment is sent -->\n\n';
        fs.writeFileSync(path.join(rdata, 'queue', '#16 big.md'), promptHead + '{"k":"' + 'v'.repeat(2 * 1024 * 1024) + '"}\nsecond\n');
        fs.writeFileSync(path.join(rdata, 'queue', '#17 wide.md'), promptHead + 'first ' + 'u'.repeat(500) + '\nsecond ' + 'w'.repeat(500) + '\nthird\nfourth\n');
        const readWas = fs.readSync;
        let promptRead = 0;
        fs.readSync = function () { const n = readWas.apply(fs, arguments); promptRead += n; return n; };
        let bigPrompt;
        try { bigPrompt = ext._promptOf({ kind: 'prompt', promptFile: '#16 big.md' }); } finally { fs.readSync = readWas; }
        const wideLines = ext._promptOf({ kind: 'prompt', promptFile: '#17 wide.md' }).split('\n');
        check('the panel: a prompt of megabytes on one line - only the file\'s first few KB read, and each of its first lines cut at 300 characters',
            bigPrompt === '{"k":"' + 'v'.repeat(294) + '...' && promptRead > 0 && promptRead <= ext._promptIo.bytes &&
            wideLines.length === 3 && wideLines[0] === 'first ' + 'u'.repeat(294) + '...' && wideLines[1] === 'second ' + 'w'.repeat(293) + '...' && wideLines[2] === 'third',
            promptRead + ' ' + String(bigPrompt).length + ' ' + wideLines.map(l => l.length).join());
        check('openCall: a column given - the one the chat is put back in - goes to editor.open',
            JSON.stringify(ext._openCall(SID, 2)) === JSON.stringify([OPEN, SID, null, 2, null, false, { programmatic: 'pin-to-panel' }]), JSON.stringify(ext._openCall(SID, 2)));
        // a window reload brings the panel back, by the job id in its state
        resetRun();
        putJob({});
        const ser = ext._watchSerializer();
        const pr = stub.window.createWebviewPanel('chatManager.watch', 'x', { viewColumn: 1 }, {});
        await ser.deserializeWebviewPanel(pr, { jobId: JOB });
        const pbad = stub.window.createWebviewPanel('chatManager.watch', 'x', { viewColumn: 1 }, {});
        await ser.deserializeWebviewPanel(pbad, { jobId: '../../x' });
        check('the panel after a window reload: brought back for its job, fed again; one whose state names no job closed',
            ext._watchViews.has(JOB) && ext._watchViews.get(JOB).panel === pr && /<script nonce=/.test(pr.webview.html) && pbad.disposed,
            ext._watchViews.has(JOB) + ' ' + pbad.disposed);

        // the ways in: the command, the chip's watch, the chip's open, the picker, Show it
        resetRun();
        putJob({});
        putRs({ phase: 'ended' });
        const wr1 = ext._watchRun();
        const wr1Asked = asked.slice();
        putRs({ phase: 'running', hostPids: [999991] });
        const wr2 = ext._watchRun();
        check('Watch the running queued prompt: none running - said; one running - its live view',
            wr1 === 'none' && wr1Asked[0] === ext._texts.noRun && wr2 === 'watch' && panels.length === 1, wr1 + ' ' + wr2 + ' ' + wr1Asked.join());
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        const wOpen = (id, x) => fs.writeFileSync(ofile, JSON.stringify(Object.assign({ id, kind: 'watch', jobId: JOB, seq: 15, sessionId: SID, title: 'T', cwd: projA,
            home: null, hostPids: [], at: new Date().toISOString() }, x)));
        wOpen('w1');
        const cw1 = await ext._checkOpen(context, ofile, false);
        const cw1Calls = calls.join();
        wOpen('w2', { jobId: undefined });
        const cw2 = await ext._checkOpen(context, ofile, false);
        folders.push({ uri: { fsPath: path.resolve('/work/projB') } });
        wOpen('w3');
        const cw3 = await ext._checkOpen(context, ofile, false);
        folders.pop();
        // where a chat would open (claudeColumn): no Claude tab here, so the
        // active group - ViewColumn.Active, -1
        check('the chip\'s watch: its live view opened, no Claude tab; one naming no job is nothing; a window not exactly its folder leaves it, as for an open',
            cw1 === 'watch' && cw1Calls === 'watch:-1' && cw2 === undefined && cw3 === undefined && state['chatManagerReload.lastOpenId'] === 'w1',
            [cw1, cw1Calls, cw2, cw3].join(' '));
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        const ot = await openT();
        const otCalls = calls.join();
        calls.length = 0;
        const pc = await ext._acceptChat({ sid: SID, cwd: projA, file: path.join(rt, 'none', SID + '.jsonl'), dir: rt, size: 0, mtimeMs: 0 });
        check('the chip\'s open and the picker: a chatq run going into the chat - its live view, looked at before anything else; never a tab mid-run',
            ot === 'watch' && otCalls === 'watch:-1' && pc === 'watch' && calls.join() === '' && !otCalls.includes(OPEN) && logged.includes('pick 11111111: running -> watch'),
            ot + ' ' + otCalls + ' / ' + pc + ' ' + calls.join());
        check('pick: a claude -p registered as interactive with an SDK\'s entrypoint, as 2.1.283 does - running, never a terminal',
            ext._chatState([{ kind: 'interactive', entrypoint: 'sdk-cli', status: 'busy' }]) === 'running' && ext._chatState([{ entrypoint: 'sdk-ts' }]) === 'running');
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        frontTab();
        ext._getVerdict = twoChecks(liveV(), endedV());
        const sw = await ext._showLive(reqT, file);
        const swCalls = calls.join();
        resetRun();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991] });
        ext._getVerdict = twoChecks(liveV({ outcome: 'running', oldProcess: 'held' }), endedV());
        const sw2 = await ext._showIt(reqT, file);
        check('Show it: a chatq run gone into the chat by the time it would open it again - that run\'s live view where the tab was; the first check finding one running - the live view too',
            sw === 'watch' && swCalls === OPEN + ',close:T,check:end,watch:1' && sw2 === 'watch' && calls.join() === 'check:judge,watch:-1', swCalls + ' / ' + sw2 + ' ' + calls.join());
        // a turn begun between the look and the close: the tab stays
        resetRun();
        regR([[999603, { status: 'busy' }]]);
        frontTab();
        ext._getVerdict = twoChecks(liveV(), endedV());
        const sb = await ext._showLive(Object.assign({}, reqT, { home: homeR }), file);
        check('Show it: the chat working by the registry right before the close - not closed, nothing ended under it, and said', sb === 'stale' && !calls.includes('close:T') && !calls.includes('check:end') &&
            logged.includes('Show it 11111111: not closed - it began to work meanwhile'), sb + ' ' + calls.join());

        // --- Ultracode and effort, lost by a reopen ------------------------
        // Ultracode's notices, as Claude Code writes them into the transcript;
        // a claude -p run writes its own exit as it starts
        const ua = (on, ep) => jl({ type: 'attachment', attachment: on ? { type: 'ultra_effort_enter', reminderType: 'full' } : { type: 'ultra_effort_exit' },
            entrypoint: ep, sessionId: SID, timestamp: new Date().toISOString() });
        // /effort's answer, a local_command record, as 2.1.284 wrote it in c303a4d5
        const lc = (text, ep, x) => jl(Object.assign({ type: 'system', subtype: 'local_command', content: '<local-command-stdout>' + text + '</local-command-stdout>',
            level: 'info', isMeta: false, commandRun: { command: 'effort', args: 'x' }, entrypoint: ep || 'claude-vscode', sessionId: SID, version: '2.1.284', isSidechain: false }, x));
        // an assistant turn, and the level it ran at
        const at = (effort, ep, x) => jl(Object.assign({ type: 'assistant', effort, perTurnEffort: effort, entrypoint: ep || 'claude-vscode', isSidechain: false,
            message: { role: 'assistant', content: [{ type: 'text', text: 'ran at ' + effort }] } }, x));
        const uHead = user('hi', { entrypoint: 'claude-vscode' });
        const uFill = (n) => { let s = ''; for (let i = 0; i < n; i++) s += asst('row ' + i + ' ' + 'y'.repeat(300)); return s; };
        const uDir = path.join(rt, 'ultra');
        fs.mkdirSync(uDir, { recursive: true });
        const uf = (n, text) => { const f = path.join(uDir, n + '.jsonl'); fs.writeFileSync(f, text); return f; };
        // every text /effort answers with that says something of the two
        const MID = ' \u00b7 ';
        const T = {
            ucOn: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays max.',
            ucOnX: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays xhigh.',
            ucOnRemote: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays max. (applied locally \u2014 this remote transport can\'t change the remote session\'s settings)',
            ucOff: 'Ultracode off. Effort stays max.',
            max: 'Set effort level to max (this session only): Maximum capability with deepest reasoning. May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks.',
            highSession: 'Set effort level to high (this session only): Comprehensive implementation',
            highSaved: 'Set effort level to high (saved as your default for new sessions): Comprehensive implementation',
            highOrg: 'Set effort level to high (saved, though your organization starts new sessions on claude-opus-5-5 at xhigh effort): Comprehensive implementation',
            highRemote: 'Set effort level to high (this session only): Comprehensive implementation' + MID + 'Ultracode off',
            capSession: 'Effort \'max\' exceeds the cap for claude-opus-5-5 set by your settings or organization; set to \'xhigh\' instead (this session only): Deeper reasoning',
            capSaved: 'Effort \'max\' exceeds the cap for claude-opus-5-5 set by your settings or organization; set to \'xhigh\' instead (saved as your default for new sessions): Deeper reasoning',
            auto: 'Effort level set to auto',
            autoRemote: 'Effort level set to auto (this session only)' + MID + 'Ultracode off',
            envAuto: 'Effort set to auto for this session, but CLAUDE_CODE_EFFORT_LEVEL=high still controls this session',
            statusOn: 'Current effort level: max (Maximum capability with deepest reasoning)' + MID + 'Ultracode on',
            statusAutoOn: 'Effort level: auto (currently xhigh)' + MID + 'Ultracode on',
            statusOff: 'Current effort level: max (Maximum capability with deepest reasoning)',
            old: 'Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration',
            invalid: 'Invalid argument: max ultracode. Valid options are: low, medium, high, xhigh, max, auto, ultracode [on|off]',
            notApplied: 'Not applied: CLAUDE_CODE_EFFORT_LEVEL=high overrides effort this session, and max is session-only (nothing saved)',
            needs: 'Ultracode needs dynamic workflows enabled (see /config). Valid options are: low, medium, high, xhigh, max, auto'
        };
        // the rules' vector (fixtures/session-vector.json, which
        // make-session-vector.js writes): every answer through effortSaid,
        // every transcript through the reader - at its chunk, and at a small
        // one; a case's budget where it has one
        const vec = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'session-vector.json'), 'utf8'));
        const saysBad = vec.says.filter(s => {
            const o = ext._effortSaid(s.text, s.version);
            return ('ultracode' in o ? o.ultracode : null) !== s.ultracode || ('set' in o) !== s.level || ('set' in o ? o.set : null) !== s.effort;
        });
        check('effort: every /effort answer of the vector read as it says - Ultracode on, off or unsaid, by the version too; a level set, kept only where for this session only; a refusal, nothing',
            vec.says.length > 0 && saysBad.length === 0, saysBad.map(s => s.version + ' ' + s.text.slice(0, 50) + ': ' + JSON.stringify(ext._effortSaid(s.text, s.version))).join(' | '));
        const vDir = path.join(rt, 'vector');
        fs.mkdirSync(vDir, { recursive: true });
        const ioWas = Object.assign({}, ext._sessionIo);
        const casesBad = [];
        try {
            for (const [i, c] of vec.cases.entries()) {
                const f = path.join(vDir, i + '.jsonl');
                fs.writeFileSync(f, c.lines.map(l => (c.pad ? l.split('@PAD@').join('x'.repeat(c.pad)) : l)).join('\n') + '\n', 'utf8');
                for (const chunk of [ioWas.chunk, 777]) {
                    ext._sessionIo.chunk = chunk;
                    ext._sessionIo.budget = c.budget || ioWas.budget;
                    const r = await ext._sessionSettingsIn(f);
                    if (r.ultracode !== c.expect.ultracode || r.effort !== c.expect.effort) casesBad.push(c.name + ' (chunk ' + chunk + '): ' + JSON.stringify(r));
                }
            }
        } finally {
            Object.assign(ext._sessionIo, ioWas);
        }
        check('effort: every transcript of the vector read as it says - at the reader\'s chunk and at 777 bytes alike, within a case\'s budget where it has one',
            vec.cases.length > 0 && casesBad.length === 0, casesBad.join(' | '));
        // a prompt the user typed, as the Claude extension writes it, 20 s
        // after the one before; a queued run's
        let hpAt = Date.parse('2026-09-29T09:00:00.000Z');
        const hp = (content, x) => user(content, Object.assign({ timestamp: new Date(hpAt += 20000).toISOString(), origin: { kind: 'human' }, entrypoint: 'claude-vscode' }, x));
        const rp = (content) => user(content, { timestamp: new Date(hpAt += 20000).toISOString(), entrypoint: 'sdk-cli' });
        const cb = (x) => jl(Object.assign({ type: 'system', subtype: 'compact_boundary', content: 'Conversation compacted', timestamp: new Date(hpAt += 20000).toISOString(),
            entrypoint: 'claude-vscode', isSidechain: false }, x));
        const at0 = '2026-09-29T08:00:00.000Z', ts0 = Date.parse(at0);
        // ts: its time where it has one - at0, or 'other' for any other
        const lineOf = (l) => {
            const r = ext._effortLine(l);
            if (r === undefined) return JSON.stringify('none');
            if (!Number.isFinite(r.ts)) delete r.ts;
            else if (r.ts !== ts0) r.ts = 'other';
            return JSON.stringify(r);
        };
        const lines = [lc(T.max), lc(T.max, 'sdk-cli'), lc(T.ucOn, 'sdk-py'), lc(T.max, 'claude-vscode', { commandRun: { command: 'model', args: 'max' } }), lc(T.invalid),
            at('max'), at('high', 'sdk-ts'), at('high', 'claude-vscode', { isSidechain: true }), ua(true, 'claude-vscode'), ua(false, 'cli'), ua(false, 'sdk-py'),
            '{"type":"attachment","attachment":{"type":"ultra_effort_x"}}', '{"type":"attachment","attachment":{"type":"ultra_effort_enter"',
            hp('why "Set effort level to max (this session only)" in <local-command-stdout>x</local-command-stdout>, local_command, "effort":"max"?', { timestamp: at0 }),
            user('[Request interrupted by user]', { entrypoint: 'claude-vscode' }), user([{ type: 'tool_result', tool_use_id: 't1', content: 'ultra_effort_enter' }], { entrypoint: 'claude-vscode' }),
            user('<command-name>/effort</command-name>', { entrypoint: 'claude-vscode', isMeta: true }), hp('the summary', { isCompactSummary: true }),
            hp('go', { entrypoint: 'sdk-cli' }), hp('go', { isSidechain: true }), cb({ entrypoint: 'sdk-cli', timestamp: at0 })].map(lineOf);
        check('effort: a line\'s kind, and its time where it has one - /effort\'s answer, an assistant turn\'s level, an Ultracode notice, a prompt typed, another user record, a compaction; of a claude -p run\'s only its notices and compactions; none of a subagent\'s, another command\'s, a tool\'s result, a meta record - nor the words in a message',
            lines.join() === ['{"k":"S","set":"max"}', '"none"', '"none"', '"none"', '"none"', '{"k":"A","effort":"max"}', '"none"', '"none"', '{"k":"N","on":true,"own":true,"ts":"other"}',
                '{"k":"N","on":false,"own":true,"ts":"other"}', '{"k":"N","on":false,"own":false,"ts":"other"}', '"none"', '"none"', '{"k":"H","ts":' + ts0 + '}', '{"k":"F"}', '"none"', '"none"', '{"k":"F","ts":"other"}',
                '"none"', '"none"', '{"k":"B","ts":' + ts0 + '}'].join(), lines.join());
        const U = {
            on: uf('on', uHead + ua(true, 'claude-vscode') + uFill(5)),
            sdkExit: uf('sdkexit', uHead + ua(true, 'claude-vscode') + uFill(5) + ua(false, 'sdk-cli') + uFill(3)),
            off: uf('off', uHead + ua(true, 'claude-vscode') + uFill(2) + ua(false, 'claude-vscode') + uFill(2) + ua(true, 'sdk-cli')),
            none: uf('none', uHead + uFill(5)),
            term: uf('term', uHead + ua(false, 'claude-vscode') + ua(true, 'cli')),
            // the word in a message is no switch
            said: uf('said', uHead + ua(false, 'claude-vscode') + user('why "type":"ultra_effort_enter" and {"type":"attachment"}?', { entrypoint: 'claude-vscode' })),
            far: uf('far', uHead + ua(true, 'claude-vscode') + uFill(300) + ua(false, 'sdk-ts') + asst('the last, no newline').trimEnd()),
            lastNoEol: uf('lastnoeol', uHead + uFill(3) + ua(true, 'claude-vscode').trimEnd())
        };
        const uIn = async (f) => ext._ultracodeIn(f);
        const uPlain = [await uIn(U.on), await uIn(U.sdkExit), await uIn(U.off), await uIn(U.none), await uIn(U.term), await uIn(U.said),
            await uIn(U.far), await uIn(U.lastNoEol), await uIn(path.join(uDir, 'missing.jsonl'))];
        check('Ultracode, no prompt typed since: the last notice of the chat\'s own - an enter on, an exit off; a claude -p run\'s exit, or enter, is not the chat\'s and passes; a terminal\'s counts; none, or no file, unknown; the word in a message is no switch',
            JSON.stringify(uPlain) === JSON.stringify([true, true, false, null, true, false, true, true, null]), JSON.stringify(uPlain));
        // the transcripts of the reading rules, prompts typed between: what
        // the chat's own records say, each setting on its own
        const S = {
            // c303a4d5 as it went: Ultracode on at xhigh, max, Ultracode on again
            real: uf('real', hp('a') + at('xhigh') + lc(T.ucOnX) + lc(T.max) + lc(T.ucOn) + hp('b') + ua(true, 'claude-vscode') + at('max') + at('max')),
            ucOnly: uf('uconly', hp('a') + at('xhigh') + lc(T.ucOnX) + hp('b') + ua(true, 'claude-vscode') + at('xhigh')),
            maxOnly: uf('maxonly', hp('a') + at('xhigh') + lc(T.max) + hp('b') + at('max')),
            // the menu set high since: saved, and nothing lost
            menu: uf('menu', lc(T.max) + hp('a') + at('max') + hp('b') + at('high')),
            saved: uf('saved', lc(T.max) + hp('a') + at('max') + lc(T.highSaved) + hp('b') + at('high')),
            // a queued run since, at its own level, Ultracode off in it; and a
            // prompt of the chat's after it, with no notice: off since
            run: uf('run', lc(T.ucOn) + lc(T.max) + hp('a') + ua(true, 'claude-vscode') + at('max') + rp('go') + ua(false, 'sdk-cli') + at('high', 'sdk-cli') + lc(T.ucOff, 'sdk-cli')),
            runThen: uf('runthen', lc(T.ucOn) + lc(T.max) + hp('a') + ua(true, 'claude-vscode') + at('max') + rp('go') + ua(false, 'sdk-cli') + at('high', 'sdk-cli') + hp('b') + at('max')),
            off: uf('offcmd', lc(T.ucOn) + lc(T.max) + hp('a') + ua(true, 'claude-vscode') + at('max') + lc(T.ucOff)),
            exit: uf('exit', lc(T.ucOn) + hp('a') + ua(true, 'claude-vscode') + at('max') + hp('b') + ua(false, 'claude-vscode') + at('xhigh')),
            // a compaction, and a prompt since with no notice: off
            compact: uf('compact', hp('a') + ua(true, 'claude-vscode') + at('xhigh') + cb() + hp('b') + at('xhigh')),
            statusOff: uf('statusoff', hp('a') + ua(true, 'claude-vscode') + at('xhigh') + lc(T.statusOff)),
            statusOn: uf('statuson', hp('a') + at('xhigh') + lc(T.statusOn)),
            old: uf('old', hp('a') + at('xhigh') + lc(T.old, 'claude-vscode', { version: '2.1.283' })),
            cap: uf('cap', lc(T.capSession) + hp('a') + at('xhigh')),
            high: uf('high', lc(T.highSession) + hp('a') + at('high')),
            sidechain: uf('sidechain', lc(T.max) + hp('a') + at('max') + at('high', 'claude-vscode', { isSidechain: true })),
            auto: uf('auto', lc(T.max) + hp('a') + at('max') + lc(T.auto) + hp('b') + at('xhigh')),
            // no turn yet at the level just set: it stands
            fresh: uf('fresh', hp('a') + at('xhigh') + lc(T.max)),
            far: uf('farset', lc(T.ucOn) + lc(T.max) + hp('a') + ua(true, 'claude-vscode') + at('max') + uFill(300))
        };
        const sWant = { real: [true, 'max'], ucOnly: [true, null], maxOnly: [false, 'max'], menu: [false, null], saved: [false, null], run: [true, 'max'], runThen: [false, 'max'],
            off: [false, 'max'], exit: [false, null], compact: [false, null], statusOff: [false, null], statusOn: [true, null], old: [true, null], cap: [false, 'xhigh'],
            high: [false, 'high'], sidechain: [false, 'max'], auto: [false, null], fresh: [false, 'max'], far: [true, 'max'] };
        const sRead = async () => {
            const o = {};
            for (const k of Object.keys(S)) { const r = await ext._sessionSettingsIn(S[k]); o[k] = [r.ultracode, r.effort]; }
            const m = await ext._sessionSettingsIn(path.join(uDir, 'missing.jsonl'));
            o.missing = [m.ultracode, m.effort];
            return o;
        };
        const sAll = await sRead();
        const sExpect = Object.assign({}, sWant, { missing: [null, null] });
        check('effort: the chat\'s own session-only settings - Ultracode by its notice or /effort answer since the last prompt typed, else as that prompt found it: a queued run\'s notice before it counts, a compaction between is off; the level of the latest turn a prompt started, where max, or set by the last /effort before it for the session only; a claude -p run\'s own records passed over',
            JSON.stringify(sAll) === JSON.stringify(sExpect), JSON.stringify(sAll));
        // read backwards in small chunks: lines cut across them put together;
        // and past the budget, given up on - unknown
        ext._sessionIo.chunk = 777;
        const uSmall = [await uIn(U.on), await uIn(U.sdkExit), await uIn(U.off), await uIn(U.said), await uIn(U.far), await uIn(U.lastNoEol)];
        const sSmall = await sRead();
        ext._sessionIo.budget = 20000;
        const uCut = await uIn(U.far);
        const uNear = await uIn(U.sdkExit);
        const sCut = await ext._sessionSettingsIn(S.far);
        ext._sessionIo.chunk = 1024 * 1024;
        ext._sessionIo.budget = 16 * 1024 * 1024;
        check('effort: read backwards in chunks, a line cut across two put together; what is far back found; past the read budget - unknown, so nothing said',
            JSON.stringify(uSmall) === JSON.stringify([true, true, false, false, true, true]) && JSON.stringify(sSmall) === JSON.stringify(sExpect) &&
            fs.statSync(U.far).size > 90000 && uCut === null && uNear === true && sCut.ultracode === null && sCut.effort === null,
            JSON.stringify(uSmall) + ' ' + JSON.stringify(sSmall) + ' ' + uCut + ' ' + uNear + ' ' + JSON.stringify(sCut));

        // bounded by the launch of the chat's current process: a record from
        // before it is an older process's, whose settings died with it
        const tOld = Date.parse('2026-09-28T07:58:45.000Z'), tLaunch = Date.parse('2026-09-30T00:00:00.000Z');
        const iso = (t) => ({ timestamp: new Date(t).toISOString() });
        const enterAt = (t) => jl(Object.assign({ type: 'attachment', attachment: { type: 'ultra_effort_enter', reminderType: 'full' }, entrypoint: 'claude-vscode', sessionId: SID }, iso(t)));
        const BT = {
            // ac284315 as it went: Ultracode in a 2.1.283 process two days
            // back, max set for the session in today's
            stale: uf('bstale', hp('a', iso(tOld)) + enterAt(tOld) + at('xhigh', 'claude-vscode', iso(tOld + 3000)) + lc(T.max, 'claude-vscode', iso(tLaunch + 60000))),
            // Ultracode on in today's process
            fresh: uf('bfresh', hp('a', iso(tOld)) + at('high', 'claude-vscode', iso(tOld + 3000)) + hp('b', iso(tLaunch + 1000)) + enterAt(tLaunch + 1000) +
                at('xhigh', 'claude-vscode', iso(tLaunch + 2000))),
            // nothing of today's process yet
            quiet: uf('bquiet', hp('a', iso(tOld)) + enterAt(tOld) + lc(T.max, 'claude-vscode', iso(tOld + 3000))),
            // a turn of today's process at high
            turned: uf('bturned', hp('a', iso(tOld)) + enterAt(tOld) + hp('b', iso(tLaunch + 1000)) + at('high', 'claude-vscode', iso(tLaunch + 2000)))
        };
        const bRead = async (f, start) => { const r = await ext._sessionSettingsIn(f, start); return [r.ultracode, r.effort]; };
        const L0 = { at: tLaunch, ultracode: false, effort: null }, LUM = { at: tLaunch, ultracode: true, effort: 'max' };
        const bAll = [await bRead(BT.stale), await bRead(BT.stale, L0), await bRead(BT.fresh, L0), await bRead(BT.quiet, L0), await bRead(BT.quiet, LUM),
            await bRead(BT.turned, LUM), await bRead(BT.turned, { at: tLaunch, ultracode: false, effort: 'high' })];
        check('effort: bounded by the launch of the chat\'s process - Ultracode entered in an older one, a level set before: gone, the level set since kept; on since: on; nothing since: what the launch was given; a level it was given, a turn since at another: changed since',
            JSON.stringify(bAll) === JSON.stringify([[true, 'max'], [false, 'max'], [true, null], [false, null], [true, 'max'], [true, null], [false, 'high']]), JSON.stringify(bAll));

        // what a reopen loses, and what goes into the new panel's input box:
        // with chatManager.keepSessionSettings off, as before it was carried
        cfgVals['chatManager.keepSessionSettings'] = false;
        const uChatDir = path.join(homeR, 'projects', ext._chatSlug(projA));
        fs.mkdirSync(uChatDir, { recursive: true });
        const uChat = path.join(uChatDir, SID + '.jsonl');
        const uPut = (f) => fs.copyFileSync(f, uChat);
        const reqU = Object.assign({}, reqT, { cwd: projA, home: homeR });
        const LU = { ultracode: true, effort: null, prefill: '/effort ultracode' };
        const LM = { ultracode: false, effort: 'max', prefill: '/effort max' };
        const LB = { ultracode: true, effort: 'max', prefill: '/effort ultracode' };
        const lostOf = async (f) => { if (f) uPut(f); else fs.rmSync(uChat, { force: true }); return JSON.stringify(await ext._lostByReopen(reqU)); };
        const lostAll = [await lostOf(S.ucOnly), await lostOf(S.maxOnly), await lostOf(S.real), await lostOf(S.high), await lostOf(S.menu), await lostOf(U.off), await lostOf(null)];
        check('effort: the pre-fill - /effort ultracode where Ultracode was on, with or without a session-only level; else /effort <level> for that level alone; nothing lost, or unknown - none',
            lostAll.join(' ') === [JSON.stringify(LU), JSON.stringify(LM), JSON.stringify(LB), JSON.stringify({ ultracode: false, effort: 'high', prefill: '/effort high' }), 'null', 'null', 'null'].join(' '),
            lostAll.join(' '));
        const say = (lost, pre) => ext._texts.settingsLost(reqU, lost, pre);
        const LBH = { ultracode: true, effort: 'high', prefill: '/effort ultracode' };
        const sayU = say(LU, true), sayM = say(LM, true), sayB = say(LB, true), typeU = say(LU, false), typeM = say(LM, false), typeB = say(LB, false);
        const sayBH = say(LBH, true), typeBH = say(LBH, false);
        check('effort: the word - naming the chat and what the reopen lost; pre-filled, what its input box holds and that Enter applies it; both lost, the level after, typed - which leaves Ultracode on; never the effort menu, which would save a level as every new session\'s',
            sayU.startsWith('"T" was opened again without Ultracode: ') && sayU.includes('input box holds /effort ultracode') && /Enter/.test(sayU) && !/menu/.test(sayU) &&
            sayM.startsWith('"T" was opened again without effort max: ') && sayM.includes('input box holds /effort max') && /Enter/.test(sayM) && !/Ultracode/.test(sayM) &&
            sayB.startsWith('"T" was opened again without Ultracode and effort max: ') && sayB.includes('input box holds /effort ultracode') && !/menu/.test(sayB) &&
            sayB.endsWith(' Then type /effort max and press Enter: typed, it leaves Ultracode on.') && /leaves Ultracode on/.test(sayB) &&
            sayBH.startsWith('"T" was opened again without Ultracode and effort high: ') && !/menu/.test(sayBH) &&
            sayBH.endsWith(' Then type /effort high and press Enter: typed, it leaves Ultracode on.'),
            [sayU, sayM, sayB, sayBH].join(' | '));
        check('effort: the word where no pre-fill could go - the commands named to type, nothing said to be in the box',
            typeU.includes('Type /effort ultracode') && !/holds/.test(typeU) && typeM.includes('Type /effort max') && !/holds/.test(typeM) &&
            typeB.includes('Type /effort ultracode') && typeB.endsWith(', then type /effort max and press Enter: typed, it leaves Ultracode on.') && !/menu/.test(typeB) && !/holds/.test(typeB) &&
            typeBH.endsWith(', then type /effort high and press Enter: typed, it leaves Ultracode on.') && !/menu/.test(typeBH),
            [typeU, typeM, typeB, typeBH].join(' | '));
        // the key that sends there: Ctrl+Enter - Cmd+Enter on a Mac - where
        // the Claude extension's useCtrlEnterToSend is on
        const platformWas = Object.getOwnPropertyDescriptor(process, 'platform');
        const keyed = (on, platform) => {
            if (on === undefined) delete cfgVals['claudeCode.useCtrlEnterToSend']; else cfgVals['claudeCode.useCtrlEnterToSend'] = on;
            Object.defineProperty(process, 'platform', Object.assign({}, platformWas, { value: platform }));
            asked.length = 0;
            ext._sayLost(reqU, LB, true);
            return asked.join(' | ');
        };
        const keys = [];
        try {
            keys.push(keyed(true, 'win32'), keyed(true, 'darwin'), keyed(false, 'darwin'), keyed(undefined, 'linux'));
        } finally {
            Object.defineProperty(process, 'platform', platformWas);
            delete cfgVals['claudeCode.useCtrlEnterToSend'];
        }
        check('effort: the key the word names - Ctrl+Enter where the Claude extension sends with it, Cmd+Enter on a Mac; else Enter',
            keys[0] === sayB.split('Enter').join('Ctrl+Enter') && keys[1] === sayB.split('Enter').join('Cmd+Enter') && keys[2] === sayB && keys[3] === sayB &&
            process.platform === platformWas.value, keys.join(' || '));
        // the prompt every open was given, as the Claude extension got it
        const prompts = () => openArgs.map(a => (a[1] === undefined ? null : a[1]));
        const noticed = () => asked.filter(m => / was opened again without /.test(m));
        const quiet = async () => { resetRun(); putJob({ state: 'done' }); putRs({ phase: 'ended' }); };
        // openCall, openOnce, openWith: the prompt as editor.open's second
        // argument, primaryEditor.open's too; kept through a fallback and a retry
        reset();
        const ocP = JSON.stringify(ext._openCall(SID, 2, '/effort max'));
        claudeVer = '2.1.280';
        const ocOld = JSON.stringify(ext._openCall(SID, undefined, '/effort max'));
        reset();
        fail[OPEN] = 1;
        await ext._openOnce(SID, undefined, '/effort ultracode');
        const fbArgs = JSON.stringify(openArgs);
        reset();
        fail[OPEN] = 1;
        fail[OPEN_FULL] = 1;
        const owOk = await ext._openWith(SID, undefined, '/effort max');
        check('the open with a prompt: editor.open\'s second argument, and primaryEditor.open\'s - where an old Claude extension takes that one, or editor.open was refused; the retry keeps it',
            ocP === JSON.stringify([OPEN, SID, '/effort max', 2, null, false, { programmatic: 'pin-to-panel' }]) && ocOld === JSON.stringify([OPEN_FULL, SID, '/effort max']) &&
            fbArgs === JSON.stringify([[SID, '/effort ultracode', -1, null, false, { programmatic: 'pin-to-panel' }], [SID, '/effort ultracode']]) &&
            owOk === true && prompts().join() === '/effort max,/effort max,/effort max',
            ocP + ' ' + ocOld + ' ' + fbArgs + ' ' + owOk + ' ' + prompts().join());
        // Show it: its tab closed, the process gone, the chat opened again -
        // the second open, sure of a new panel, takes the pre-fill
        const uShow = async (f) => {
            await quiet();
            uPut(f);
            frontTab();
            ext._getVerdict = twoChecks(liveV(), endedV());
            const r = await ext._showLive(reqU, file);
            return JSON.stringify([r, prompts(), noticed()]);
        };
        const us = [await uShow(U.sdkExit), await uShow(S.maxOnly), await uShow(S.real), await uShow(U.off), await uShow(U.none)];
        check('effort: Show it\'s close and reopen - the reopen alone given the pre-fill, said once: Ultracode (a claude -p run\'s exit since passed over), effort max, both; off, or none recorded - no prompt, nothing said',
            us.join(' ') === [JSON.stringify(['reopened', [null, '/effort ultracode'], [sayU]]), JSON.stringify(['reopened', [null, '/effort max'], [sayM]]),
                JSON.stringify(['reopened', [null, '/effort ultracode'], [sayB]]), JSON.stringify(['reopened', [null, null], []]), JSON.stringify(['reopened', [null, null], []])].join(' '),
            us.join(' '));
        // a new tab where a process of this window held the chat outside the
        // tabs - Show it's, or a plan's tab: its open was not sure of a new
        // panel, so no prompt, and the commands named instead
        const uNew = async (f, run) => { await quiet(); uPut(f); const r = await run(); return JSON.stringify([r, prompts(), noticed(), asked.includes(ext._texts.sideBarStale(reqU))]); };
        ext._getVerdict = twoChecks(liveV(), endedV());
        const un = [await uNew(U.on, () => ext._showLive(reqU, file)), await uNew(U.off, () => ext._showLive(reqU, file)),
            await uNew(S.real, () => ext._perform('tab', Object.assign({}, reqU, { hostPids: [process.pid] }))),
            await uNew(U.off, () => ext._perform('tab', Object.assign({}, reqU, { hostPids: [process.pid] }))),
            await uNew(U.on, () => ext._perform('tab', Object.assign({}, reqU, { hostPids: [] }))),
            await uNew(U.on, () => ext._perform('tab', Object.assign({}, reqU, { hostPids: [999991], oldProcess: 'ended' })))];
        check('effort: a new tab for a chat a process of this window held outside the tabs - Show it\'s, or a run\'s tab - no prompt; the commands to type named where something was lost, beside the side bar\'s copy said stale; off - only that; no process of this window - nothing; one of another window\'s the check ended - the commands named, nothing stale here',
            un.join(' ') === [JSON.stringify(['new', [null], [typeU], true]), JSON.stringify(['new', [null], [], true]), JSON.stringify(['new', [null], [typeB], true]),
                JSON.stringify(['new', [null], [], true]), JSON.stringify(['new', [null], [], false]), JSON.stringify(['new', [null], [typeU], false])].join(' '),
            un.join(' '));
        // Show it the other way: the script ended the process, the stale tab
        // closed and opened again (showTab)
        const uTab = async (f) => {
            await quiet();
            uPut(f);
            tabs.push(claudeTab(SID, 'T'), note());
            active.tab = tabs[1];
            const r = await ext._showTab(reqU);
            return JSON.stringify([r, prompts(), noticed()]);
        };
        const ut = [await uTab(S.maxOnly), await uTab(U.off)];
        check('effort: a stale tab closed and opened again after the script ended its process - the reopen alone given the pre-fill, and said; nothing lost - no prompt, nothing said',
            ut.join(' ') === [JSON.stringify(['reopened', [null, '/effort max'], [sayM]]), JSON.stringify(['reopened', [null, null], []])].join(' '), ut.join(' '));
        // the chat put back after a handover, its run a claude -p's: no
        // process holds it, so the open takes the pre-fill; a Claude tab here
        // reading as the chat is only revealed - no prompt, the commands named
        const uRestore = async (f, keep) => {
            await handOver({ home: homeR });
            if (f) uPut(f); else fs.rmSync(uChat, { force: true });
            if (keep) tabs.push(claudeTab(SID, 'T'));
            panels[0].active = true;
            const e = await endIt({}, { home: homeR });
            return JSON.stringify([e.restored, prompts(), noticed()]);
        };
        const ur = [await uRestore(U.sdkExit), await uRestore(S.real), await uRestore(U.off), await uRestore(null), await uRestore(S.maxOnly, true)];
        check('effort: the chat put back after a handover - the pre-fill given, and said: the run\'s own exit passed over; off, or no transcript - no prompt, nothing said; a tab of it here - no prompt, the commands named',
            ur.join(' ') === [JSON.stringify([['new'], ['/effort ultracode'], [sayU]]), JSON.stringify([['new'], ['/effort ultracode'], [sayB]]), JSON.stringify([['new'], [null], []]),
                JSON.stringify([['new'], [null], []]), JSON.stringify([['revealed'], [null], [typeM]])].join(' '),
            ur.join(' '));
        // the handover's record keeps when the process its close ended began:
        // a transcript all from before that - an older process's - puts
        // nothing back; a host started since - a reload between - does not
        // move it
        const uBound = async (f, hostAtHandover, hostAtRestore) => {
            ext._carryIo.hostStart = hostAtHandover;
            try {
                await handOver({ home: homeR });
                uPut(f);
                ext._carryIo.hostStart = hostAtRestore;
                panels[0].active = true;
                const e = await endIt({}, { home: homeR });
                return JSON.stringify([e.restored, prompts(), noticed()]);
            } finally { ext._carryIo.hostStart = 0; }
        };
        const tLater = Date.parse('2099-01-01T00:00:00.000Z');
        const ub = [await uBound(S.real, tLater, 0), await uBound(S.real, 0, tLater)];
        check('effort: the chat put back after a handover - bounded by the start its record kept: a transcript from before it puts nothing back; a reload since leaves it',
            ub.join(' ') === [JSON.stringify([['new'], [null], []]), JSON.stringify([['new'], ['/effort ultracode'], [sayB]])].join(' '), ub.join(' '));
        // asked, and the answer late: the chat opened by hand meanwhile, a
        // process of it idle - Show it, nothing given or said; still closed -
        // the pre-fill, and said
        const uLate = async (reg) => {
            await handOver({ home: homeR });
            uPut(S.real);
            panels[0].dispose();
            const infoWas = stub.window.showInformationMessage;
            let click = null;
            stub.window.showInformationMessage = (m, ...b) => {
                calls.push('ask');
                asked.push(m);
                return m === ext._texts.ranClosed(rsT) ? new Promise(r => { click = () => r('Open chat'); }) : Promise.resolve(undefined);
            };
            try {
                const e = await endIt({}, { home: homeR });
                regR(reg);
                ext._getVerdict = twoChecks(liveV({ oldProcess: 'held', outcome: 'held' }), endedV());
                calls.length = 0;
                openArgs.length = 0;
                asked.length = 0;
                if (click) click();
                await drain();
                return JSON.stringify([e.restored, calls.includes('check:judge'), calls.includes(OPEN), prompts(), noticed()]);
            } finally {
                stub.window.showInformationMessage = infoWas;
                regR([]);
            }
        };
        const ul = [await uLate([[999605, { status: 'idle' }]]), await uLate([])];
        check('effort: the chat put back, asked, and Open chat clicked late - a process holding it by then: Show it, which judges first, nothing opened beside it, no prompt, nothing said; still none - the pre-fill, and said',
            ul.join(' ') === [JSON.stringify([['asked'], true, false, [], []]), JSON.stringify([['asked'], false, true, ['/effort ultracode'], [sayB]])].join(' '),
            ul.join(' '));
        // the live view's Open chat: the pre-fill only where the registry
        // shows no process of the chat, and no tab here reads as it
        const uWatch = async (f, reg, tab) => {
            await quiet();
            uPut(f);
            putJob({ state: 'done', home: homeR });
            if (reg) regR(reg);
            if (tab) tabs.push(claudeTab(SID, 'T'));
            const w = ext._openWatch(JOB, {});
            calls.length = 0;
            openArgs.length = 0;
            asked.length = 0;
            const r = await ext._onWatchMessage(w, { type: 'open' });
            await drain();
            return JSON.stringify([r, prompts(), noticed(), w.disposed]);
        };
        const uw = [await uWatch(S.real), await uWatch(U.off), await uWatch(S.real, [[999604, { status: 'idle' }]]), await uWatch(S.real, null, true)];
        check('effort: the live view\'s Open chat - no process of the chat: the pre-fill given, and said; nothing lost - none; a process of it idle somewhere - no prompt, nothing said; a Claude tab here reading as it - revealed, no prompt, the commands named',
            uw.join(' ') === [JSON.stringify(['new', ['/effort ultracode'], [sayB], true]), JSON.stringify(['new', [null], [], true]), JSON.stringify(['new', [null], [], true]),
                JSON.stringify(['revealed', [null], [typeB], true])].join(' '),
            uw.join(' '));

        // --- Ultracode and the level carried into the new process ------------
        // chatManager.keepSessionSettings on, as by default. The hook goes into
        // stand-ins of child_process; a new tab's launch is made by hand
        // (onMake), as the Claude extension's SDK makes it
        {
        delete cfgVals['chatManager.keepSessionSettings'];
        ext._removeSpawnHook();
        const fakeSpawn = fakeCp.spawn;
        const launch = (argv, opts) => fakeCp.spawn('claude.exe', argv, opts || { cwd: projA });
        const lastArgs = () => { const a = fakeCp.spawned[fakeCp.spawned.length - 1]; return a ? a[1] : null; };
        const R = '--resume=' + SID;
        const NONE = '{"ultracode":false,"effort":null}';
        // an arm's promise, or 'late': its timer is unref'd, so an arm that
        // never settles would otherwise end the run here
        const within = (p) => Promise.race([p, new Promise(r => setTimeout(() => r('late'), 1000))]);
        const modA = { spawn(...a) { return { self: this, a }; } };
        const origA = modA.spawn;
        const hIn = ext._installSpawnHook(modA);
        const hWrapped = modA.spawn !== origA;
        const hAgain = ext._installSpawnHook(modA);
        const hThrough = modA.spawn('x', ['a', R], { cwd: 'c' });
        const hOut = ext._removeSpawnHook();
        const hBack = modA.spawn === origA;
        ext._installSpawnHook(modA);
        const ours = modA.spawn;
        const theirs = function () { return ours.apply(this, arguments); };
        modA.spawn = theirs;
        const hCovered = ext._removeSpawnHook();
        const hKept = modA.spawn === theirs;
        const frozen = Object.freeze({ spawn() { } });
        const hFrozen = ext._installSpawnHook(frozen);
        check('carry: the spawn hook - in once, as the module\'s spawn; a launch with nothing armed through as it came, its this kept; out, the original back; another hook put over it later - left in place, theirs kept; a module that refuses it - not in',
            hIn === true && hWrapped && hAgain === true && hThrough.self === modA && JSON.stringify(hThrough.a) === JSON.stringify(['x', ['a', R], { cwd: 'c' }]) &&
            hOut === 'removed' && hBack && hCovered === 'covered' && hKept && hFrozen === false && ext._removeSpawnHook() === 'none',
            JSON.stringify([hIn, hWrapped, hAgain, hOut, hBack, hCovered, hKept, hFrozen]));
        // no hook to be had: the pre-fill as before, and an arm carries nothing
        ext._carryIo.mod = frozen;
        const noHook = await Promise.race([ext._armCarry(SID, { ultracode: true, effort: 'max' }), new Promise(r => setTimeout(() => r('late'), 50))]);
        uPut(S.real);
        const planNoHook = JSON.stringify(await ext._lostByReopen(reqU));
        ext._carryIo.mod = fakeCp;
        const planOn = JSON.stringify(await ext._lostByReopen(reqU));
        cfgVals['chatManager.keepSessionSettings'] = false;
        const planOff = JSON.stringify(await ext._lostByReopen(reqU));
        delete cfgVals['chatManager.keepSessionSettings'];
        check('carry: planned - the setting on and the hook in: both lost, nothing to pre-fill; off, or no hook to be had: the pre-fill as before; no hook - an arm carries nothing, at once',
            planOn === JSON.stringify({ ultracode: true, effort: 'max', prefill: null }) && planOff === JSON.stringify(LB) && planNoHook === JSON.stringify(LB) &&
            JSON.stringify(noHook) === NONE && fakeCp.spawn !== fakeSpawn, [planOn, planOff, planNoHook, JSON.stringify(noHook)].join(' '));
        // a remote window: claude starts on the remote host, out of the
        // hook's reach - the pre-fill and the word at once, as before, no arm
        let planRemote, reachRemote, showRemote, armsRemote;
        try {
            stub.env = { remoteName: 'wsl' };
            planRemote = JSON.stringify(await ext._lostByReopen(reqU));
            reachRemote = ext._carryReaches();
            showRemote = await uShow(S.real);
            armsRemote = ext._carryArms.size;
        } finally {
            delete stub.env;
        }
        check('carry: a remote window - not planned: the pre-fill as before, Show it\'s reopen given it and said at once, nothing armed; a local one - reached',
            planRemote === JSON.stringify(LB) && reachRemote === false && showRemote === JSON.stringify(['reopened', [null, '/effort ultracode'], [sayB]]) && armsRemote === 0 &&
            ext._carryReaches() === true, JSON.stringify([planRemote, reachRemote, showRemote, armsRemote]));
        // what a launch takes
        fakeCp.spawned.length = 0;
        logged.length = 0;
        const o1 = { cwd: projA };
        const c1 = ext._armCarry(SID, { ultracode: true, effort: 'max' });
        launch(['--output-format', 'stream-json', R], o1);
        const a1 = fakeCp.spawned[0];
        const g1 = await within(c1);
        launch(['--output-format', 'stream-json', R]);
        const a2 = lastArgs();
        const c3 = ext._armCarry(SID.toUpperCase(), { effort: 'max' });
        launch(['--resume', SID, '--', 'x']);
        const a3 = lastArgs();
        const g3 = await within(c3);
        check('carry: a launch of the armed chat - --resume=<id>, or --resume and the id - takes --settings {"ultracode":true} and --effort max, before a -- where there is one, its command and options as they were; once: its next launch as it came; logged',
            JSON.stringify(a1[1]) === JSON.stringify(['--output-format', 'stream-json', R, '--settings', '{"ultracode":true}', '--effort', 'max']) && a1[0] === 'claude.exe' && a1[2] === o1 &&
            JSON.stringify(g1) === '{"ultracode":true,"effort":"max"}' && JSON.stringify(a2) === JSON.stringify(['--output-format', 'stream-json', R]) &&
            JSON.stringify(a3) === JSON.stringify(['--resume', SID, '--effort', 'max', '--', 'x']) && JSON.stringify(g3) === '{"ultracode":false,"effort":"max"}' &&
            logged.includes('spawn 11111111: carried Ultracode, effort max') && logged.includes('spawn 11111111: carried effort max') && ext._carryArms.size === 0,
            JSON.stringify([a1, g1, a2, a3, g3]) + ' ' + logged.join(' | '));
        const SIDx = '44444444-4444-4444-8444-444444444444';
        const c4 = ext._armCarry(SID, { ultracode: true, effort: 'max' });
        fakeCp.spawned.length = 0;
        for (const a of [['--resume=' + SIDx], ['--output-format', 'stream-json'], ['--resume']]) launch(a);
        fakeCp.spawn('claude.exe', { cwd: projA });
        const oSeen = JSON.stringify(fakeCp.spawned.map(a => a.slice(1)));
        const pending = ext._carryArms.has(SID);
        const c5 = ext._armCarry(SID, { ultracode: true });
        const g4 = await within(c4);
        launch([R]);
        const g5 = await within(c5);
        check('carry: another chat\'s launch, one of no chat, --resume with no id, a launch with no list of arguments - each as it came, the arm still there; a newer arm for the chat - the older settles null, taken over, the newer carries what it asked',
            oSeen === JSON.stringify([[['--resume=' + SIDx], { cwd: projA }], [['--output-format', 'stream-json'], { cwd: projA }], [['--resume'], { cwd: projA }], [{ cwd: projA }]]) &&
            pending && g4 === null && JSON.stringify(g5) === '{"ultracode":true,"effort":null}' &&
            JSON.stringify(lastArgs()) === JSON.stringify([R, '--settings', '{"ultracode":true}']), oSeen + ' ' + JSON.stringify([g4, g5, lastArgs()]));
        // every launch of a chat noted, armed or not, with what went in: the
        // bound of what a later reopen carries (processStart)
        ext._carryIo.now = () => 7;
        launch(['--resume', SIDx.toUpperCase()]);
        ext._carryIo.now = () => 0;
        const pX = ext._processStart(SIDx), pS = ext._processStart(SID.toUpperCase());
        const pNone = ext._processStart('55555555-5555-4555-8555-555555555555');
        const vs = [ext._validStart({ at: 5, ultracode: true, effort: 'max' }), ext._validStart({ at: 5, ultracode: 'yes', effort: 'huge' }), ext._validStart({ at: 'x' }), ext._validStart(null)];
        check('carry: every launch of a chat noted - one of no arm with nothing put in, the armed one with what went in; a chat never launched here - this extension host\'s start; a kept one read back, or null',
            JSON.stringify(pX) === JSON.stringify({ at: 7, ultracode: false, effort: null }) && JSON.stringify(pS) === JSON.stringify({ at: 0, ultracode: true, effort: null }) &&
            JSON.stringify(pNone) === JSON.stringify({ at: 0, ultracode: false, effort: null }) &&
            JSON.stringify(vs) === JSON.stringify([{ at: 5, ultracode: true, effort: 'max' }, { at: 5, ultracode: false, effort: null }, null, null]),
            JSON.stringify([pX, pS, pNone, vs]));
        // a launch naming either flag itself
        logged.length = 0;
        const c6 = ext._armCarry(SID, { ultracode: true, effort: 'max' });
        launch([R, '--settings', '{"model":"x"}']);
        const a6 = lastArgs(), g6 = await within(c6);
        const c7 = ext._armCarry(SID, { ultracode: true, effort: 'max' });
        launch([R, '--effort=high']);
        const a7 = lastArgs(), g7 = await within(c7);
        const c8 = ext._armCarry(SID, { ultracode: true, effort: 'max' });
        launch([R, '--settings=x.json', '--effort', 'low']);
        const a8 = lastArgs(), g8 = await within(c8);
        check('carry: a launch naming --settings or --effort of its own keeps it - nothing merged - and takes the other alone; both named - nothing added; what was not carried logged',
            JSON.stringify(a6) === JSON.stringify([R, '--settings', '{"model":"x"}', '--effort', 'max']) && JSON.stringify(g6) === '{"ultracode":false,"effort":"max"}' &&
            JSON.stringify(a7) === JSON.stringify([R, '--effort=high', '--settings', '{"ultracode":true}']) && JSON.stringify(g7) === '{"ultracode":true,"effort":null}' &&
            JSON.stringify(a8) === JSON.stringify([R, '--settings=x.json', '--effort', 'low']) && JSON.stringify(g8) === NONE &&
            logged.includes('spawn 11111111: carried effort max; not carried: Ultracode - the launch has --settings of its own') &&
            logged.includes('spawn 11111111: nothing carried; not carried: Ultracode - the launch has --settings of its own; effort max - the launch has --effort of its own'),
            JSON.stringify([a6, g6, a7, g7, a8, g8]) + ' ' + logged.join(' | '));
        // the arm's end, and the hook failing
        ext._timing.carryWait = 20;
        logged.length = 0;
        const g9 = await within(ext._armCarry(SID, { effort: 'max' }));
        const expired = ext._carryArms.size === 0 && logged.some(l => /^open 11111111: no launch of it within \d+ s - nothing carried$/.test(l));
        launch([R]);
        const a9 = lastArgs();
        ext._timing.carryWait = 60000;
        const c10 = ext._armCarry(SID, { ultracode: true });
        const bad = new Proxy([R], { get(t, k) { if (k === 'length') throw new Error('boom'); return t[k]; } });
        let threwW = false, got10 = null;
        try { got10 = fakeCp.spawn('claude.exe', bad, o1); } catch (e) { threwW = true; }
        const passedBad = !threwW && !!got10 && got10.args[1] === bad && got10.args[2] === o1;
        fakeCp.spawned.length = 0;
        const still = ext._carryArms.has(SID);
        launch([R]);
        await within(c10);
        check('carry: no launch within timing.carryWait - the arm gone, nothing carried, logged, a later launch as it came; anything failing in the hook - the launch through as it came, never thrown, the arm kept',
            JSON.stringify(g9) === NONE && expired && JSON.stringify(a9) === JSON.stringify([R]) && passedBad && still,
            JSON.stringify([g9, expired, a9, passedBad, still, threwW]));
        // the reopens: armed before the open, the new tab's launch takes both -
        // no prompt, nothing said, a line in the log
        const RA = JSON.stringify(['--output-format', 'stream-json', R, '--settings', '{"ultracode":true}', '--effort', 'max']);
        const carriedLine = 'reopened 11111111: Ultracode, effort max carried';
        onMake = (sid) => launch(['--output-format', 'stream-json', '--resume=' + sid]);
        const seen = () => [prompts(), noticed(), JSON.stringify(lastArgs()) === RA, logged.includes(carriedLine)];
        const cShow = async () => {
            await quiet();
            uPut(S.real);
            frontTab();
            ext._getVerdict = twoChecks(liveV(), endedV());
            fakeCp.spawned.length = 0;
            const r = await ext._showLive(reqU, file);
            await settle();
            return JSON.stringify([r].concat(seen()));
        };
        const cNew = async (run) => {
            await quiet();
            uPut(S.real);
            ext._getVerdict = twoChecks(liveV(), endedV());
            fakeCp.spawned.length = 0;
            const r = await run();
            await settle();
            return JSON.stringify([r, asked.includes(ext._texts.sideBarStale(reqU))].concat(seen()));
        };
        const cRestore = async () => {
            await handOver({ home: homeR });
            uPut(S.real);
            panels[0].active = true;
            fakeCp.spawned.length = 0;
            const e = await endIt({}, { home: homeR });
            return JSON.stringify([e.restored].concat(seen()));
        };
        const cWatch = async () => {
            await quiet();
            uPut(S.real);
            putJob({ state: 'done', home: homeR });
            const w = ext._openWatch(JOB, {});
            calls.length = 0;
            openArgs.length = 0;
            asked.length = 0;
            fakeCp.spawned.length = 0;
            const r = await ext._onWatchMessage(w, { type: 'open' });
            await drain();
            return JSON.stringify([r, w.disposed].concat(seen()));
        };
        const cs = [await cShow(), await cNew(() => ext._showLive(reqU, file)), await cNew(() => ext._perform('tab', Object.assign({}, reqU, { hostPids: [process.pid] }))),
            await cNew(() => ext._perform('tab', Object.assign({}, reqU, { hostPids: [999991], oldProcess: 'ended' }))), await cRestore(), await cWatch()];
        check('carry: Show it\'s reopen, its new tab beside the side bar\'s copy, a run\'s tab where this window held the chat or the check ended another\'s, the chat put back after a handover, the live view\'s Open chat - each launch takes Ultracode and max; no prompt, no word but the side bar\'s, "carried" in the log',
            cs.join(' ') === [JSON.stringify(['reopened', [null, null], [], true, true]), JSON.stringify(['new', true, [null], [], true, true]),
                JSON.stringify(['new', true, [null], [], true, true]), JSON.stringify(['new', false, [null], [], true, true]),
                JSON.stringify([['new'], [null], [], true, true]), JSON.stringify(['new', true, [null], [], true, true])].join(' '),
            cs.join(' '));
        // a carry missed, or in part: said once the arm settles, what did not
        // go in to be typed - nothing in the box - in the key that sends. With
        // no launch the arm is left a second, so a slow machine still reads
        // nothing said before it goes, and its word is waited for; a launch
        // settles it at once, and the short arm's due time is looked past for
        // a second word
        const cMiss = async (mk) => {
            onMake = mk;
            ext._timing.carryWait = mk ? 30 : 1000;
            await quiet();
            uPut(S.real);
            frontTab();
            ext._getVerdict = twoChecks(liveV(), endedV());
            const r = await ext._showLive(reqU, file);
            const atOnce = noticed().length;
            if (mk) await new Promise(res => setTimeout(res, 120));
            else { await waitFor(() => noticed().length > 0); await settle(); }
            return JSON.stringify([r, prompts(), atOnce, noticed()]);
        };
        const cm = [await cMiss(null), await cMiss((sid) => launch(['--resume=' + sid, '--settings', '{}'])), await cMiss((sid) => launch(['--resume=' + sid, '--effort', 'high']))];
        const platformNow = Object.getOwnPropertyDescriptor(process, 'platform');
        let cmKey;
        try {
            cfgVals['claudeCode.useCtrlEnterToSend'] = true;
            Object.defineProperty(process, 'platform', Object.assign({}, platformNow, { value: 'win32' }));
            cmKey = await cMiss(null);
        } finally {
            Object.defineProperty(process, 'platform', platformNow);
            delete cfgVals['claudeCode.useCtrlEnterToSend'];
        }
        check('carry: no launch of the reopened chat - nothing said until the arm goes, then both named to type; a launch with --settings of its own - Ultracode alone named, as it came; with --effort - the level alone; Ctrl+Enter where that sends',
            cm.join(' ') === [JSON.stringify(['reopened', [null, null], 0, [typeB]]), JSON.stringify(['reopened', [null, null], 1, [typeU]]),
                JSON.stringify(['reopened', [null, null], 1, [typeM]])].join(' ') &&
            cmKey === JSON.stringify(['reopened', [null, null], 0, [typeB.split('Enter').join('Ctrl+Enter')]]),
            cm.join(' ') + ' ' + cmKey);
        // an open that only reveals a Claude tab reading as the chat: armed
        // all the same - one not revived yet may start its process as it
        // shows - so nothing said at once; no launch, and the commands named
        // once the arm goes. The arm outlasts the run's end on a slow machine,
        // and its word is waited for
        onMake = null;
        ext._timing.carryWait = 1500;
        const later = async () => { await waitFor(() => noticed().length > 0); await settle(); };
        const rvRestore = async () => {
            await handOver({ home: homeR });
            uPut(S.real);
            tabs.push(claudeTab(SID, 'T'));
            panels[0].active = true;
            const e = await endIt({}, { home: homeR });
            const atOnce = noticed().length;
            await later();
            return JSON.stringify([e.restored, prompts(), atOnce, noticed()]);
        };
        const rvWatch = async () => {
            await quiet();
            uPut(S.real);
            putJob({ state: 'done', home: homeR });
            tabs.push(claudeTab(SID, 'T'));
            const w = ext._openWatch(JOB, {});
            openArgs.length = 0;
            asked.length = 0;
            const r = await ext._onWatchMessage(w, { type: 'open' });
            await drain();
            const atOnce = noticed().length;
            await later();
            return JSON.stringify([r, prompts(), atOnce, noticed(), w.disposed]);
        };
        const rv = [await rvRestore(), await rvWatch()];
        check('carry: the chat put back, or the live view\'s Open chat, where a Claude tab here reads as it - revealed, no prompt, nothing said at once; no launch - both named to type once the arm goes',
            rv.join(' ') === [JSON.stringify([['revealed'], [null], 0, [typeB]]), JSON.stringify(['revealed', [null], 0, [typeB], true])].join(' '),
            rv.join(' '));
        // an arm a newer open took over says nothing: a revealed Open chat
        // still waiting on its arm, then Show it's reopen of the chat - the
        // newer launch takes both, and no word says the first one missed
        ext._timing.carryWait = 60000;
        onMake = (sid) => launch(['--output-format', 'stream-json', '--resume=' + sid]);
        await quiet();
        uPut(S.real);
        putJob({ state: 'done', home: homeR });
        tabs.push(claudeTab(SID, 'T'));
        const wT = ext._openWatch(JOB, {});
        openArgs.length = 0;
        asked.length = 0;
        const rT1 = await ext._onWatchMessage(wT, { type: 'open' });
        await drain();
        const tWaiting = ext._carryArms.has(SID);
        tabs.length = 0;
        frontTab();
        ext._getVerdict = twoChecks(liveV(), endedV());
        fakeCp.spawned.length = 0;
        openArgs.length = 0;
        const rT2 = await ext._showLive(reqU, file);
        await settle();
        await drain();
        const tSeen = JSON.stringify([rT1, tWaiting, rT2].concat(seen(), logged.includes('reopened 11111111: armed again by a newer open - its word, not this one')));
        check('carry: a revealed Open chat still waiting, then Show it\'s reopen of the chat - the first arm taken over, said nothing; the reopen\'s launch takes both, "carried" in the log',
            tSeen === JSON.stringify(['revealed', true, 'reopened', [null, null], [], true, true, true]), tSeen);
        // the chat put back, and no launch of it yet: its open does not wait
        // on the arm - the show queue goes on
        ext._timing.carryWait = 60000;
        onMake = null;
        await handOver({ home: homeR });
        uPut(S.real);
        panels[0].active = true;
        const tH = Date.now();
        const eH = await endIt({}, { home: homeR });
        const nextUp = await Promise.race([ext._enqueue(async () => 'next'), new Promise(r => setTimeout(() => r('held'), 1000))]);
        const heldMs = Date.now() - tH;
        check('carry: the chat put back, its launch not come yet - the open done and the show queue free at once, the arm waiting, nothing said yet',
            JSON.stringify(eH.restored) === '["new"]' && nextUp === 'next' && heldMs < 5000 && ext._carryArms.has(SID) && noticed().length === 0,
            JSON.stringify([eH.restored, nextUp, heldMs, ext._carryArms.has(SID), noticed()]));
        // the run's end, the chat not opened by chatq - asked, or its live
        // view left up behind others - and opened another way meanwhile
        // (Session history, the side bar): that launch takes both, armed as
        // the run ended; no launch at all - nothing said once the arm goes;
        // Open chat clicked after - its own arm takes over, and carries
        const putBackNot = async (how, click) => {
            onMake = click ? (sid) => launch(['--output-format', 'stream-json', '--resume=' + sid]) : null;
            launch([R]);    // the check before left its arm waiting: taken
            await handOver({ home: homeR });
            uPut(S.real);
            if (how === 'asked') panels[0].dispose(); else panels[0].active = false;
            const infoWas = stub.window.showInformationMessage;
            let clickIt = null;
            stub.window.showInformationMessage = (m, ...b) => {
                asked.push(m);
                return m === ext._texts.ranClosed(rsT) ? new Promise(r => { clickIt = () => r('Open chat'); }) : Promise.resolve(undefined);
            };
            try {
                logged.length = 0;
                fakeCp.spawned.length = 0;
                const e = await endIt({}, { home: homeR });
                await within(ext._putBackLast());
                const armed = ext._carryArms.has(SID);
                if (click && clickIt) { clickIt(); await drain(); await settle(); }
                else if (!click) launch(['--output-format', 'stream-json', R]);
                return JSON.stringify([e.restored, armed, JSON.stringify(lastArgs()) === RA, noticed(), ext._carryArms.has(SID),
                    logged.some(l => /^run 11111111 ended, the chat not opened again: Ultracode, effort max armed for its next launch here, for \d+ min$/.test(l)),
                    logged.includes('spawn 11111111: carried Ultracode, effort max'), logged.includes('reopened 11111111: armed again by a newer open - its word, not this one')]);
            } finally {
                stub.window.showInformationMessage = infoWas;
            }
        };
        const pb = [await putBackNot('asked'), await putBackNot('shown'), await putBackNot('asked', true)];
        check('carry: the chat put back by no open of chatq\'s - asked, or its live view left up - armed as the run ends; a launch of it by other means takes Ultracode and max, logged, nothing said; Open chat clicked after - its own arm takes over, the launch carries both, the first arm says nothing',
            pb.join(' ') === [JSON.stringify([['asked'], true, true, [], false, true, true, false]), JSON.stringify([['shown'], true, true, [], false, true, true, false]),
                JSON.stringify([['asked'], true, true, [], false, true, true, false])].join(' '),
            pb.join(' '));
        // its going waited for by the line it logs, not timed: a slow machine
        // only waits longer. That it was armed as the run ended is the checks
        // above, with arms that outlast any machine
        ext._timing.putBackWait = 300;
        onMake = null;
        await handOver({ home: homeR });
        uPut(S.real);
        panels[0].dispose();
        logged.length = 0;
        const eQ = await endIt({}, { home: homeR });
        const putBackGone = l => /^open 11111111: no launch of it within \d+ s - nothing carried$/.test(l);
        await waitFor(() => logged.some(putBackGone));
        await settle();
        ext._timing.putBackWait = 30 * 60000;
        check('carry: the chat put back by no open of chatq\'s, and no launch of it within timing.putBackWait - the arm gone, logged, nothing said',
            JSON.stringify(eQ.restored) === '["asked"]' && !ext._carryArms.has(SID) && noticed().length === 0 && logged.some(putBackGone),
            JSON.stringify([eQ.restored, ext._carryArms.has(SID), noticed(), logged]));
        // deactivate: the arms dropped unsaid, child_process.spawn as it was
        ext.deactivate();
        const pkS = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'extension', 'package.json'), 'utf8')).contributes.configuration.properties['chatManager.keepSessionSettings'];
        check('carry: deactivate puts spawn back and drops every arm; chatManager.keepSessionSettings declared, a boolean, on by default',
            fakeCp.spawn === fakeSpawn && ext._carryArms.size === 0 && !!pkS && pkS.type === 'boolean' && pkS.default === true && ext._keepSettings() === true,
            JSON.stringify([fakeCp.spawn === fakeSpawn, ext._carryArms.size, pkS]));
        }
        // opens that are not chatq's reopens: the chip's and the picker's
        await quiet();
        uPut(S.real);
        const uo1 = await ext._openTab({ kind: 'open', sessionId: SID, title: 'T', cwd: projA, home: homeR, oldProcess: 'none', hostPids: [] });
        const uo1Seen = JSON.stringify([prompts(), noticed()]);
        await quiet();
        uPut(S.real);
        const uo2 = await ext._acceptChat({ sid: SID, cwd: projA, file: uChat, dir: uChatDir, size: fs.statSync(uChat).size, mtimeMs: Date.now() });
        const uo2Seen = JSON.stringify([prompts(), noticed()]);
        check('effort: the chip\'s open and the picker\'s, Ultracode and max in the transcript - no prompt, nothing said: neither closed a tab of chatq\'s',
            uo1 === 'new' && uo1Seen === '[[null],[]]' && uo2 === 'new' && uo2Seen === '[[null],[]]', uo1 + ' ' + uo1Seen + ' ' + uo2 + ' ' + uo2Seen);
        // the watch panel's header, where the run carries Ultracode or a level
        await quiet();
        putJob({ ultracode: true, effort: 'max' });
        const uw1 = ext._openWatch(JOB, {});
        const uh1 = uw1.head;
        uw1.panel.dispose();
        putJob({});
        putRs({ phase: 'running', hostPids: [999991], ultracode: true, effort: 'max' });
        await runOnce();
        const uw2 = ext._openWatch(JOB, {});
        const uh2 = uw2.head;
        uw2.panel.dispose();
        putRs({ phase: 'running', hostPids: [999991] });
        await runOnce();
        const uw3 = ext._openWatch(JOB, {});
        const uh3 = uw3.head;
        const hasU = (h) => /class="ultra">Ultracode</.test(h), hasM = (h) => /class="effort">effort max</.test(h);
        check('the panel: "Ultracode" and "effort max" in the header where the job carries them, or run-state does; neither - none; a level Claude Code does not know - not shown',
            hasU(uh1) && hasM(uh1) && hasU(uh2) && hasM(uh2) && !/Ultracode|effort /.test(uh3) &&
            hasU(wv.headerHtml({ state: 'done' }, { ultracode: true })) && !/Ultracode/.test(wv.headerHtml({ state: 'done', ultracode: false }, {})) &&
            hasM(wv.headerHtml({ state: 'done' }, { effort: 'max' })) && !hasU(wv.headerHtml({ state: 'done' }, { effort: 'max' })) &&
            /class="effort">effort high</.test(wv.headerHtml({ state: 'done', effort: 'high' }, { effort: 'max' })) &&
            !/class="effort"/.test(wv.headerHtml({ state: 'done', effort: '<b>x</b>' }, { effort: 'ultracode' })),
            uh1 + ' / ' + uh2 + ' / ' + uh3);
        const uhQ = wv.headerHtml({ state: 'queued', ultracode: true, effort: 'max' }, { ultracode: true, effort: 'high' });
        const uhR = wv.headerHtml({ state: 'running', ultracode: true, effort: 'max' }, {});
        check('the panel: a job back in the queue - neither "Ultracode" nor a level, whatever it or run-state carries from its last run; running - both',
            !/class="ultra"|class="effort"/.test(uhQ) && hasU(uhR) && hasM(uhR), uhQ + ' / ' + uhR);
        fs.rmSync(uChatDir, { recursive: true, force: true });

        for (const v of [...ext._watchViews.values()]) v.panel.dispose();
        setupMod._runPs = realRunPs;
        Object.assign(ext._overlayIo, realIoRun);
        fs.watchFile = realWatchFile;
        fs.unwatchFile = realUnwatchFile;
        delete context.workspaceState;
        delete cfgVals['chatManager.folder'];
        claudeHere = false;
        aliveSet.clear();
        fs.rmSync(rt, { recursive: true, force: true });
    }

    // --- the terminal half: setup.js and build.js -----------------------------
    const su = require(path.join(__dirname, '..', 'extension', 'setup.js'));
    const bj = require(path.join(__dirname, '..', 'extension', 'build.js'));
    check('setup: the loader\'s version read from its text', su._readVersion("# x\r\n$script:ChatVersion = '0.7.0'\r\n") === '0.7.0' &&
        su._readVersion('none') === null && su._readVersion("$script:ChatVersion = '0.8.0-rc1'") === null);
    check('setup: versions compare by number, 0.10.0 after 0.9.1', su._compareVersions('0.10.0', '0.9.1') === 1 &&
        su._compareVersions('0.7.0', '0.7.0') === 0 && su._compareVersions('0.6.9', '0.7.0') === -1);
    const dcd = (bundled, disk, git, extra) => su._decide(Object.assign({ bundled, loader: disk !== null, onDisk: disk, git, foreign: false }, extra));
    check('setup: nothing there - install; older - update; the same - nothing; newer - left alone',
        dcd('0.7.0', null, false) === 'install' && dcd('0.7.0', '0.6.0', false) === 'update' && dcd('0.7.0', '0.7.0', false) === 'none' && dcd('0.7.0', '0.8.0', false) === 'newer');
    check('setup: a git checkout is never written - another version there is only said',
        dcd('0.7.0', '0.6.0', true) === 'skew' && dcd('0.7.0', '0.7.0', true) === 'none' && dcd('0.7.0', null, true) === 'none');
    check('setup: a loader whose version cannot be read is left, never taken for no loader',
        dcd('0.7.0', null, false, { loader: true }) === 'unknown' && dcd('0.7.0', null, true, { loader: true }) === 'unknown');
    check('setup: a folder holding other things is not installed into', dcd('0.7.0', null, false, { foreign: true }) === 'foreign');
    check('setup: a build carrying no scripts does nothing', dcd(null, '0.6.0', false) === 'none' && dcd(null, null, false) === 'none');
    check('setup: the profile looked at when files changed, or when not settled for this version',
        su._needsProbe('update', { profile: 'yes' }, '0.7.0') && su._needsProbe('none', {}, '0.7.0') && !su._needsProbe('none', { profile: 'yes' }, '0.7.0') &&
        !su._needsProbe('none', { profile: 'never' }, '0.7.0') && !su._needsProbe('none', { notNowFor: '0.7.0' }, '0.7.0') && su._needsProbe('none', { notNowFor: '0.6.0' }, '0.7.0'));
    check('setup: asked only where a PowerShell lacks the line; never after Never; after Not now, at the next version; always from the palette',
        !su._shouldAsk({}, [], '0.7.0', true) && su._shouldAsk({}, ['p'], '0.7.0', false) && !su._shouldAsk({ profile: 'never' }, ['p'], '0.7.0', false) &&
        su._shouldAsk({ profile: 'never' }, ['p'], '0.7.0', true) && !su._shouldAsk({ notNowFor: '0.7.0' }, ['p'], '0.7.0', false) && su._shouldAsk({ notNowFor: '0.6.0' }, ['p'], '0.7.0', false));
    check('setup: the policies a profile line cannot run under', su._blocksProfile('Restricted') && su._blocksProfile('AllSigned') &&
        !su._blocksProfile('RemoteSigned') && !su._blocksProfile('Bypass') && !su._blocksProfile(null));
    check('setup: the last True or False a PowerShell printed, and none is no answer', su._lastBool('WARNING: x\r\nFalse\r\nTrue\r\n') === true && su._lastBool('noise') === null);
    const pa = su._psArgs("C:\\it's\\Charlie-and-the-chat-factory.ps1", 'Test-ChatProfileLine');
    const pt = dec(pa);
    check('setup: its PowerShell loads no profile, is marked as no interactive shell, and quotes the path',
        pa.includes('-NoProfile') && pa.includes('Bypass') && pt === "$env:CHATQ_OVERLAY='1'; . 'C:\\it''s\\Charlie-and-the-chat-factory.ps1'; Test-ChatProfileLine", pt);

    // locks, folders and copies, in the sandbox
    const sbx = path.join(dir, 'ext-setup');
    fs.rmSync(sbx, { recursive: true, force: true });
    fs.mkdirSync(sbx, { recursive: true });
    const lk = path.join(sbx, 'x.lock');
    const t0 = Date.now();
    check('lock: the first window takes it, a second does not', su._takeLock(lk, t0, 60000) && !su._takeLock(lk, t0, 60000));
    check('lock: one older than its limit is taken over', su._takeLock(lk, t0 + 120000, 60000));
    su._releaseLock(lk);
    check('lock: released, it is free again', su._takeLock(lk, t0, 60000));
    su._releaseLock(lk);
    let lockThrew = false;
    try { su._takeLock(path.join(sbx, 'no-such-dir', 'x.lock'), t0, 60000); } catch (e) { lockThrew = true; }
    check('lock: a place that cannot be written throws, never reads as another window', lockThrew);
    fs.mkdirSync(path.join(sbx, 'repo', '.git'), { recursive: true });
    fs.mkdirSync(path.join(sbx, 'repo', 'Tools', 'tool'), { recursive: true });
    // the sandbox is inside this repo, so every look stops at it
    const realGit = su._inGitCheckout;
    check('setup: a folder inside a git work tree counts as one, however deep', realGit(path.join(sbx, 'repo', 'Tools', 'tool'), sbx) &&
        !realGit(path.join(sbx, 'x'), sbx));
    su._inGitCheckout = (f) => realGit(f, sbx);
    fs.mkdirSync(path.join(sbx, 'docs'), { recursive: true });
    fs.writeFileSync(path.join(sbx, 'docs', 'letter.txt'), 'x');
    fs.mkdirSync(path.join(sbx, 'empty'), { recursive: true });
    fs.mkdirSync(path.join(sbx, 'withdata', 'data'), { recursive: true });
    check('setup: someone else\'s folder is foreign; an empty or missing one, or one with data/, is not',
        su._isForeign(path.join(sbx, 'docs')) && !su._isForeign(path.join(sbx, 'empty')) && !su._isForeign(path.join(sbx, 'missing')) &&
        !su._isForeign(path.join(sbx, 'withdata')));

    // packages carrying 0.7.0 and 0.7.1, and a tool folder to put them in
    const mkPayload = (at, v) => {
        const p = path.join(at, 'payload');
        fs.mkdirSync(path.join(p, 'src'), { recursive: true });
        fs.writeFileSync(path.join(p, su.LOADER), "$script:ChatVersion = '" + v + "'\r\n");
        fs.writeFileSync(path.join(p, 'src', 'core.ps1'), '# core ' + v + '\r\n');
        return at;
    };
    const ext70 = mkPayload(path.join(sbx, 'ext70'), '0.7.0');
    const ext71 = mkPayload(path.join(sbx, 'ext71'), '0.7.1');
    const tool = path.join(sbx, 'tool');
    const steps = [];
    const realStep = su._profileStep;
    su._profileStep = async (o) => { steps.push(o.action); };
    const said = [];
    const warned = [];
    stub.window.showInformationMessage = async (m) => { said.push(m); };
    stub.window.showWarningMessage = async (m) => { warned.push(m); };
    const up = (at, force, where) => su.setUp({ extensionPath: at, folder: where || tool, log: () => { }, force });
    const diskText = () => { try { return fs.readFileSync(path.join(tool, su.LOADER), 'latin1'); } catch (e) { return ''; } };
    const coreText = () => { try { return fs.readFileSync(path.join(tool, 'src', 'core.ps1'), 'latin1'); } catch (e) { return ''; } };
    const r1s = await up(ext70);
    check('setUp: an empty folder gets the scripts, then the profile step, and says where',
        r1s === 'install' && diskText().includes("'0.7.0'") && coreText().includes('0.7.0') && steps.join() === 'install' &&
        !fs.existsSync(path.join(tool, su.LOADER + '.new')) && said.length === 1 && said[0].includes(tool), r1s + ' ' + steps.join() + ' ' + said.join('|'));
    steps.length = 0; said.length = 0;
    const r2s = await up(ext70);
    check('setUp: the same package again copies nothing; the profile question is still open', r2s === 'none' && steps.join() === 'none', r2s + ' ' + steps.join());
    steps.length = 0;
    su._writeState(tool, { profile: 'yes' });
    const r3s = await up(ext70);
    check('setUp: settled, a start runs no PowerShell at all', r3s === 'none' && steps.length === 0, r3s + ' ' + steps.join());
    const r4s = await up(ext71);
    check('setUp: a newer package updates the copy, and says so', r4s === 'update' && diskText().includes("'0.7.1'") && coreText().includes('0.7.1') &&
        steps.join() === 'update' && said.some(m => m.includes('0.7.1')), r4s + ' ' + steps.join());
    steps.length = 0;
    const r5s = await up(ext70);
    check('setUp: an older package leaves a newer copy alone', r5s === 'newer' && diskText().includes("'0.7.1'") && steps.length === 0, r5s);
    fs.writeFileSync(path.join(tool, su.LOADER), "$script:ChatVersion = '0.9.0-dev'\r\n");
    warned.length = 0;
    const u1 = await up(ext70);
    const u2 = await up(ext70);
    check('setUp: a loader of no readable version is left as it is, and said once', u1 === 'unknown' && u2 === 'unknown' &&
        diskText().includes('0.9.0-dev') && warned.length === 1 && steps.length === 0, u1 + ' ' + warned.join('|'));
    fs.writeFileSync(path.join(tool, su.LOADER), "$script:ChatVersion = '0.6.0'\r\n");
    fs.writeFileSync(path.join(tool, 'data', 'install.lock'), '1');
    const r6s = await up(ext70);
    check('setUp: while another window holds the lock, nothing is copied', r6s === 'elsewhere' && diskText().includes("'0.6.0'"), r6s);
    fs.unlinkSync(path.join(tool, 'data', 'install.lock'));
    // a copy that fails: src is a file where the folder goes
    const bad = path.join(sbx, 'bad');
    fs.mkdirSync(path.join(bad, 'data'), { recursive: true });
    fs.writeFileSync(path.join(bad, 'src'), 'not a folder');
    warned.length = 0;
    const b1 = await up(ext70, false, bad);
    const b2 = await up(ext70, false, bad);
    check('setUp: a copy that fails says so once a version, leaves no .new, and keeps no half install',
        b1 === 'failed' && b2 === 'failed' && warned.length === 1 && /could not put/.test(warned[0]) && !fs.existsSync(path.join(bad, su.LOADER)) &&
        !fs.readdirSync(bad).some(n => n.endsWith('.new')), b1 + ' ' + warned.join('|'));
    warned.length = 0;
    const f1 = await up(ext70, false, path.join(sbx, 'docs'));
    check('setUp: someone else\'s folder gets nothing, not even a data/, and is said', f1 === 'foreign' &&
        !fs.existsSync(path.join(sbx, 'docs', 'data')) && !fs.existsSync(path.join(sbx, 'docs', su.LOADER)) && warned.length === 1, f1);
    fs.mkdirSync(path.join(tool, '.git'));
    said.length = 0;
    const g1 = await up(ext70);
    const g2 = await up(ext70);
    check('setUp: a git checkout is never written, and the difference is said once',
        g1 === 'skew' && g2 === 'skew' && diskText().includes("'0.6.0'") && said.length === 1 && /pull to match/.test(said[0]), g1 + ' ' + said.join('|'));
    // onReady: once the loader is in place, before the profile step, which
    // waits on a question nobody may ever answer
    const tool3 = path.join(sbx, 'tool3');
    const readyAt = [];
    let stepGo = null;
    su._profileStep = () => { readyAt.push('step'); return new Promise(r => { stepGo = r; }); };
    const onReady = () => readyAt.push('ready:' + fs.existsSync(path.join(tool3, su.LOADER)));
    const pending = su.setUp({ extensionPath: ext70, folder: tool3, log: () => { }, onReady });
    for (let i = 0; i < 50 && !stepGo; i++) await tick();
    const readyWhileAsking = readyAt.join();
    if (stepGo) stepGo();
    const rr1 = await pending;
    readyAt.length = 0;
    su._profileStep = async () => { readyAt.push('step'); };
    su._writeState(tool3, {});
    const rr2 = await su.setUp({ extensionPath: ext70, folder: tool3, log: () => { }, onReady });
    const readyThere = readyAt.join();
    readyAt.length = 0;
    const rr3 = await su.setUp({ extensionPath: ext70, folder: path.join(sbx, 'docs'), log: () => { }, onReady });
    check('setUp: onReady the moment its copy put the loader there, or at once where it was there, and before the profile step, which may never end; never for a folder it did not install into',
        readyWhileAsking === 'ready:true,step' && rr1 === 'install' && readyThere === 'ready:true,step' && rr2 === 'none' && rr3 === 'foreign' && readyAt.length === 0,
        readyWhileAsking + ' / ' + readyThere + ' / ' + rr1 + ' ' + rr2 + ' ' + rr3 + ' ' + readyAt.join());
    su._profileStep = realStep;
    su._inGitCheckout = realGit;

    // the profile step itself, with PowerShell stood in for: hosts A and B,
    // what each answers, and every command recorded
    const ps = { A: { line: true, policy: 'RemoteSigned' }, B: { line: false, policy: 'RemoteSigned' } };
    const psRan = [];
    let installWorks = true;
    const real = { hosts: su._hosts, runPs: su._runPs, policyOf: su._policyOf, allowScripts: su._allowScripts };
    su._hosts = () => Object.keys(ps);
    su._runPs = async (exe, loader, cmd) => {
        psRan.push(exe + ':' + cmd.split(' ')[0]);
        if (/Test-ChatProfileLine/.test(cmd)) return { ok: true, stdout: ps[exe].line === null ? 'garbage' : String(ps[exe].line ? 'True' : 'False') };
        if (/^chatinstall/.test(cmd) && installWorks) ps[exe].line = true;
        return { ok: true, stdout: '' };
    };
    su._policyOf = async (exe) => ps[exe].policy;
    // locked: a group policy decides it, and nothing here changes it
    su._allowScripts = async (exe) => { psRan.push(exe + ':allow'); if (!ps[exe].locked) ps[exe].policy = 'RemoteSigned'; return ps[exe].policy === 'RemoteSigned'; };
    let answer2 = 'Add';
    const asked2 = [];
    stub.window.showInformationMessage = async (m, ...b) => { asked2.push(m); return b.length ? answer2 : undefined; };
    stub.window.showWarningMessage = async (m, ...b) => { asked2.push('warn:' + m); return b.length ? 'Allow' : undefined; };
    const pf = path.join(sbx, 'pf');
    fs.mkdirSync(pf, { recursive: true });
    const step = (action, force) => su._profileStep({ folder: pf, loader: 'L', version: '0.7.0', action, force, log: () => { } });
    const reset2 = () => { psRan.length = 0; asked2.length = 0; su._writeState(pf, {}); };
    reset2();
    await step('update');
    check('profile: Add - chatinstall where the line was missing, checked again; after an update also where it was; one restart',
        psRan.filter(x => /chatinstall/.test(x)).sort().join() === 'A:chatinstall,B:chatinstall' && psRan.filter(x => /Restart-ChatBackground/.test(x)).length === 1 &&
        su._readState(pf).profile === 'yes' && asked2.includes(su.texts.added), psRan.join() + ' | ' + asked2.join(' | '));
    reset2();
    ps.B.line = false;
    installWorks = false;
    await step('none');
    installWorks = true;
    check('profile: Add, and the line still not there after - no "Added", the answer not kept as yes, and said',
        su._readState(pf).profile !== 'yes' && su._readState(pf).notNowFor === '0.7.0' && !asked2.includes(su.texts.added) &&
        asked2.includes('warn:' + su.texts.addFailed), JSON.stringify(su._readState(pf)) + ' | ' + asked2.join(' | '));
    reset2();
    ps.B = { line: false, policy: 'Restricted' };
    await step('none');
    check('profile: the policy would stop the line - the question says so, and Add allows scripts before the line is written',
        asked2[0] === su.texts.askPolicy('Restricted') && psRan.indexOf('B:allow') >= 0 && psRan.indexOf('B:allow') < psRan.indexOf('B:chatinstall') &&
        su._readState(pf).profile === 'yes', psRan.join() + ' | ' + asked2.join(' | '));
    reset2();
    ps.B = { line: false, policy: 'Restricted', locked: true };
    await step('none');
    check('profile: a policy that will not change - the line is not written, and said',
        !psRan.includes('B:chatinstall') && asked2.includes('warn:' + su.texts.policyStuck) && su._readState(pf).profile !== 'yes', psRan.join() + ' | ' + asked2.join(' | '));
    reset2();
    ps.B = { line: null, policy: 'RemoteSigned' };
    await step('none');
    check('profile: a PowerShell that gives no answer is neither asked about nor installed into', asked2.length === 0 &&
        !psRan.some(x => /chatinstall/.test(x)), psRan.join() + ' | ' + asked2.join(' | '));
    reset2();
    ps.A = { line: true, policy: 'Restricted', locked: true };
    ps.B = { line: true, policy: 'RemoteSigned' };
    await step('none');
    const firstAsk = asked2.slice();
    asked2.length = 0;
    await step('none');
    check('profile: a line already there that the policy never runs - offered once a version, tried on the click, and a refusal said',
        firstAsk[0] === 'warn:' + su.texts.policyHave('Restricted') && firstAsk.includes('warn:' + su.texts.policyStuck) &&
        psRan.includes('A:allow') && asked2.length === 0, firstAsk.join(' | ') + ' / ' + asked2.join(' | '));
    reset2();
    ps.A = { line: false, policy: 'RemoteSigned' };
    ps.B = { line: false, policy: 'RemoteSigned' };
    answer2 = 'Never';
    await step('none');
    const afterNever = su._readState(pf).profile;
    asked2.length = 0;
    await step('none');
    const askedAgain = asked2.length;
    await step('none', true);
    answer2 = 'Add';
    check('profile: Never is kept and never asked again - until the palette asks', afterNever === 'never' && askedAgain === 0 && asked2.length >= 1,
        afterNever + ' ' + askedAgain + ' ' + asked2.length);
    Object.assign(su, { _hosts: real.hosts, _runPs: real.runPs, _policyOf: real.policyOf, _allowScripts: real.allowScripts });

    check('build: the part names in the loader\'s own list, in its order', bj._partsOf("x\r\n$chatParts = 'core', 'providers', 'overlay'\r\n").join() === 'core,providers,overlay');
    check('build: an SVG image is caught; a PNG, and a plain link to an SVG, are not',
        bj._svgImages('![a](x/demo.svg) ![b](y.png) [c](z.svg) <img alt="w" src="w.SVG">').join() === 'x/demo.svg,w.SVG');
    const realLoader = fs.readFileSync(path.join(__dirname, '..', su.LOADER), 'latin1');
    const realParts = bj._partsOf(realLoader);
    check('build: the real loader lists 25 parts, each one in src/', realParts.length === 25 &&
        realParts.every(p => fs.existsSync(path.join(__dirname, '..', 'src', p + '.ps1'))), realParts.join());
    const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'extension', 'package.json'), 'utf8'));
    check('build: the extension\'s version is the script\'s', pkg.version === su._readVersion(realLoader), pkg.version + ' / ' + su._readVersion(realLoader));
    check('build: the listing README shows no SVG', bj._svgImages(fs.readFileSync(path.join(__dirname, '..', 'extension', 'README.md'), 'utf8')).length === 0);
    // the watch panel: its half in watch.js, which the package must carry -
    // vsce packs every file .vscodeignore does not name - and what VS Code
    // reads of package.json to offer it and bring it back after a reload
    const ignored = fs.readFileSync(path.join(__dirname, '..', 'extension', '.vscodeignore'), 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
    const cmds = ((pkg.contributes || {}).commands || []).map(c => c.command);
    const wr = ((pkg.contributes || {}).configuration || {}).properties || {};
    check('package: watch.js carried - no .vscodeignore line names it; the watch command, chatManager.watchRuns (on by default) and the panel\'s activation event declared',
        !ignored.some(p => /^(watch\.js|\*\.js|\*\*\/\*\.js)$/.test(p)) && fs.existsSync(path.join(__dirname, '..', 'extension', 'watch.js')) &&
        cmds.includes('chatManager.watchRun') && !!wr['chatManager.watchRuns'] && wr['chatManager.watchRuns'].type === 'boolean' && wr['chatManager.watchRuns'].default === true &&
        (pkg.activationEvents || []).includes('onWebviewPanel:chatManager.watch'), ignored.join() + ' / ' + JSON.stringify(pkg.activationEvents));

    // the tool folder, as set
    cfgVals['chatManager.folder'] = 'Tools/relative';
    const relTo = ext._toolFolder();
    delete cfgVals['chatManager.folder'];
    cfgVals['chatManagerReload.signalFile'] = path.resolve('/c/Users/me/reload-request');
    const oddTo = ext._toolFolder();
    delete cfgVals['chatManagerReload.signalFile'];
    const dflt = path.join(require('os').homedir(), 'Tools', 'Charlie-and-the-chat-factory');
    check('the tool folder: a relative one, or a signalFile not in a data/ folder, falls back to the default - never C:\\ or C:\\Users',
        relTo === dflt && oddTo === dflt, relTo + ' | ' + oddTo);

    // the overlay started on activation, with the platform, the config, the
    // lock and PowerShell stood in for
    const ov = path.join(sbx, 'ov');
    fs.mkdirSync(path.join(ov, 'data'), { recursive: true });
    fs.writeFileSync(path.join(ov, su.LOADER), "$script:ChatVersion = '0.7.1'\r\n");
    const lockFile = path.join(ov, 'data', 'overlay.lock');
    check('the overlay lock: missing, or there and opened by nobody, is not held', !ext._lockHeld(lockFile) &&
        (fs.writeFileSync(lockFile, ''), !ext._lockHeld(lockFile)));
    // force: a first look that fails skips the write, and the check says so
    fs.rmSync(lockFile, { force: true });
    // the real thing, as the overlay holds it: opened with no sharing, and held
    // till its stdin ends - no set time a starved check could sleep through. One
    // that never says it holds it is started again, three in all: a machine short
    // of memory can fail its start - refused to node, or dead as it loads - or
    // its open. The detail has each exit code, and the last one's first error line
    const winPs = ext._windowsPowerShell();
    if (process.platform === 'win32' && fs.existsSync(winPs)) {
        const heldFile = path.join(ov, 'data', 'held.lock');
        const exits = [];
        let opened = false, whileHeld = false, afterExit = false, err = '';
        for (let i = 0; i < 3 && !opened; i++) {
            let child;
            err = '';
            try {
                child = require('child_process').spawn(winPs, ['-NoProfile', '-NonInteractive', '-Command',
                    "$ErrorActionPreference = 'Stop'; $f = [IO.File]::Open(" + ext._psQuote(heldFile) + ", 'OpenOrCreate', 'ReadWrite', 'None'); [Console]::Out.WriteLine('held'); $null = [Console]::In.ReadLine(); $f.Close()"],
                    { windowsHide: true });
            } catch (e) {
                // a refused start node throws for, most codes; the rest come
                // as 'error', with 'close' after it
                exits.push(e.code || 'spawn');
                err = e.message;
                continue;
            }
            child.on('error', e => { err += e.message; });
            child.stderr.on('data', d => { err += d; });
            // on close, not exit: its output is all read by then
            const exited = new Promise(r => child.on('close', r));
            let giveUp;
            opened = await new Promise(r => {
                let out = '';
                child.stdout.on('data', d => { out += d; if (/held/.test(out)) r(true); });
                exited.then(() => r(false));
                giveUp = setTimeout(() => r(false), 30000);
            });
            clearTimeout(giveUp);
            whileHeld = opened && ext._lockHeld(heldFile);
            if (opened) child.stdin.end(); else child.kill();
            exits.push(await exited);
            afterExit = ext._lockHeld(heldFile);
        }
        check('the overlay lock, held for real by a PowerShell: held while it is open, free once it lets go', whileHeld && !afterExit,
            opened + ' ' + whileHeld + ' ' + afterExit + ', exit ' + exits.join(' ') + (err.trim() ? ': ' + err.trim().split(/\r?\n/)[0] : ''));
    } else {
        console.log('  skip  the overlay lock, held for real by a PowerShell: no Windows PowerShell here');
    }
    const realIo = Object.assign({}, ext._overlayIo);
    // which PowerShell: Windows PowerShell's own path, with no look on PATH
    const hostsAsked = [];
    su._hosts = () => { hostsAsked.push(1); return ['pwsh']; };
    ext._overlayIo.exists = () => true;
    const psWin = realIo.powershell('win32');
    ext._overlayIo.exists = () => false;
    const psNone = realIo.powershell('win32');
    const winAsked = hostsAsked.length;
    ext._forgetPwsh();
    const psMac = realIo.powershell('darwin');
    const psMac2 = realIo.powershell('darwin');
    const macAsked = hostsAsked.length - winAsked;
    ext._forgetPwsh();
    ext._overlayIo.exists = realIo.exists;
    check('overlay: on Windows, Windows PowerShell by its own path - never setup\'s hosts(), whose where.exe can take 5 s; elsewhere pwsh as hosts() finds it, once for the host\'s life',
        psWin === ext._windowsPowerShell() && /WindowsPowerShell[\\/]v1\.0[\\/]powershell\.exe$/.test(psWin) && psNone === null && winAsked === 0 && psMac === 'pwsh' &&
        psMac2 === 'pwsh' && macAsked === 1,
        psWin + ' ' + psNone + ' ' + winAsked + ' ' + psMac + ' ' + macAsked);
    const ovRan = [];
    let ovSays = 'started';
    su._runPs = async (exe, loader, cmd) => { ovRan.push(exe + ':' + cmd + ':' + loader); if (ovSays === 'throw') throw new Error('boom'); return { ok: true, stdout: 'WARNING: x\r\n' + ovSays + '\r\n' }; };
    let ovCfg = null;
    let ovHeld = false;
    const ioError = (code) => { const e = new Error(code); e.code = code; return e; };
    Object.assign(ext._overlayIo, {
        platform: () => 'win32',
        readFile: (f) => {
            if (ovCfg === null || f !== path.join(ov, 'data', 'config.json')) throw ioError('ENOENT');
            if (ovCfg === 'EACCES') throw ioError('EACCES');
            return ovCfg;
        },
        lockHeld: (f) => ovHeld && f === lockFile,
        powershell: () => 'PS'
    });
    cfgVals['chatManager.folder'] = ov;
    const ovStart = async (x) => {
        ovRan.length = 0;
        ovCfg = x.cfg === undefined ? null : x.cfg;
        ovHeld = !!x.held;
        ext._overlayIo.platform = () => x.platform || 'win32';
        return ext._startOverlay({});
    };
    const s1 = await ovStart({});
    check('overlay: on Windows with no config.json, started - Start-ChatOverlayAuto, once, through the loader, and its word taken',
        s1 === 'started' && ovRan.length === 1 && ovRan[0] === 'PS:Start-ChatOverlayAuto:' + path.join(ov, su.LOADER), s1 + ' ' + ovRan.join());
    const ctxOv = {};
    ovRan.length = 0;
    const s2a = await ext._startOverlay(ctxOv);
    const s2b = await ext._startOverlay(ctxOv);
    check('overlay: one start per activation', s2a === 'started' && s2b === 'already' && ovRan.length === 1, s2a + ' ' + s2b + ' ' + ovRan.join());
    const s3 = await ovStart({ cfg: '\uFEFF{"overlay":{"autoStart":false}}' });
    const s3b = await ovStart({ cfg: '{"overlay":{"autoStart":false}}', platform: 'darwin' });
    check('overlay: autoStart false - not started, BOM or not', s3 === 'off' && s3b === 'off' && ovRan.length === 0, s3 + ' ' + s3b);
    const s4 = await ovStart({ platform: 'darwin' });
    const s4b = await ovStart({ platform: 'darwin', cfg: '{"overlay":{"theme":"dark"}}' });
    const s4c = await ovStart({ platform: 'darwin', cfg: '{"overlay":{"autoStart":true}}' });
    check('overlay: off by default on a Mac, started there only when turned on', s4 === 'off' && s4b === 'off' && s4c === 'started' && ovRan.length === 1, s4 + ' ' + s4b + ' ' + s4c);
    const s5 = await ovStart({ platform: 'linux', cfg: '{"overlay":{"autoStart":true}}' });
    check('overlay: never where there is no panel to draw', s5 === 'no panel' && ovRan.length === 0, s5);
    const s6 = await ovStart({ held: true });
    check('overlay: its lock held - already running, no PowerShell', s6 === 'running' && ovRan.length === 0, s6);
    cfgVals['chatManager.folder'] = path.join(sbx, 'no-loader');
    const s7 = await ovStart({});
    cfgVals['chatManager.folder'] = ov;
    check('overlay: no loader in the tool folder - not started', s7 === 'no loader' && ovRan.length === 0, s7);
    ovSays = 'running';
    const s8 = await ovStart({});
    ovSays = 'nonsense';
    const s8b = await ovStart({});
    ovSays = 'throw';
    let s8c, ovThrew = false;
    try { s8c = await ovStart({}); } catch (e) { ovThrew = true; }
    ovSays = 'started';
    check('overlay: the script\'s word as it said it; no word, or PowerShell failing, is failed and never thrown',
        s8 === 'running' && s8b === 'failed' && s8c === 'failed' && !ovThrew, s8 + ' ' + s8b + ' ' + s8c);
    const s9 = await ovStart({ cfg: '{"overlay":{"autoStart":fal' });
    const s9b = await ovStart({ cfg: 'EACCES' });
    const s9c = await ovStart({ cfg: '{"theme":"dark"}' });
    check('overlay: a config.json that does not parse, or cannot be read, is off - it may be what turned it off; a missing key is the default',
        s9 === 'off' && s9b === 'off' && s9c === 'started' && ovRan.length === 1, s9 + ' ' + s9b + ' ' + s9c);
    const ctxL = {};
    ovRan.length = 0;
    ovCfg = null;
    cfgVals['chatManager.folder'] = path.join(sbx, 'no-loader');
    const s10a = await ext._startOverlay(ctxL);
    cfgVals['chatManager.folder'] = ov;
    const s10b = await ext._startOverlay(ctxL);
    const s10c = await ext._startOverlay(ctxL);
    check('overlay: a look before the loader is there does not use up the one start; a start that ran does',
        s10a === 'no loader' && s10b === 'started' && s10c === 'already' && ovRan.length === 1, s10a + ' ' + s10b + ' ' + s10c);

    // Chat Manager: Overlay: start by itself... - On or Off picked, set
    // through the loader as chatoverlay -AutoStart sets it; Off closes a
    // running overlay too. PowerShell stood in for, answering as the script
    // prints.
    const ovRunPs = su._runPs;
    const asRan = [], asSaid = [], asPicks = [];
    let asPick = 'on', asStop = 'overlay closed', asWorks = true;
    su._runPs = async (exe, loader, cmd) => {
        asRan.push(exe + ':' + cmd + ':' + loader);
        if (/^chatoverlay -AutoStart (on|off)\b/.test(cmd)) {
            const w = /-AutoStart (on|off)/.exec(cmd)[1];
            return { ok: true, stdout: asWorks ? '  start with every shell and VS Code window: ' + w + '\r\n' : 'Set-ChatOverlayConfig : Access to the path is denied.\r\n' };
        }
        if (/^chatoverlay -Stop\b/.test(cmd)) return { ok: true, stdout: '  ' + asStop + '\r\n' };
        return { ok: true, stdout: '' };
    };
    stub.window.showQuickPick = async (items, o) => { asPicks.push(o && o.placeHolder); return items.find(i => i.value === asPick); };
    stub.window.showInformationMessage = async (m) => { asSaid.push(m); };
    stub.window.showWarningMessage = async (m) => { asSaid.push('warn:' + m); };
    const asRun = async (x) => {
        asRan.length = 0; asSaid.length = 0; asPicks.length = 0;
        asPick = x.pick === undefined ? 'on' : x.pick; asStop = x.stop || 'overlay closed'; asWorks = x.works !== false;
        ext._overlayIo.platform = () => x.platform || 'win32';
        return ext._overlayAutoStart();
    };
    const ldr = path.join(ov, su.LOADER);
    logged.length = 0;
    const as1 = await asRun({ pick: 'on' });
    check('autostart: On - chatoverlay -AutoStart on through the tool folder\'s loader, nothing stopped, said, and logged',
        as1 === 'on' && asRan.length === 1 && asRan[0] === 'PS:chatoverlay -AutoStart on *>&1 | Out-String -Width 200:' + ldr &&
        asPicks[0] === ext._texts.autoStartAsk && asSaid.join() === ext._texts.autoStartOn && logged.includes('overlay autoStart: on'),
        as1 + ' ' + asRan.join(' / ') + ' | ' + asSaid.join(' | '));
    const as2 = await asRun({ pick: 'off' });
    const as2Ran = asRan.slice(), as2Said = asSaid.slice();
    const as3 = await asRun({ pick: 'off', stop: 'asked the overlay to close - it has not yet; data/logs/overlay.log may say why' });
    const as3Said = asSaid.slice();
    const as4 = await asRun({ pick: 'off', stop: 'the overlay is not running' });
    check('autostart: Off - set off, then chatoverlay -Stop closes a running overlay; what it did said',
        as2 === 'off, the overlay closed' && as2Ran.length === 2 && as2Ran[0] === 'PS:chatoverlay -AutoStart off *>&1 | Out-String -Width 200:' + ldr &&
        as2Ran[1] === 'PS:chatoverlay -Stop *>&1 | Out-String -Width 200:' + ldr && as2Said.join() === ext._texts.autoStartOff('closed') &&
        as3 === 'off, the overlay not yet' && as3Said.join() === ext._texts.autoStartOff('not yet') &&
        as4 === 'off, the overlay not running' && asSaid.join() === ext._texts.autoStartOff('not running') &&
        /, and was closed\.$/.test(ext._texts.autoStartOff('closed')) && /by itself\.$/.test(ext._texts.autoStartOff('not running')),
        as2 + ' ' + as3 + ' ' + as4 + ' | ' + as2Ran.join(' / ') + ' | ' + as2Said.join(' | '));
    const as5 = await asRun({ pick: 'off', works: false });
    check('autostart: the script not saying it took - failed, said, and no -Stop run', as5 === 'off - failed' && asRan.length === 1 &&
        asSaid.join() === 'warn:' + ext._texts.autoStartFailed, as5 + ' ' + asRan.join(' / ') + ' | ' + asSaid.join(' | '));
    const as6 = await asRun({ pick: null });
    const as6Ran = asRan.length, as6Said = asSaid.length;
    cfgVals['chatManager.folder'] = path.join(sbx, 'no-loader');
    const as7 = await asRun({ pick: 'off' });
    cfgVals['chatManager.folder'] = ov;
    const as7Picks = asPicks.length, as7Said = asSaid.join();
    const as8 = await asRun({ pick: 'off', platform: 'linux' });
    check('autostart: nothing picked does nothing; no loader in the tool folder - said, before any question; no panel to draw - said',
        as6 === 'nothing picked' && as6Ran === 0 && as6Said === 0 &&
        as7 === 'no loader in ' + path.join(sbx, 'no-loader') && as7Picks === 0 && asRan.length === 0 &&
        as7Said === 'warn:' + ext._texts.autoStartNoLoader(path.join(sbx, 'no-loader')) &&
        as8 === 'no panel' && asSaid.join() === ext._texts.autoStartNoPanel,
        as6 + ' / ' + as7 + ' / ' + as8 + ' ' + asSaid.join(' | '));
    const asPkg = (pkg.contributes.commands || []).find(c => c.command === 'chatManager.overlayAutoStart') || {};
    check('autostart: in the palette as Chat Manager: Overlay: start by itself...', asPkg.title === 'Overlay: start by itself...' && asPkg.category === 'Chat Manager',
        JSON.stringify(asPkg));

    // Chat Manager: Phone alerts... - chatnotify -Setup through the loader,
    // as a terminal opens the window; the script's one "phone setup" line
    // decides what is said. Windows only: elsewhere it only says so.
    // PowerShell stood in for, answering as Start-ChatqPhoneSetup prints.
    const phRan = [];
    let phSays = '';
    su._runPs = async (exe, loader, cmd) => {
        phRan.push(exe + ':' + cmd + ':' + loader);
        if (phSays === 'throw') throw new Error('boom');
        return { ok: true, stdout: 'WARNING: x\r\n' + phSays + '\r\n' };
    };
    const phRun = async (x) => {
        phRan.length = 0; asSaid.length = 0;
        phSays = x.says === undefined ? '  phone setup opens in its own window' : x.says;
        ext._overlayIo.platform = () => x.platform || 'win32';
        return ext._phoneAlerts();
    };
    logged.length = 0;
    const ph1 = await phRun({});
    check('phone alerts: chatnotify -Setup, once, through the tool folder\'s loader; a window that came is the answer - nothing said, logged',
        ph1 === 'phone setup opens in its own window' && phRan.length === 1 && phRan[0] === 'PS:chatnotify -Setup *>&1 | Out-String -Width 200:' + ldr &&
        asSaid.length === 0 && logged.includes('phone alerts: phone setup opens in its own window'),
        ph1 + ' ' + phRan.join(' / ') + ' | ' + asSaid.join(' | '));
    const ph2 = await phRun({ says: '  phone setup is already open' });
    const ph2Said = asSaid.join();
    const ph3 = await phRun({ says: '  phone setup did not open: WPF would not load' });
    const ph3Said = asSaid.join();
    const ph4 = await phRun({ says: '' });
    const ph4Said = asSaid.join();
    let ph5, phThrew = false;
    try { ph5 = await phRun({ says: 'throw' }); } catch (e) { phThrew = true; }
    const ph5Said = asSaid.join();
    check('phone alerts: already open - said; did not open - said with the script\'s reason; no word, or PowerShell failing - failed, said, never thrown',
        ph2 === 'already open' && /^The phone alerts window is already open/.test(ph2Said) &&
        ph3 === 'failed - phone setup did not open: WPF would not load' && /^warn:The phone alerts window: phone setup did not open: WPF would not load\./.test(ph3Said) &&
        ph4 === 'failed - no word from the script' && /^warn:.*did not open\./.test(ph4Said) &&
        /^failed - boom$/.test(ph5) && !phThrew && /^warn:/.test(ph5Said),
        [ph2, ph3, ph4, ph5].join(' / ') + ' | ' + [ph2Said, ph3Said, ph4Said, ph5Said].join(' | '));
    const ph6 = await phRun({ platform: 'darwin' });
    const ph6Ran = phRan.length, ph6Said = asSaid.join();
    const ph7 = await phRun({ platform: 'linux' });
    const ph7Ran = phRan.length;
    cfgVals['chatManager.folder'] = path.join(sbx, 'no-loader');
    const ph8 = await phRun({});
    cfgVals['chatManager.folder'] = ov;
    check('phone alerts: off Windows no PowerShell, only that the window is Windows-only and the terminal command; no loader - said, no PowerShell',
        ph6 === 'Windows only' && ph7 === 'Windows only' && ph6Ran === 0 && ph7Ran === 0 && /Windows-only.*chatnotify -Setup/.test(ph6Said) &&
        !/^warn:/.test(ph6Said) && ph8 === 'no loader in ' + path.join(sbx, 'no-loader') && phRan.length === 0 &&
        /^warn:.*not in .*Install terminal commands/.test(asSaid.join()),
        ph6 + ' / ' + ph7 + ' / ' + ph8 + ' | ' + ph6Said + ' | ' + asSaid.join());
    const phCmds = pkg.contributes.commands || [];
    // found by its id: commands added after it (0.9.0's auto-continue) come later
    const phPkg = phCmds.filter(c => c.command === 'chatManager.phoneAlerts')[0] || {};
    check('phone alerts: in the palette as Chat Manager: Phone alerts...',
        phPkg.command === 'chatManager.phoneAlerts' && phPkg.title === 'Phone alerts...' && phPkg.category === 'Chat Manager', JSON.stringify(phPkg));

    // Chat Manager: Auto-continue cut-off chats... (0.9.0) - chatq
    // -AutoContinue on|ask|off through the loader; the script's own "auto-
    // continue: on|ask|off" line says whether it took. PowerShell stood in for.
    const acRan = [];
    let acWorks = true;
    su._runPs = async (exe, loader, cmd) => {
        acRan.push(exe + ':' + cmd + ':' + loader);
        const w = /-AutoContinue (on|ask|off)/.exec(cmd);
        if (acWorks === 'throw') throw new Error('boom');
        return { ok: true, stdout: acWorks && w ? '  auto-continue: ' + w[1] + ' - a chat the limit cuts off gets "continue"\r\n' : 'chatq : The term is not recognized\r\n' };
    };
    const acRun = async (x) => {
        acRan.length = 0; asSaid.length = 0; asPicks.length = 0;
        asPick = x.pick === undefined ? 'on' : x.pick; acWorks = x.works === undefined ? true : x.works;
        ext._overlayIo.platform = () => x.platform || 'win32';
        return ext._autoContinue();
    };
    logged.length = 0;
    const ac1 = await acRun({ pick: 'on' });
    const ac1Ran = acRan.slice(), ac1Said = asSaid.join(), ac1Pick = asPicks[0];
    const ac2 = await acRun({ pick: 'off', platform: 'linux' });
    const ac2Ran = acRan.slice(), ac2Said = asSaid.join();
    const ac2a = await acRun({ pick: 'ask' });
    const ac2aRan = acRan.slice(), ac2aSaid = asSaid.join();
    check('auto-continue: Continue, Ask and Leave run chatq -AutoContinue on|ask|off through the tool folder\'s loader, on every platform; the script\'s line checked; said and logged',
        ac1 === 'on' && ac1Ran.length === 1 && ac1Ran[0] === 'PS:chatq -AutoContinue on *>&1 | Out-String -Width 200:' + ldr && ac1Pick === ext._autoTexts.ask &&
        ac1Said === 'Chats the usage limit cuts off are now continued by chatq, a minute after the reset.' && logged.includes('auto-continue: on') &&
        ac2 === 'off' && ac2Ran[0] === 'PS:chatq -AutoContinue off *>&1 | Out-String -Width 200:' + ldr && ac2Said === 'chatq no longer continues chats the limit cuts off.' &&
        ac2a === 'ask' && ac2aRan[0] === 'PS:chatq -AutoContinue ask *>&1 | Out-String -Width 200:' + ldr && ac2aSaid === ext._autoTexts.asks,
        [ac1, ac2, ac2a].join(' / ') + ' | ' + ac1Ran.join(' / ') + ' | ' + ac1Said + ' | ' + ac2Said + ' | ' + ac2aSaid);
    const ac3 = await acRun({ pick: 'off', works: false });
    const ac3Said = asSaid.join();
    let ac4, acThrew = false;
    try { ac4 = await acRun({ pick: 'on', works: 'throw' }); } catch (e) { acThrew = true; }
    const ac4Said = asSaid.join();
    const ac5 = await acRun({ pick: null });
    const ac5Ran = acRan.length;
    check('auto-continue: the script not saying it took, or PowerShell failing - failed and said, never thrown; nothing picked does nothing',
        ac3 === 'off - failed' && ac3Said === 'warn:Auto-continue could not be set. Chat Manager: Show log has the details.' &&
        /^failed - boom$/.test(ac4) && !acThrew && ac4Said === ac3Said && ac5 === 'nothing picked' && ac5Ran === 0,
        [ac3, ac4, ac5].join(' / ') + ' | ' + ac3Said + ' | ' + ac4Said);
    const acPkg = phCmds.find(c => c.command === 'chatManager.autoContinue') || {};
    check('auto-continue: in the palette as Chat Manager: Auto-continue cut-off chats...', acPkg.title === 'Auto-continue cut-off chats...' && acPkg.category === 'Chat Manager',
        JSON.stringify(acPkg));
    // the offer after a run auto-continue made: its own words, Show it or a reload
    const acReq = { kind: 'ran', title: 'Parser rewrite', sessionId: '11111111-1111-4111-8111-111111111111', oldProcess: 'live', auto: true };
    const acFresh = ext._message(acReq, true), acReload = ext._message(acReq, false), acPlain = ext._message(Object.assign({}, acReq, { auto: false }), true);
    check('message(): a run auto-continue made is worded as one - Show it, or Reload where it cannot be shown; others as before',
        acFresh === 'chatq continued "Parser rewrite" after the usage limit reset, and this window still has it open. Show it?' &&
        acReload === 'chatq continued "Parser rewrite" after the usage limit reset, and this window still has it open. Reload to show it?' &&
        acPlain === 'A queued prompt ran in "Parser rewrite", which this window still has open. Show it?', acFresh + ' | ' + acReload + ' | ' + acPlain);
    su._runPs = ovRunPs;
    delete cfgVals['chatManager.folder'];
    // the activations below start it through the same stand-ins: never a
    // real PowerShell from a test
    ext._overlayIo.platform = () => 'win32';
    ext._overlayIo.readFile = realIo.readFile;
    ext._overlayIo.lockHeld = () => false;
    ovRan.length = 0;

    // runs of the setup, one at a time per window, a palette one after a
    // start's rather than dropped
    const realSetUp = su.setUp;
    const runs = [];
    su.setUp = async (o) => { runs.push(o.force ? 'force' : 'start'); await new Promise(r => setTimeout(r, 15)); return 'none'; };
    const ctxR = { extensionPath: sbx };
    const pr1 = ext._runSetup(ctxR, false);
    const pr2 = ext._runSetup(ctxR, false);
    const pr3 = ext._runSetup(ctxR, true);
    await Promise.all([pr1, pr2, pr3]);
    su.setUp = realSetUp;
    check('setup runs one at a time; a second start joins the first, the palette\'s runs after it', runs.join() === 'start,force', runs.join());

    // activation: the old extension left to handle requests where it watches
    // the same file, and one window offering it away
    const watched = [];
    const realWatch = fs.watchFile;
    fs.watchFile = (f) => { watched.push(f); };
    const registered = [], serialized = [];
    stub.commands.registerCommand = (id) => { registered.push(id); return { dispose() { } }; };
    stub.window.registerWebviewPanelSerializer = (type) => { serialized.push(type); return { dispose() { } }; };
    const acts = [];
    stub.commands.executeCommand = async (c, a) => { acts.push(c + (a ? ':' + a : '')); };
    const asks = [];
    stub.window.showWarningMessage = async (m, ...b) => { asks.push(m); return b[0]; };
    stub.window.showInformationMessage = async (m, ...b) => { asks.push(m); return undefined; };
    cfgVals['chatManagerReload.signalFile'] = path.join(tool, 'data', 'reload-request');
    oldHere = true;
    const ctxA = { subscriptions: [], extensionPath: path.join(sbx, 'no-payload'), globalState: context.globalState };
    ext.activate(ctxA);
    await settle();
    // the overlay waits on the setup's run, which takes a moment of its own
    for (let i = 0; i < 100 && !ovRan.length; i++) await tick();
    const ovFirst = ovRan.slice();
    check('the old extension installed on the same file: none of it watched here, and the old one offered away',
        watched.length === 0 && asks[0] === ext._texts.oldThere && acts.includes('workbench.extensions.uninstallExtension:phal40lax78.chat-manager-reload') &&
        asks[1] === ext._texts.oldGone, acts.join() + ' | ' + asks.join(' | '));
    asks.length = 0;
    check('another window within 10 minutes does not ask again', (await ext._askToRemoveOld()) === 'elsewhere' && asks.length === 0);
    cfgVals['chatManager.folder'] = path.join(sbx, 'tool2');
    ext.activate(ctxA);
    await settle();
    check('the old one on another file than chatManager.folder\'s: this one handles its own - run-state and the overlay\'s reload answers too', !ext._oldWatchesMine() && watched.length === 4 &&
        watched[0] === path.join(sbx, 'tool2', 'data', 'reload-request') && watched[2] === path.join(sbx, 'tool2', 'data', 'run-state') &&
        watched[3] === ext._answerFile(), watched.join());
    watched.length = 0;
    delete cfgVals['chatManager.folder'];
    oldHere = false;
    ext.activate(ctxA);
    await settle();
    check('without it, both request files are watched, in the tool folder, data/run-state beside them, and the overlay\'s answer to a reload', watched.length === 4 &&
        watched[0] === path.join(tool, 'data', 'reload-request') && watched[1] === path.join(tool, 'data', 'open-request') &&
        watched[2] === path.join(tool, 'data', 'run-state') && watched[3] === ext._answerFile(), watched.join());
    check('and the palette has every command - the autostart switch among them',
        ['chatManager.installTerminal', 'chatManager.showLog', 'chatManager.openChat', 'chatManager.overlayAutoStart', 'chatManager.phoneAlerts'].every(c => registered.includes(c)),
        registered.join());
    check('and auto-continue\'s, 0.9.0', registered.includes('chatManager.autoContinue'), registered.join());
    check('and Watch the running queued prompt, and the watch panel\'s serializer, so a reload brings one back',
        registered.includes('chatManager.watchRun') && serialized.includes('chatManager.watch'), registered.join() + ' / ' + serialized.join());
    check('and Show the queue, the queue item\'s click - registered, and in the palette',
        registered.includes('chatManager.showQueue') && cmds.includes('chatManager.showQueue'), registered.join());
    await settle();
    check('activation, the loader in place: the overlay started once, from the tool folder\'s loader - however often it runs',
        ovFirst.join() === 'PS:Start-ChatOverlayAuto:' + path.join(tool, su.LOADER) && ovRan.length === 1, ovFirst.join() + ' / ' + ovRan.join());

    // a setup that never settles - its profile question left unanswered -
    // holds up no overlay whose loader is in place
    // - onReady called as the real setUp calls it where the loader is in
    // place and nothing is to be copied: before its first await
    let setupDone = null;
    su.setUp = (o) => { o.onReady(); return new Promise(r => { setupDone = r; }); };
    ovRan.length = 0;
    ext.activate({ subscriptions: [], extensionPath: sbx, globalState: context.globalState });
    for (let i = 0; i < 50 && !ovRan.length; i++) await tick();
    const ovWhileAsking = ovRan.slice();
    const askingStill = !!setupDone;
    if (setupDone) setupDone('none');
    await settle();
    check('activation, the loader in place and the setup waiting on its question: the overlay started at once, and only once',
        askingStill && ovWhileAsking.join() === 'PS:Start-ChatOverlayAuto:' + path.join(tool, su.LOADER) && ovRan.length === 1,
        askingStill + ' ' + ovWhileAsking.join() + ' / ' + ovRan.join());
    // a first install: no loader until the setup's copy puts it there, and
    // then the profile question, which nobody answers
    const first = path.join(sbx, 'first');
    fs.mkdirSync(first, { recursive: true });
    cfgVals['chatManager.folder'] = first;
    const firstOrder = [];
    let firstGo = null;
    su.setUp = async (o) => {
        firstOrder.push('setup');
        await tick();
        fs.writeFileSync(path.join(o.folder, su.LOADER), "$script:ChatVersion = '0.7.1'\r\n");
        firstOrder.push('copied');
        o.onReady();
        await new Promise(r => { firstGo = r; });
        return 'install';
    };
    const ranPs = su._runPs;
    su._runPs = async (...a) => { firstOrder.push('overlay'); return ranPs(...a); };
    ovRan.length = 0;
    ext.activate({ subscriptions: [], extensionPath: sbx, globalState: context.globalState });
    for (let i = 0; i < 50 && !ovRan.length; i++) await tick();
    await settle();
    const firstAsking = !!firstGo;
    const firstRan = ovRan.join();
    if (firstGo) firstGo();
    await settle();
    su._runPs = ranPs;
    su.setUp = realSetUp;
    delete cfgVals['chatManager.folder'];
    check('activation on a first install: the overlay started once the setup put the loader there, from it, once - with the profile question still unanswered',
        firstAsking && firstOrder.join() === 'setup,copied,overlay' && firstRan === 'PS:Start-ChatOverlayAuto:' + path.join(first, su.LOADER) &&
        ovRan.length === 1, firstAsking + ' ' + firstOrder.join() + ' / ' + ovRan.join());
    // the real setUp from here, each run's promise kept to be waited on, and
    // the version of the loader the overlay was started from, as it was then
    const setupRuns = [];
    su.setUp = (o) => { const p = realSetUp(o); setupRuns.push(p); return p; };
    su._inGitCheckout = (f) => realGit(f, sbx);
    su._profileStep = async () => { };
    const startedFrom = [];
    su._runPs = async (exe, loader, cmd) => { startedFrom.push(su._readVersion(fs.readFileSync(loader, 'latin1'))); return ranPs(exe, loader, cmd); };
    const activateOn = async (folder) => {
        cfgVals['chatManager.folder'] = folder;
        setupRuns.length = 0; startedFrom.length = 0; ovRan.length = 0;
        ext.activate({ subscriptions: [], extensionPath: ext71, globalState: context.globalState });
        for (let i = 0; i < 50 && !setupRuns.length; i++) await tick();
        const r = await setupRuns[0];
        await settle();
        return r;
    };
    // an update: 0.6.0 in place, and this window's setup copying 0.7.1 over it
    const upd = path.join(sbx, 'upd');
    fs.mkdirSync(path.join(upd, 'data'), { recursive: true });
    fs.writeFileSync(path.join(upd, su.LOADER), "$script:ChatVersion = '0.6.0'\r\n");
    const updR = await activateOn(upd);
    check('activation during an update: the overlay not started from the old loader, only once the copy was whole - from the new one, once',
        updR === 'update' && startedFrom.join() === '0.7.1' && ovRan.join() === 'PS:Start-ChatOverlayAuto:' + path.join(upd, su.LOADER),
        updR + ' ' + startedFrom.join() + ' / ' + ovRan.join());
    // another window holds the install lock: it may be copying right now
    const els = path.join(sbx, 'els');
    fs.mkdirSync(path.join(els, 'data'), { recursive: true });
    fs.writeFileSync(path.join(els, su.LOADER), "$script:ChatVersion = '0.6.0'\r\n");
    fs.writeFileSync(path.join(els, 'data', 'install.lock'), '1');
    const elsR = await activateOn(els);
    check('activation while another window copies an update (elsewhere): the overlay not started at all - that window starts it',
        elsR === 'elsewhere' && ovRan.length === 0 && startedFrom.length === 0, elsR + ' ' + ovRan.join());
    su._runPs = ranPs;
    su._inGitCheckout = realGit;
    su._profileStep = realStep;
    // a run with an onReady that joins a setup already going - the palette's
    // - is called once that one's loader is ready, or at once where it was
    let joinGo = null;
    su.setUp = async (o) => { await tick(); o.onReady(); await new Promise(r => { joinGo = r; }); return 'none'; };
    const ctxJ = { extensionPath: sbx };
    const joined = [];
    const j1 = ext._runSetup(ctxJ, true);
    ext._runSetup(ctxJ, false, () => joined.push('waited'));
    const joinedEarly = joined.length;
    for (let i = 0; i < 50 && !joinGo; i++) await tick();
    ext._runSetup(ctxJ, false, () => joined.push('at once'));
    const joinedReady = joined.join();
    if (joinGo) joinGo();
    await j1;
    su.setUp = realSetUp;
    delete cfgVals['chatManager.folder'];
    check('setup: an onReady joining a run already going is called once that run\'s loader is ready - at once where it was ready already',
        joinedEarly === 0 && joinedReady === 'waited,at once', joinedEarly + ' ' + joinedReady);
    Object.assign(ext._overlayIo, realIo);
    su._hosts = real.hosts;
    su._runPs = real.runPs;
    fs.watchFile = realWatch;
    delete cfgVals['chatManagerReload.signalFile'];
    fs.rmSync(sbx, { recursive: true, force: true });

    // --- a new version installed, and reloads held to this window's chats -----
    // safe-restart.js: the notice a new install brings, the wait for this
    // window's chats to go idle, and the reloads chatq asks for - with stand-
    // ins for the script's verdict, the clock, the status bar, VS Code's list
    // of installed extensions and the restart command. Nothing restarts.
    {
        const sr = safe;
        const srDir = path.join(dir, 'ext-safe');
        const exts = path.join(srDir, 'exts');
        const mineDir = path.join(exts, 'redaechan.charlie-and-the-chat-factory-0.8.1');
        fs.mkdirSync(mineDir, { recursive: true });
        const list = (version, stamp) => fs.writeFileSync(path.join(exts, 'extensions.json'), JSON.stringify([
            { identifier: { id: 'anthropic.claude-code' }, version: '2.1.283', relativeLocation: 'anthropic.claude-code-2.1.283-win32-x64', metadata: { installedTimestamp: 5 } },
            { identifier: { id: 'redaechan.charlie-and-the-chat-factory' }, version, relativeLocation: 'redaechan.charlie-and-the-chat-factory-' + version, metadata: { installedTimestamp: stamp, pinned: true, source: 'vsix' } }]));
        list('0.8.1', 1000);
        const srCalls = [], srAsked = [], items = [], srWatched = [], srHeard = [];
        const srAnswer = { info: undefined, warn: undefined };
        fs.watchFile = (f, o, cb) => { srWatched.push([f, cb]); };
        stub.commands.executeCommand = async (c) => { srCalls.push(c); };
        stub.commands.registerCommand = (id) => ({ dispose() { } });
        stub.window.showInformationMessage = async (m, ...b) => { srAsked.push({ m, b, kind: 'info' }); return b.includes(srAnswer.info) ? srAnswer.info : undefined; };
        stub.window.showWarningMessage = async (m, ...b) => { srAsked.push({ m, b, kind: 'warn' }); return b.includes(srAnswer.warn) ? srAnswer.warn : undefined; };
        stub.window.createStatusBarItem = () => { const it = { text: '', shown: false, disposed: false, show() { this.shown = true; }, dispose() { this.disposed = true; } }; items.push(it); return it; };
        stub.StatusBarAlignment = { Left: 1, Right: 2 };
        stub.extensions.onDidChange = (fn) => { srHeard.push(fn); return { dispose() { } }; };
        const srReset = () => { srCalls.length = 0; srAsked.length = 0; srAnswer.info = undefined; srAnswer.warn = undefined; };
        // a chat's transcript, titled as Claude titles it
        const SA = 'abcdef12-3456-4789-8abc-def123456789', SB = 'fedcba98-7654-4321-8fed-cba987654321', SC = '0a0a0a0a-0b0b-4c0c-8d0d-0e0e0e0e0e0e';
        const tA = path.join(srDir, SA + '.jsonl');
        fs.writeFileSync(tA, '{"type":"user","message":{"role":"user","content":"hello"}}\n{"type":"ai-title","aiTitle":"Refactor the parser"}\n');
        const chat = (sid, why, written, file) => ({ sessionId: sid, pids: [7], file: file || null, why, written: !!written });
        let verdict = noWork;
        sr._hostWork = async (pid) => verdict(pid);
        const as = (chats) => async () => ({ hostPid: process.pid, known: true, chats });

        // the pure parts
        check('safe restart: another version installed, newer or older, is said by its version; the same one again only by another install time',
            sr._installKey({ version: '0.8.1', stamp: 1 }, { version: '0.9.0', stamp: 2 }) === '0.9.0' &&
            sr._installKey({ version: '0.8.1', stamp: 1 }, { version: '0.8.0', stamp: 2 }) === '0.8.0' &&
            sr._installKey({ version: '0.8.1', stamp: 1 }, { version: '0.8.1', stamp: 2 }) === '0.8.1@2' &&
            sr._installKey({ version: '0.8.1', stamp: 1 }, { version: '0.8.1', stamp: 1 }) === '' &&
            sr._installKey({ version: '0.8.1', stamp: null }, { version: '0.8.1', stamp: 2 }) === '' &&
            sr._installKey({ version: '0.8.1', stamp: 1 }, null) === '');
        check('safe restart: its own ID is the manifest\'s publisher.name',
            sr.ID === pkg.publisher + '.' + pkg.name, sr.ID + ' / ' + pkg.publisher + '.' + pkg.name);
        check('safe restart: this extension\'s entry in VS Code\'s list, by its id in any case, the newest where two',
            sr._entryOf([{ identifier: { id: 'x.y' }, version: '1' }, { identifier: { id: 'Redaechan.Claude-Codex-Chat-Manager' }, version: '2', metadata: { installedTimestamp: 1 } },
                { identifier: { id: 'redaechan.charlie-and-the-chat-factory' }, version: '3', metadata: { installedTimestamp: 9 } }], 'redaechan.charlie-and-the-chat-factory').version === '3' &&
            sr._entryOf(null, 'a.b') === null);
        const hwGood = '{"hostPid":12,"known":true,"chats":[{"sessionId":"' + SA + '","pids":[7],"file":null,"why":"background","written":false}]}';
        check('safe restart: the script\'s verdict - the last JSON line, noise before it ignored; a field of the wrong kind is none',
            (sr._parseHostWork('WARNING: x\r\n' + hwGood + '\r\n') || {}).hostPid === 12 &&
            sr._parseHostWork('{"hostPid":12,"known":true,"chats":[]}').chats.length === 0 &&
            sr._parseHostWork(hwGood.replace('background', 'napping')) === null && sr._parseHostWork(hwGood.replace('"written":false', '"written":"no"')) === null &&
            sr._parseHostWork('{"hostPid":"12","known":true,"chats":[]}') === null && sr._parseHostWork('') === null);
        const hwCmd = sr._hostWorkCommand(4321, "D:\\h's");
        check('safe restart: the look asks Get-ChatHostWork of this host\'s pid, the Claude home quoted',
            /Get-ChatHostWork -HostPid 4321 -ConfigDir 'D:\\h''s'/.test(hwCmd) && /ConvertTo-ChatHostWorkJson/.test(hwCmd), hwCmd);
        const hwNote = sr._hostWorkCommand(4321, '', 1700000000000.7);
        const hwStart = sr._hostStart();
        check('safe restart: the look leaves its note with this host\'s start, after the line it prints - only where the scripts have Save-ChatHostWorkNote; no start known, 0',
            /\(ConvertTo-ChatHostWorkJson \$r\)\); if \(Get-Command Save-ChatHostWorkNote -EA SilentlyContinue\) \{ Save-ChatHostWorkNote \$r -HostStart 1700000000000 \} \}$/.test(hwNote) &&
            /-HostStart 0 \}/.test(hwCmd) && /-HostStart 0 \}/.test(sr._hostWorkCommand(1, '', NaN)) && /-HostStart 0 \}/.test(sr._hostWorkCommand(1, '', -5)) &&
            Number.isInteger(hwStart) && hwStart > 0 && hwStart <= Date.now(), hwNote + ' | ' + hwStart);
        const wk = sr._workingOf({ chats: [chat(SA, 'background'), chat(SB, '', true), chat(SC, '', false)] }, SB);
        check('safe restart: working - a background-only chat counts; one only written this minute counts, unless it is the run\'s own chat; an idle one never',
            wk.map(c => c.sessionId).join() === SA && sr._workingOf({ chats: [chat(SB, '', true)] }).length === 1 &&
            sr._workingOf({ chats: [chat(SC, '')] }).length === 0);

        // activation: what runs, and both ways a new install is heard of
        const ctxS = { subscriptions: [], extensionPath: mineDir, extension: { id: 'redaechan.charlie-and-the-chat-factory', packageJSON: { version: '0.8.1' } } };
        sr.activate(ctxS);
        const run0 = sr._running();
        check('safe restart: at activation, the version it runs and its folder\'s install time; VS Code\'s event and its list on disk both listened to',
            run0.version === '0.8.1' && run0.stamp === 1000 && srHeard.length === 1 && srWatched.length === 1 &&
            srWatched[0][0] === path.join(exts, 'extensions.json'), JSON.stringify(run0) + ' ' + srWatched.map(w => w[0]).join());
        srReset();
        check('safe restart: nothing new installed - nothing said', (await sr._checkInstall()) === 'none' && srAsked.length === 0);

        // a newer version, nothing working here: the short notice; Later
        list('0.9.0', 2000);
        verdict = noWork;
        const n1 = await sr._checkInstall();
        const n1Said = srAsked.slice();
        srReset();
        const n1b = await sr._checkInstall();
        check('safe restart: a newer version, nothing working here - the short notice; Later reloads nothing, and that version is not said again',
            n1 === 'later' && n1Said.length === 1 && n1Said[0].m === sr.texts.short('0.9.0') && n1Said[0].m === 'Charlie and the Chat Factory 0.9.0 is installed - reload the window to load it.' &&
            n1Said[0].b.join() === 'Reload the window,Later' && n1b === 'none' && srAsked.length === 0 && !srCalls.includes(sr.RESTART),
            n1 + ' ' + JSON.stringify(n1Said) + ' ' + n1b);

        // the same version installed again with other files, two chats working:
        // the long notice with their titles; Restart now
        list('0.8.1', 3000);
        verdict = as([chat(SA, 'turn', true, tA), chat(SB, 'background'), chat(SC, '')]);
        srAnswer.warn = sr.NOW;
        const n2 = await sr._checkInstall();
        check('safe restart: installed again, two chats working - the long notice naming them, a background-only one too; Reload now reloads the window - never Restart Extension Host, which loads nothing new',
            n2 === 'restarted' && srAsked.length === 1 && srAsked[0].kind === 'warn' &&
            srAsked[0].m === 'Charlie and the Chat Factory 0.8.1 is installed. Loading it reloads this window, which stops the 2 chats working here: "Refactor the parser" and a chat (fedcba98) (background work running).' &&
            srAsked[0].b.join() === 'Reload when they\'re idle,Reload now,Later' && srCalls.join() === 'workbench.action.reloadWindow',
            n2 + ' ' + JSON.stringify(srAsked) + ' ' + srCalls.join());
        srReset();
        // a look that fails: said without names, never taken for nothing working
        list('0.9.2', 3500);
        verdict = async () => null;
        const n3 = await sr._checkInstall();
        check('safe restart: the chats here could not be checked - the long notice, never the short one; Later restarts nothing',
            n3 === 'later' && srAsked.length === 1 && srAsked[0].m === sr.texts.unknown('0.9.2') && srAsked[0].b.length === 3 && !srCalls.length,
            n3 + ' ' + JSON.stringify(srAsked));
        srReset();
        // the short notice clicked hours later, a chat working by then: asked
        // again, the long way
        list('0.9.3', 3600);
        let looks = 0;
        verdict = async () => (++looks === 1 ? { hostPid: 1, known: true, chats: [] } : { hostPid: 1, known: true, chats: [chat(SA, 'prompt', false, tA)] });
        srAnswer.info = sr.GO;
        const n4 = await sr._checkInstall();
        check('safe restart: Restart extensions clicked once a chat began to work - no restart; the long notice instead, naming it',
            n4 === 'later' && srAsked.length === 2 && srAsked[0].kind === 'info' && srAsked[1].kind === 'warn' &&
            /stops the chat working here: "Refactor the parser" \(waiting on you\)\.$/.test(srAsked[1].m) && !srCalls.length,
            n4 + ' ' + JSON.stringify(srAsked));
        srReset();
        list('0.9.4', 3700);
        verdict = noWork;
        srAnswer.info = sr.GO;
        const n5 = await sr._checkInstall();
        check('safe restart: Restart extensions, still nothing working - the extensions restart', n5 === 'restarted' && srCalls.join() === sr.RESTART, n5 + ' ' + srCalls.join());
        srReset();

        // Reload when they're idle: the status bar, and a look every poll; the
        // registry's last word before the reload stood in for (movedSince)
        let clock = 1e9;
        sr._now = () => clock;
        let moved = '';
        const movedWas = sr._movedSince;
        sr._movedSince = () => moved;
        sr.timing.poll = 1e9;   // the looks below are made by hand
        list('0.9.5', 3800);
        verdict = as([chat(SB, 'background')]);
        srAnswer.warn = sr.WAIT;
        const w0 = await sr._checkInstall();
        await tick();
        const item = items[items.length - 1];
        const wText0 = item && item.text;
        clock += 100000;
        const w1 = await sr._poll();
        verdict = as([chat(SB, ''), chat(SC, '')]);
        const w2 = await sr._poll();
        clock += 30000;
        const w3 = await sr._poll();
        // a queued run going into a chat of the window; then a turn, only written
        verdict = as([chat(SB, 'run')]);
        clock += 10000;
        const w4 = await sr._poll();
        verdict = as([chat(SC, '', true)]);
        clock += 10000;
        const w5 = await sr._poll();
        verdict = async () => null;
        clock += 10000;
        const w6 = await sr._poll();
        const beforeIdle = srCalls.slice();
        verdict = as([chat(SB, ''), chat(SC, '')]);
        clock += 10000;
        const w7 = await sr._poll();
        clock += 50000;
        const w8 = await sr._poll();
        const at59 = srCalls.slice();
        clock += 10000;
        // idle 60 s by the looks, but a turn began since the last one began
        moved = 'fedcba98 busy';
        const w9a = await sr._poll();
        const afterMoved = srCalls.slice();
        moved = '';
        clock += 30000;
        const w9b = await sr._poll();
        clock += 60000;
        const w9 = await sr._poll();
        check('safe restart: Reload when they\'re idle - a status-bar item that cancels, saying how many chats work',
            w0 === 'waiting' && !!item && item.shown && item.command === sr.CANCEL && wText0 === '$(debug-restart) Chat Manager: reloads when 1 chat is idle' &&
            /Click to cancel/.test(item.tooltip), w0 + ' ' + wText0);
        check('safe restart: it waits while any chat works - background only, a queued run going in, a turn only written, a look that failed',
            w1 === 'working' && w4 === 'working' && w5 === 'working' && w6 === 'unknown' && !beforeIdle.length && w2 === 'idle' && w3 === 'idle',
            [w1, w2, w3, w4, w5, w6].join());
        check('safe restart: and reloads only once every chat here was idle 60 s straight and the registry, read once more, says so too - the window; the item gone',
            w7 === 'idle' && w8 === 'idle' && !at59.length && w9a === 'working' && !afterMoved.length && w9b === 'idle' && w9 === 'restarted' &&
            srCalls.join() === 'workbench.action.reloadWindow' && item.disposed && sr._wait() === null, [w7, w8, w9a, w9b, w9].join() + ' ' + srCalls.join());
        sr._movedSince = movedWas;
        srReset();
        // the registry's last word itself, read with ext's own reader stood in for
        {
            const regWas = ext._readRegistry;
            const since = Date.now() - 1000;
            const tMoved = path.join(srDir, SB + '.jsonl');
            fs.writeFileSync(tMoved, '{}\n');
            const look = { chats: [chat(SA, ''), chat(SB, '', false, tMoved)] };
            ext._readRegistry = () => new Map([[SA, [{ pid: 7, sessionId: SA, status: 'busy', kind: 'interactive', entrypoint: 'claude-vscode', startedAt: since - 60000 }]]]);
            const m1 = sr._movedSince(look, Date.now() + 60000);
            ext._readRegistry = () => new Map([[SC, [{ pid: 8, sessionId: SC, status: 'idle', kind: 'interactive', entrypoint: 'claude-vscode', startedAt: Date.now() }]]]);
            const m2 = sr._movedSince(look, since);
            ext._readRegistry = () => new Map([[SC, [{ pid: 8, sessionId: SC, status: 'idle', kind: 'interactive', entrypoint: 'cli', startedAt: Date.now() }]]]);
            const m3 = sr._movedSince(look, Date.now() + 60000);
            const m4 = sr._movedSince(look, since);
            ext._readRegistry = () => new Map();
            const m5 = sr._movedSince(look, Date.now() + 60000);
            // written as a window reloads - a record with no turn, no time -
            // after a last turn of an hour ago: its mtime is fresh, it is not
            const tTouched = path.join(srDir, SC + '.jsonl');
            const hourAgo = Date.now() - 3600000;
            fs.writeFileSync(tTouched, '{"type":"user","message":{"role":"user","content":"say \\"timestamp\\":\\"2099-01-01T00:00:00Z\\""},"timestamp":"' + new Date(hourAgo).toISOString() + '"}\n{"type":"cost-state"}\n');
            const m6 = sr._movedSince({ chats: [chat(SC, '', false, tTouched)] }, since);
            const lw = sr._lastWritten(tTouched), lwPlain = sr._lastWritten(tMoved);
            ext._readRegistry = regWas;
            check('safe restart: a transcript written since the look is by its last turn\'s time - one only touched since, as a reload touches it, is not; no time in it at all, its mtime',
                m6 === '' && Math.abs(lw - hourAgo) < 2 && Math.abs(lwPlain - fs.statSync(tMoved).mtimeMs) < 1, [m6, lw, hourAgo, lwPlain].join(' | '));
            check('safe restart: the registry\'s last word - a chat of the look busy now, a VS Code chat started since the look began, a transcript written since: each holds the reload; a terminal\'s claude does not',
                m1 === SA.slice(0, 8) + ' busy' && m2 === SC.slice(0, 8) + ' started' && m3 === '' && m4 === SB.slice(0, 8) + ' written' && m5 === '',
                [m1, m2, m3, m4, m5].join(' | '));
        }
        // a look the scripts are too old for, and one that failed, told apart
        const lf1 = sr._lookFailure(null, 'WARNING: x\r\n' + sr.TOO_OLD + '\r\n', '');
        const lf2 = sr._lookFailure(new Error('Command failed'), '', '\r\nGet-ChatHostWork : The term is not recognized\r\nmore');
        const lf3 = sr._lookFailure(null, '', '');
        check('safe restart: scripts too old for the look are said as that - the command tests for Get-ChatHostWork first; else the error and stderr\'s first line',
            lf1.old && /older than 0\.9\.0/.test(lf1.text) && !lf2.old && lf2.text === 'Command failed - Get-ChatHostWork : The term is not recognized' &&
            lf3.text === 'no answer' && /^if \(-not \(Get-Command Get-ChatHostWork -EA SilentlyContinue\)\) \{ \[Console\]::Out\.WriteLine\('chatq: no Get-ChatHostWork'\) \} else \{/.test(hwCmd),
            JSON.stringify([lf1, lf2, lf3]) + ' ' + hwCmd);
        // a reload that fails: said, with a try again - not only logged
        const execWas = stub.commands.executeCommand;
        let refusals = 1;
        stub.commands.executeCommand = async (c) => { srCalls.push(c); if (refusals-- > 0) throw new Error('refused'); };
        list('0.9.55', 3850);
        verdict = noWork;
        srAnswer.info = sr.GO;
        srAnswer.warn = sr.AGAIN;
        const rf = await sr._checkInstall();
        await settle();
        check('safe restart: a reload that fails is said, with Try again - which reloads',
            rf === 'failed' && srAsked.some(a => a.kind === 'warn' && a.m === sr.texts.failed('0.9.55') && a.b.join() === 'Try again,Later') &&
            srCalls.filter(c => c === 'workbench.action.reloadWindow').length === 2, rf + ' ' + JSON.stringify(srAsked) + ' ' + srCalls.join());
        stub.commands.executeCommand = execWas;
        srReset();
        // cancelled from the status bar: nothing restarts, whatever comes after
        list('0.9.6', 3900);
        verdict = as([chat(SA, 'turn')]);
        srAnswer.warn = sr.WAIT;
        await sr._checkInstall();
        await tick();
        const item2 = items[items.length - 1];
        const c1 = sr._cancel();
        verdict = noWork;
        const c2 = await sr._poll();
        clock += 1e6;
        const c3 = await sr._poll();
        check('safe restart: the status-bar item clicked - the wait is off, said, and nothing restarts',
            c1 === 'cancelled' && item2.disposed && c2 === 'skipped' && c3 === 'skipped' && !srCalls.length &&
            srAsked.some(a => a.m === sr.texts.cancelled('0.9.6')), [c1, c2, c3].join() + ' ' + srCalls.join());
        srReset();
        // a newer install while waiting: taken by the wait, not said again
        verdict = as([chat(SA, 'turn')]);
        srAnswer.warn = sr.WAIT;
        list('0.9.7', 4000);
        await sr._checkInstall();
        await tick();
        const asked1 = srAsked.length;
        list('0.9.8', 4100);
        const nw = await sr._checkInstall();
        check('safe restart: a newer install while it waits - no second notice; the wait loads that one',
            asked1 === 1 && nw === 'waiting' && srAsked.length === 1 && sr._wait().version === '0.9.8', asked1 + ' ' + nw);
        sr._stopWait();
        srReset();

        // chatq's own reloads, held to the chats of this window
        let reloads = () => srCalls.filter(c => c === 'workbench.action.reloadWindow').length;
        verdict = as([chat(SB, 'background')]);
        srAnswer.warn = 'Not now';
        const g1 = await sr._guardReload(true, null);
        await settle();
        const g1Said = srAsked.slice(), g1n = reloads();
        srReset();
        verdict = async () => null;
        const g2 = await sr._guardReload(true, null);
        await settle();
        const g2Said = srAsked.slice(), g2n = reloads();
        srReset();
        const g3 = await sr._guardReload(false, null);
        const g3n = reloads();
        srReset();
        verdict = as([chat(SA, '', true), chat(SC, '')]);
        const g4 = await sr._guardReload(true, SA);
        const g4n = reloads();
        srReset();
        verdict = as([chat(SB, 'background')]);
        srAnswer.warn = 'Reload anyway';
        const g5 = await sr._guardReload(true, null);
        await settle();
        const g5n = reloads();
        srReset();
        check('reload guard: by itself, a chat of this window working - background only - says which and does not reload',
            g1 === 'asked' && g1n === 0 && g1Said.length === 1 && g1Said[0].m === 'Reloading this window now would stop the chat working here: a chat (fedcba98) (background work running). Reload once it finishes.' &&
            g1Said[0].b.join() === 'Reload anyway,Not now', g1 + ' ' + JSON.stringify(g1Said));
        check('reload guard: by itself on a look that failed - not reloaded, and said; on a click, the reload as before',
            g2 === 'asked' && g2n === 0 && g2Said[0].m === sr.texts.reloadUnchecked && g3 === 'reloaded' && g3n === 1, [g2, g2n, g3, g3n].join());
        check('reload guard: the chat a queued run just wrote reads live only by its write - left out; Reload anyway reloads',
            g4 === 'reloaded' && g4n === 1 && g5 === 'asked' && g5n === 1, [g4, g4n, g5, g5n].join());
        // Reload anyway clicked on chatq's own warning: within a minute it
        // reloads; an hour on the window is looked at again, the chat the
        // warning named left out - another working since is asked about
        {
            let clk = 5e9;
            const nowWas = sr._now;
            sr._now = () => clk;
            verdict = as([chat(SA, 'turn'), chat(SB, 'background')]);
            srAnswer.warn = 'Not now';
            const a1 = await ext._reloadAnyway(clk - 30000, SA, null);
            const a1n = reloads();
            srReset();
            const a2 = await ext._reloadAnyway(clk - 3600000, SA, null);
            await settle();
            const a2n = reloads(), a2Said = srAsked.slice();
            srReset();
            verdict = as([chat(SA, 'turn')]);
            const a3 = await ext._reloadAnyway(clk - 3600000, SA, null);
            const a3n = reloads();
            srReset();
            sr._now = nowWas;
            check('reload guard: Reload anyway within a minute of its warning reloads; an hour on, a chat it never named working since is asked about - the one it named is not',
                a1n === 1 && a2 === 'asked' && a2n === 0 && a2Said.length === 1 && /stop the chat working here: a chat \(fedcba98\) \(background work running\)/.test(a2Said[0].m) &&
                a3 === 'reloaded' && a3n === 1, [a1, a1n, a2, a2n, a3, a3n].join() + ' ' + JSON.stringify(a2Said));
        }
        // end to end through the request file: autoReload after a delete, and a
        // queued run's reload by itself, with a background-only chat working here
        cfgVals['chatManager.autoReload'] = true;
        verdict = as([chat(SB, 'background')]);
        srAnswer.warn = 'Not now';
        fs.writeFileSync(file, JSON.stringify(del('sr-d1', 'T')));
        await ext._check(context, file, false);
        await settle();
        const e1 = reloads(), e1Said = srAsked.slice();
        srReset();
        delete cfgVals['chatManager.autoReload'];
        srAnswer.warn = 'Not now';
        const wasClaude = claudeHere;
        claudeHere = false;
        put('sr-r1');
        await ext._check(context, file, false);
        await settle();
        const e2 = reloads(), e2Said = srAsked.slice();
        srReset();
        // a plain Reload clicked on a delete the script found quiet
        srAnswer.info = 'Reload';
        srAnswer.warn = 'Not now';
        fs.writeFileSync(file, JSON.stringify(del('sr-d2', 'T')));
        await ext._check(context, file, false);
        await settle();
        const e3 = reloads(), e3Said = srAsked.slice();
        srReset();
        verdict = noWork;
        put('sr-r2');
        await ext._check(context, file, false);
        await settle();
        const e4 = reloads();
        claudeHere = wasClaude;
        srReset();
        check('reload guard: autoReload after a delete, a chat of this window running a workflow - not reloaded, and asked',
            e1 === 0 && e1Said.length === 1 && /would stop the chat working here/.test(e1Said[0].m), e1 + ' ' + JSON.stringify(e1Said));
        check('reload guard: a queued run\'s reload by itself, the same - not reloaded; nothing working, it reloads as before',
            e2 === 0 && e2Said.length === 1 && /would stop the chat working here/.test(e2Said[0].m) && e4 === 1, e2 + ' ' + e4 + ' ' + JSON.stringify(e2Said));
        check('reload guard: a plain Reload clicked while a chat here works - asked again, not reloaded',
            e3 === 0 && e3Said.length === 2 && e3Said[0].b.join() === 'Reload,Not now' && /would stop the chat working here/.test(e3Said[1].m),
            e3 + ' ' + JSON.stringify(e3Said));

        // the question left unanswered for good holds no show behind it -
        // any other check's left unanswered forgotten first, so the overlay's
        // list below holds this one alone
        ext._pendingAsks.clear();
        const warnWas = stub.window.showWarningMessage;
        stub.window.showWarningMessage = () => new Promise(() => { });
        verdict = as([chat(SB, 'background')]);
        const qFirst = ext._enqueue(() => sr._guardReload(false, null));
        let qNext = false;
        const qAfter = ext._enqueue(async () => { qNext = true; });
        await Promise.race([qAfter, new Promise(r => setTimeout(r, 500))]);
        stub.window.showWarningMessage = warnWas;
        check('reload guard: its question, never answered, holds up no show queued after it', qNext && reloads() === 0, qNext + ' ' + srCalls.join());
        await qFirst;
        srReset();

        // that question, on the overlay too: listed in reload-pending/<pid>
        // .json while it is up, and the overlay's reload is its Reload anyway
        {
            const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return null; } };
            const answer = (id, a, at) => {
                fs.mkdirSync(path.dirname(ext._answerFile()), { recursive: true });
                fs.writeFileSync(ext._answerFile(), String.fromCharCode(0xFEFF) + JSON.stringify({ id, answer: a, at: at || new Date().toISOString() }));
                return ext._onReloadAnswer();
            };
            const p1 = readJson(ext._pendingFile());
            const a1 = p1 && p1.asks[0];
            check('reload on the overlay: an unanswered reload question is listed for it - this host\'s pid, when it started, its window, the ask\'s id, state and line',
                p1 && p1.pid === process.pid && typeof p1.started === 'number' && p1.window === 'projA' && p1.asks.length === 1 &&
                a1.state === 'anyway' && a1.say === 'it would stop 1 working chat' && /would stop the chat working here/.test(a1.text) &&
                path.dirname(ext._pendingFile()) === path.join(reloadData, 'reload-pending'), JSON.stringify(p1));
            const r1 = answer(a1.id, 'reload');
            await settle();
            check('reload on the overlay: its reload is the notice\'s Reload anyway - the window reloads, the answer and the listing both gone',
                r1 === 'reload' && reloads() === 1 && !fs.existsSync(ext._pendingFile()) && !fs.existsSync(ext._answerFile()) && !ext._pendingAsks.size,
                r1 + ' ' + srCalls.join());
            srReset();
            // later: every ask of this window off the overlay, the notices
            // still up and still answering
            let letGo = null;
            stub.window.showWarningMessage = (m, ...b) => new Promise(r => { letGo = r; });
            stub.window.showInformationMessage = (m, ...b) => new Promise(() => { });
            let picked = 'none';
            ext._askReload(false, 'Reload?', 'Reload', ext._askSay({ kind: 'deleted', title: 'Old chat' })).then(p => { picked = p; });
            ext._askReload(true, 'Reload anyway?', 'Reload anyway', 'x').then(p => { picked = p; });
            const p2 = readJson(ext._pendingFile());
            const ids2 = p2 ? p2.asks.map(a => a.id) : [];
            const st2 = p2 ? p2.asks.map(a => a.state).join() : '';
            // later on the older: an ask made since - not yet on the overlay
            // when it was answered - stays; later on the newest, all go
            const r2a = answer(ids2[0], 'later');
            const kept2 = [...ext._pendingAsks.keys()].join();
            const r2 = answer(ids2[1], 'later');
            await tick();
            const gone2 = !fs.existsSync(ext._pendingFile()) && !ext._pendingAsks.size && picked === 'none';
            letGo('Reload anyway');
            await tick();
            check('reload on the overlay: later takes the ask it answered, and those before it, off; one asked since stays; the notice left up still answers',
                ids2.length === 2 && ids2[0] !== ids2[1] && st2 === 'offered,anyway' && p2.asks[0].say === '"Old chat" deleted - the chat list still shows it' &&
                r2a === 'later' && kept2 === ids2[1] && r2 === 'later' && gone2 && picked === 'Reload anyway' && !fs.existsSync(ext._pendingFile()),
                [ids2.join(), st2, r2a, kept2, r2, gone2, picked].join(' '));
            srReset();
            // answered on the overlay, its notice cannot be taken down: its
            // button there still acts - Reload anyway reloads
            let letGo2 = null, picked2 = 'none';
            stub.window.showWarningMessage = (m, ...b) => new Promise(r => { letGo2 = r; });
            ext._askReload(true, 'Reload anyway?', 'Reload anyway', 'x').then(p => { picked2 = p; });
            const r7 = answer(ext._pendingAsks.keys().next().value, 'reload');
            await tick();
            const n7 = reloads();
            letGo2('Reload anyway');
            await settle();
            check('reload on the overlay: the notice\'s own button, clicked after the overlay answered it, still reloads',
                r7 === 'reload' && picked2 === 'Reload anyway' && n7 === 0 && reloads() === 1, [r7, picked2, n7, reloads()].join());
            srReset();
            // an answer to an ask no longer open, or an old one: nothing
            stub.window.showWarningMessage = () => new Promise(() => { });
            ext._askReload(true, 'Reload anyway?', 'Reload anyway', 'x');
            const id3 = ext._pendingAsks.keys().next().value;
            const r3 = answer('nope-1', 'reload');
            const r4 = answer(id3, 'reload', new Date(Date.now() - 11 * 60000).toISOString());
            const r5 = answer(id3, 'maybe');
            const r6 = ext._onReloadAnswer();
            await settle();
            check('reload on the overlay: an answer to no open ask, one over ten minutes old, or no answer at all does nothing - and is removed',
                r3 === 'stale' && r4 === 'stale' && r5 === 'stale' && r6 === 'none' && reloads() === 0 && ext._pendingAsks.size === 1 &&
                fs.existsSync(ext._pendingFile()) && !fs.existsSync(ext._answerFile()), [r3, r4, r5, r6, reloads()].join());
            ext._pendingAsks.clear();
            ext._writePending();
            stub.window.showWarningMessage = warnWas;
            stub.window.showInformationMessage = async (m, ...b) => { srAsked.push({ m, b, kind: 'info' }); return b.includes(srAnswer.info) ? srAnswer.info : undefined; };
            // at activation: the files of windows gone swept, a live one's kept
            const pd = path.dirname(ext._pendingFile()), ad = path.dirname(ext._answerFile());
            fs.mkdirSync(ad, { recursive: true });
            for (const n of ['424242.json', '515151.json', '424242.json.tmp', process.pid + '.json', 'notes.txt']) fs.writeFileSync(path.join(pd, n), '{}');
            fs.writeFileSync(path.join(ad, '424242.json'), '{}');
            // and the open tabs of each (writeTabs)
            const td = path.dirname(ext._tabsFile());
            fs.mkdirSync(td, { recursive: true });
            for (const n of ['424242.json', '515151.json', '424242.json.tmp', process.pid + '.json']) fs.writeFileSync(path.join(td, n), '{}');
            const aliveWas = ext._alive;
            ext._alive = (p) => p === 515151;
            ext._sweepPending();
            ext._alive = aliveWas;
            const left = fs.readdirSync(pd).sort().join(), leftA = fs.readdirSync(ad).join();
            check('reload on the overlay: activation sweeps the files of hosts gone, and this host\'s own - a live window\'s stay',
                left === '515151.json,notes.txt' && leftA === '', left + ' / ' + leftA);
            const leftT = fs.readdirSync(td).sort().join();
            check('open tabs: activation sweeps those of hosts gone too, and this host\'s own - a live window\'s stay', leftT === '515151.json', leftT);
            check('reload on the overlay: the line each request gets there',
                ext._askSay({ kind: 'archived', title: 'A' }) === '"A" archived - the chat list still shows it' &&
                ext._askSay({ kind: 'ran', title: 'R' }) === 'a queued prompt ran in "R" - a reload shows it' &&
                ext._askSay({ kind: 'deleted' }) === 'a chat deleted - the chat list still shows it' && ext._askSay({ kind: 'other' }) === 'a reload is waiting',
                [ext._askSay({ kind: 'archived', title: 'A' }), ext._askSay({ kind: 'ran', title: 'R' })].join(' | '));
            fs.rmSync(reloadData, { recursive: true, force: true });
            srReset();
        }

        sr._stopWait();
        sr._now = () => Date.now();
        sr.timing.poll = 25000;
        sr._hostWork = noWork;
        fs.watchFile = realWatch;
        delete stub.extensions.onDidChange;
        fs.rmSync(srDir, { recursive: true, force: true });
    }

    try { fs.unlinkSync(file); } catch (e) { }
    try { fs.unlinkSync(ofile); } catch (e) { }
    delete process.env.CLAUDE_CONFIG_DIR;
    console.log('');
    console.log('  ' + (total - failed) + ' passed, ' + failed + ' failed');
    summed = true;
    process.exit(failed);
})();
