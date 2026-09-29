// Makes tests/fixtures/session-vector.json: transcripts, and the session-only
// settings a chat left in them - { ultracode, effort } - as both readers must
// find them: Get-ChatSessionSettings in src/chatrm.ps1 and sessionSettingsIn
// in extension/extension.js. tests/sections/ultracode.ps1 and
// tests/extension-check.js run every case, each at the full read size and
// again in small chunks, so the two readers cannot drift apart. The answers
// are written here by hand from the rules, never by either reader.
//
//   says   one /effort answer each: { text, version, ultracode, level,
//          effort } - Read-ChatEffortSay's Ultracode, Level and Effort;
//          effortSaid's ultracode, 'set' in it, and set
//   cases  { name, lines, expect: { ultracode, effort } }, and where a case
//          needs them: pad - every "@PAD@" in a line becomes that many "x";
//          budget - the bytes read from the end
//
// The records keep Claude Code's own key order (2.1.284): a reader that
// looks for its keys by position is held to the real layout.
//
//     node tests/fixtures/make-session-vector.js
//
// Run it again after changing a case; the file is checked in.
const fs = require('fs');
const path = require('path');

// anything past ASCII written as a JSON escape: the file stays ASCII, so
// Windows PowerShell 5.1 reads it the same whatever its code page
const ascii = (o) => JSON.stringify(o, null, 1).replace(/[^\x00-\x7f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '\n';
const DOT = ' \u00b7 ';
const DASH = '\u2014';

// --- /effort's words ---------------------------------------------------------
const W = {
    onX: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays xhigh.',
    onMax: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays max.',
    onRemote: 'Ultracode on (this session only): dynamic workflows on every task. Effort stays max. (applied locally ' + DASH + ' this remote transport can\u2019t change the remote session\u2019s settings)',
    offX: 'Ultracode off. Effort stays xhigh.',
    offMax: 'Ultracode off. Effort stays max.',
    max: 'Set effort level to max (this session only): Maximum capability with deepest reasoning. May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks.',
    high: 'Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation',
    xhigh: 'Set effort level to xhigh (this session only): Deeper reasoning for complex tasks',
    med: 'Set effort level to med (this session only): Balanced approach',
    highSaved: 'Set effort level to high (saved as your default for new sessions): Comprehensive implementation with extensive testing and documentation',
    mediumOrg: 'Set effort level to medium (saved, though your organization starts new sessions on claude-opus-5-5 at high effort): Balanced approach',
    highOff: 'Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation' + DOT + 'Ultracode off',
    cap: 'Effort \'max\' exceeds the cap for claude-opus-5-5 set by your settings or organization; set to \'xhigh\' instead (this session only): Deeper reasoning',
    capSaved: 'Effort \'max\' exceeds the cap for claude-opus-5-5 set by your settings or organization; set to \'xhigh\' instead (saved as your default for new sessions): Deeper reasoning',
    auto: 'Effort level set to auto',
    autoOff: 'Effort level set to auto (this session only)' + DOT + 'Ultracode off',
    envAuto: 'Effort set to auto for this session, but CLAUDE_CODE_EFFORT_LEVEL=high still controls this session',
    envCleared: 'Cleared effort from settings, but CLAUDE_CODE_EFFORT_LEVEL=high still controls this session',
    envOver: 'CLAUDE_CODE_EFFORT_LEVEL=high overrides this session ' + DASH + ' clear it and xhigh takes over',
    envOver283: 'CLAUDE_CODE_EFFORT_LEVEL=high overrides effort this session ' + DASH + ' clear it and ultracode takes over',
    notApplied: 'Not applied: CLAUDE_CODE_EFFORT_LEVEL=high overrides effort this session, and max is session-only (nothing saved)',
    statusOn: 'Current effort level: max (Maximum capability with deepest reasoning)' + DOT + 'Ultracode on',
    statusAutoOn: 'Effort level: auto (currently xhigh)' + DOT + 'Ultracode on',
    statusAuto: 'Effort level: auto (currently xhigh)',
    status: 'Current effort level: high (Comprehensive implementation with extensive testing and documentation)',
    status283: 'Current effort level: ultracode (xhigh + dynamic workflow orchestration; this session only)',
    set283: 'Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration',
    invalid: 'Invalid argument: max ultracode. Valid options are: low, medium, high, xhigh, max, auto, ultracode [on|off]',
    needs: 'Ultracode needs dynamic workflows enabled (see /config). Valid options are: low, medium, high, xhigh, max, auto'
};
const V = '2.1.284', V283 = '2.1.283';
const say = (text, version, ultracode, level, effort) => ({ text, version, ultracode, level, effort });
const says = [
    say(W.onX, V, true, false, null),
    say(W.onRemote, V, true, false, null),
    say(W.offMax, V, false, false, null),
    say(W.max, V, null, true, 'max'),
    say(W.high, V, null, true, 'high'),
    say(W.med, V, null, true, 'medium'),
    say(W.highSaved, V, null, true, null),
    say(W.mediumOrg, V, null, true, null),
    say(W.highOff, V, false, true, 'high'),
    say(W.cap, V, null, true, 'xhigh'),
    say(W.capSaved, V, null, true, null),
    say(W.auto, V, null, true, null),
    say(W.autoOff, V, false, true, null),
    say(W.envAuto, V, null, true, null),
    say(W.envCleared, V, null, true, null),
    say(W.envOver, V, null, true, null),
    say(W.notApplied, V, null, true, null),
    say(W.statusOn, V, true, false, null),
    say(W.statusAutoOn, V, true, false, null),
    say(W.statusAuto, V, false, false, null),
    say(W.status, V, false, false, null),
    // 2.1.283: a status named Ultracode only as a level of its own, and
    // every level set switched it off unsaid
    say(W.status, V283, null, false, null),
    say(W.status283, V283, true, false, null),
    say(W.set283, V283, true, true, null),
    say(W.high, V283, false, true, 'high'),
    say(W.auto, V283, false, true, null),
    say(W.cap, V283, false, true, 'xhigh'),
    say(W.envOver283, V283, null, true, null),
    say(W.invalid, V, null, false, null),
    say(W.needs, V, null, false, null)
];

// --- records, in Claude Code's key order -------------------------------------
let clock = 0, n = 0;
const at = (ms) => new Date(clock += (ms === undefined ? 1000 : ms)).toISOString();
const id = () => '00000000-0000-4000-8000-' + String(++n).padStart(12, '0');
const tail = (o) => ({ userType: 'external', entrypoint: o.ep || 'claude-vscode', cwd: 'C:\\work', sessionId: 's', version: o.v || V, gitBranch: 'main' });
const line = (r) => JSON.stringify(r);
// a prompt the user typed or pasted: content a string, or blocks
const human = (content, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: !!o.side, promptId: id(), type: 'user', message: { role: 'user', content }, uuid: id(),
    timestamp: at(o.gap), permissionMode: 'auto', origin: { kind: 'human' }, promptSource: 'sdk', turnOrigin: 'human' }, tail(o)));
// an Ultracode notice, written just after the prompt it came with, stamped
// a millisecond before it
const notice = (kind, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: !!o.side,
    attachment: kind === 'enter' ? { type: 'ultra_effort_enter', reminderType: o.sparse ? 'sparse' : 'full' } : { type: 'ultra_effort_exit' },
    type: 'attachment', uuid: id(), timestamp: new Date(clock - 1).toISOString() }, tail(o)));
const meta = (text, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: !!o.side, promptId: id(), type: 'user', message: { role: 'user', content: [{ type: 'text', text }] },
    isMeta: true, turnCompanion: true, uuid: id(), timestamp: at(0) }, tail(o)));
// a turn of the model's: effort the level it ran at (none: an old version's
// record); o.input - a tool call's input, structure of its own
const asst = (effort, o = {}) => {
    const content = [{ type: 'text', text: o.text || 'done' }];
    if (o.input) content.push({ type: 'tool_use', id: 'toolu_' + n, name: o.tool || 'Workflow', input: o.input });
    const r = { parentUuid: id(), isSidechain: !!o.side, message: { model: 'claude-opus-5-5', id: 'msg_' + n, type: 'message', role: 'assistant', content, stop_reason: o.input ? 'tool_use' : 'end_turn' },
        requestId: 'req_' + n, type: 'assistant', uuid: id(), timestamp: at(o.gap === undefined ? 2000 : o.gap) };
    if (effort) { r.effort = effort; r.perTurnEffort = effort; }
    return line(Object.assign(r, tail(o)));
};
const toolResult = (text, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: !!o.side, promptId: id(), type: 'user',
    message: { role: 'user', content: [{ tool_use_id: 'toolu_' + n, type: 'tool_result', content: text }] }, uuid: id(), timestamp: at(500),
    toolUseResult: { stdout: text, stderr: '', interrupted: false }, sourceToolAssistantUUID: id() }, tail(o)));
const taskNote = (o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: false, promptId: id(), type: 'user',
    message: { role: 'user', content: '<task-notification>\n<task-id>t' + n + '</task-id>\n<status>completed</status>\n<summary>Background task done</summary>\n</task-notification>' },
    uuid: id(), timestamp: at(), permissionMode: 'auto', origin: { kind: 'task-notification' }, promptSource: 'system', turnOrigin: 'task_notification' }, tail(o)));
const interrupted = (o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: false, promptId: id(), type: 'user',
    message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] }, uuid: id(), timestamp: at(300) }, tail(o)));
// a prompt another session sent into this one: no origin, the SDK's source
const peer = (text, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: false, promptId: id(), type: 'user', message: { role: 'user', content: text },
    uuid: id(), timestamp: at(), permissionMode: 'auto', promptSource: 'sdk', turnOrigin: 'sdk' }, tail(o)));
// a claude -p run's prompt - chatq's queued prompt among them
const runPrompt = (text, o = {}) => line(Object.assign({ parentUuid: id(), isSidechain: false, promptId: id(), type: 'user', message: { role: 'user', content: text },
    uuid: id(), timestamp: at(o.gap), permissionMode: 'auto', promptSource: 'sdk', turnOrigin: 'sdk' }, tail(Object.assign({ ep: 'sdk-cli' }, o))));
// a slash command and its output: the user's command record, then
// local_command with what it printed
const command = (name, args, text, o = {}) => [
    line(Object.assign({ parentUuid: id(), isSidechain: !!o.side, promptId: id(), type: 'user',
        message: { role: 'user', content: '<command-name>/' + name + '</command-name>\n            <command-message>' + name + '</command-message>\n            <command-args>' + args + '</command-args>' },
        uuid: id(), timestamp: at(o.gap) }, tail(o))),
    line(Object.assign({ parentUuid: id(), isSidechain: !!o.side, type: 'system', subtype: 'local_command', content: '<local-command-stdout>' + text + '</local-command-stdout>',
        level: 'info', timestamp: at(0), uuid: id(), isMeta: false, commandRun: { command: name, args } }, tail(o)))
];
const effort = (args, text, o) => command('effort', args, text, o);
// /compact's boundary and the summary after it; gap - since the last record
const compact = (o = {}) => [
    line(Object.assign({ parentUuid: null, logicalParentUuid: id(), isSidechain: false, type: 'system', subtype: 'compact_boundary', content: 'Conversation compacted', isMeta: false,
        timestamp: at(o.gap === undefined ? 60000 : o.gap), uuid: id(), level: 'info', compactMetadata: { trigger: 'manual', preTokens: 180000, durationMs: 60000 } }, tail(o))),
    line(Object.assign({ parentUuid: id(), isSidechain: false, promptId: id(), type: 'user',
        message: { role: 'user', content: 'This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.' },
        isVisibleInTranscriptOnly: true, isCompactSummary: true, uuid: id(), timestamp: at(-700) }, tail(o)))
];
// a prompt and its turn: o.notice 'enter' | 'sparse' | 'exit'; o.gap - since
// the last record
const turn = (text, level, o = {}) => {
    const r = [human(text, o)];
    if (o.notice) r.push(notice(o.notice === 'exit' ? 'exit' : 'enter', Object.assign({}, o, { sparse: o.notice === 'sparse' })));
    r.push(asst(level, o));
    return r;
};
// a queued run: its prompt, its own exit (it starts without Ultracode), its turn
const run = (level, o = {}) => [runPrompt('Continue from where you left off.', o), notice(o.notice || 'exit', { ep: 'sdk-cli', sparse: false }), asst(level, { ep: 'sdk-cli' })];

const cases = [];
const add = (name, expect, parts, extra) => {
    cases.push(Object.assign({ name, lines: [].concat(...parts), expect: { ultracode: expect[0], effort: expect[1] } }, extra || {}));
};
const start = () => { clock = Date.parse('2026-09-20T10:00:00.000Z'); n = 0; };

// --- Ultracode ---------------------------------------------------------------
// a prompt's own notice says it
start(); add('on at the prompt', [true, null], [turn('a', 'xhigh', { notice: 'enter' })]);
start(); add('off at the prompt', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh', { notice: 'exit' })]);
// no notice since an enter: still on - an exit would have come with the prompt
start(); add('on, prompts without a notice since', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh'), turn('c', 'xhigh')]);
// no notice since a compaction: off - the enter is out of the process's
// sight, and it writes one with the next prompt while Ultracode is on
start(); add('off after a compaction', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), turn('b', 'xhigh', { gap: 60000 })]);
start(); add('on after a compaction', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), turn('b', 'xhigh', { gap: 60000, notice: 'enter' })]);
// a prompt queued during /compact: judged against the chat before it
start(); add('queued during the compaction, on', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), turn('b', 'xhigh', { gap: 800 })]);
start(); add('queued during the compaction, off', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh', { notice: 'exit' }), compact(), turn('c', 'xhigh', { gap: 800 })]);
start(); add('queued during the second compaction', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), turn('b', 'xhigh', { gap: 60000 }), compact(), turn('c', 'xhigh', { gap: 800 })]);
start(); add('queued during the compaction, sparse', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), turn('b', 'xhigh', { gap: 800, notice: 'sparse' })]);
// a queued run's exit: its own, but the chat's next prompt judged against it
start(); add('a run\'s exit, then a prompt', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), run('xhigh'), turn('b', 'xhigh')]);
start(); add('a run\'s exit, no prompt since', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), run('xhigh')]);
start(); add('a run\'s enter, then a prompt', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh', { notice: 'exit' }), run('xhigh', { notice: 'enter' }), turn('c', 'xhigh')]);
// /effort after the last prompt says it; before it, the prompt's notice
start(); add('/effort off after the prompt', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), effort('ultracode off', W.offX)]);
start(); add('/effort on after the prompt', [true, null], [turn('a', 'xhigh'), effort('ultracode', W.onX)]);
start(); add('/effort on, then a prompt without its notice', [false, null], [effort('ultracode', W.onX), turn('a', 'xhigh')]);
start(); add('/effort on, no prompt', [true, null], [effort('ultracode', W.onX)]);
start(); add('no notice ever', [false, null], [turn('a', 'xhigh'), turn('b', 'xhigh')]);
start(); add('nothing at all', [null, null], [asst('xhigh'), toolResult('ok')]);
// none of these is a prompt of the user's
start(); add('records that are no prompt', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), interrupted({ gap: 60000 }), taskNote(), asst('medium'),
    [meta('Continue from where you left off.')], asst('xhigh'), peer('<teammate-message>look at this</teammate-message>'), asst('xhigh'),
    command('model', 'opus', 'Set model to Opus'), runPrompt('queued'), asst('xhigh', { ep: 'sdk-cli' })]);
// a prompt with the IDE's context first, one with a picture: prompts all the same
start(); add('a prompt led by the IDE\'s context', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(),
    human([{ type: 'text', text: '<ide_opened_file>The user opened the file c:\\work\\a.js in the IDE.</ide_opened_file>' }, { type: 'text', text: 'go on' }], { gap: 60000 }), asst('xhigh')]);
start(); add('a prompt with a picture', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(),
    human([{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' } },
        { type: 'text', text: 'look' }], { gap: 60000 }), meta('[Image: source: C:\\work\\1.png]'), asst('xhigh')]);
start(); add('a prompt longer than a read', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(), human('@PAD@', { gap: 60000 }), asst('xhigh')], { pad: 1200000 });
// a subagent's records are its own
start(); add('a subagent\'s records', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh', { notice: 'exit' }),
    human('side', { side: true }), notice('enter', { side: true }), effort('ultracode', W.onX, { side: true }), asst('max', { side: true })]);
// the words of a record, quoted in a tool's output, or structure in a tool
// call's input, are no record
start(); add('a prompt quoted, or nested in a tool call', [true, null], [turn('a', 'xhigh', { notice: 'enter' }), compact(),
    asst('xhigh', { gap: 60000, tool: 'Agent', input: { note: { parentUuid: null, isSidechain: false, type: 'user', message: { role: 'user', content: 'x' }, origin: { kind: 'human' }, entrypoint: 'claude-vscode' } } }),
    toolResult(human('quoted prompt'))]);
start(); add('a notice quoted, or nested in a tool call', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), turn('b', 'xhigh', { notice: 'exit' }),
    toolResult(notice('enter') + '\n' + effort('ultracode', W.onX).join('\n')),
    asst('xhigh', { tool: 'Agent', input: { note: { isSidechain: false, attachment: { type: 'ultra_effort_enter' }, type: 'attachment', entrypoint: 'claude-vscode' } } })]);
// 2.1.283's words
start(); add('2.1.283: a level set switched it off', [false, 'high'], [turn('a', 'xhigh', { notice: 'enter', v: V283 }), effort('high', W.high, { v: V283 })]);
start(); add('2.1.283: its status named it', [true, null], [turn('a', 'xhigh', { v: V283 }), effort('', W.status283, { v: V283 })]);
start(); add('2.1.283: a plain status says nothing of it', [true, null], [turn('a', 'xhigh', { notice: 'enter', v: V283 }), effort('', W.status, { v: V283 })]);
start(); add('2.1.284: a plain status is off', [false, null], [turn('a', 'xhigh', { notice: 'enter' }), effort('', W.status)]);
start(); add('2.1.283: /effort ultracode set xhigh', [true, null], [effort('max', W.max, { v: V283 }), effort('ultracode', W.set283, { v: V283 })]);
// read from the end, only so far
start(); add('past the budget', [null, null], [turn('a', 'max', { notice: 'enter' }), toolResult('@PAD@')], { pad: 6000, budget: 4096 });
start(); add('the prompt within the budget, its notice past it', [null, null], [turn('a', 'max', { notice: 'enter' }), toolResult('@PAD@'), turn('b', 'high')], { pad: 6000, budget: 2048 });

// --- the level ---------------------------------------------------------------
start(); add('max set, and used', [false, 'max'], [effort('max', W.max), turn('a', 'max')]);
start(); add('max from the menu', [false, 'max'], [turn('a', 'xhigh'), turn('b', 'max')]);
start(); add('a level from the menu', [false, null], [turn('a', 'high')]);
start(); add('a session-only level, used', [false, 'high'], [effort('high', W.high), turn('a', 'high')]);
start(); add('a session-only level, then the menu', [false, null], [effort('high', W.high), turn('a', 'high'), turn('b', 'xhigh')]);
start(); add('max, then the menu', [false, null], [effort('max', W.max), turn('a', 'max'), turn('b', 'high')]);
start(); add('set after the last turn', [false, 'high'], [turn('a', 'xhigh'), effort('high', W.high)]);
start(); add('set in the middle of a turn', [false, 'max'], [turn('a', 'xhigh'), effort('max', W.max, { gap: 100 }), asst('max')]);
start(); add('saved', [false, null], [effort('high', W.highSaved), turn('a', 'high')]);
start(); add('auto', [false, null], [effort('max', W.max), turn('a', 'max'), effort('auto', W.auto)]);
start(); add('the environment\'s level', [false, null], [effort('xhigh', W.xhigh), turn('a', 'xhigh'), effort('max', W.notApplied)]);
start(); add('through the cap', [false, 'xhigh'], [effort('max', W.cap), turn('a', 'xhigh')]);
start(); add('med', [false, 'medium'], [effort('med', W.med), turn('a', 'medium')]);
// a turn no prompt of the user's started runs at its own level
start(); add('a task\'s turn at another level', [false, 'max'], [effort('max', W.max), turn('a', 'max'), taskNote(), asst('medium')]);
start(); add('a subagent\'s turn', [false, 'max'], [effort('max', W.max), turn('a', 'max'), asst('high', { side: true })]);
start(); add('a run\'s turn', [false, 'max'], [effort('max', W.max), turn('a', 'max'), run('high')]);
// a prompt its turn never answered: the one before it counts
start(); add('an interrupted prompt', [false, 'max'], [turn('a', 'max'), human('b'), interrupted(), taskNote(), asst('medium')]);
// a turn's first level is the session's: a skill raises it later on
start(); add('the turn\'s first level', [false, 'xhigh'], [effort('xhigh', W.xhigh), human('a'), asst('xhigh', { input: { skill: 'x' }, tool: 'Skill' }), toolResult('ok'), asst('high')]);
// an old version's turns name no level
start(); add('turns without a level', [false, 'high'], [effort('high', W.high), turn('a', undefined)]);
start(); add('a level set, and Ultracode off by the same words', [false, 'high'], [turn('a', 'xhigh', { notice: 'enter' }), effort('high', W.highOff)]);
// c303a4d5 as it went: Ultracode on, max, Ultracode on again, a prompt
start(); add('Ultracode and max together', [true, 'max'], [turn('a', 'xhigh', { notice: 'enter' }), effort('ultracode', W.onX), effort('max', W.max), effort('ultracode', W.onMax), turn('b', 'max')]);

fs.writeFileSync(path.join(__dirname, 'session-vector.json'), ascii({ says, cases }));
console.log(says.length + ' says, ' + cases.length + ' cases');
