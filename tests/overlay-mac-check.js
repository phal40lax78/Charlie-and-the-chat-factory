// Checks the macOS overlay's JXA without a Mac: lifts the here-string out of
// src/overlay-mac.ps1, compiles it, and drives its pure part (CO) - the
// countdowns and reset times, the lines the panel draws, which commands it
// takes, and when the menu offers to continue cut-off chats. Everything
// that touches Cocoa sits in run(), which only osascript on a Mac can run;
// TESTING.md has the checklist for that.
//
//     node tests/overlay-mac-check.js
//
// The exit code is the number of failed checks.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
let failed = 0, total = 0;
const check = (name, ok) => {
    total++;
    if (!ok) failed++;
    console.log((ok ? '  ok    ' : '  FAIL  ') + name);
};
const ps1 = fs.readFileSync(path.join(__dirname, '..', 'src', 'overlay-mac.ps1'), 'utf8');
const m = ps1.match(/\$script:ChatOverlayJxa = @'\r?\n([\s\S]*?)\r?\n'@/);
check('the JXA here-string is in the script', !!m);
const js = m ? m[1] : '';
check('it is pure ASCII', /^[\x00-\x7f]*$/.test(js));
// older JavaScriptCore reads neither
check('no ?. or ??', !/\?\.|\?\?/.test(js));
const box = { module: { exports: {} } };
let CO = null;
try {
    vm.createContext(box);
    new vm.Script(js, { filename: 'overlay-mac.js' }).runInContext(box);
    CO = box.module.exports;
} catch (e) {
    console.log('  ' + e.message);
}
check('it compiles, and run() is there for osascript', !!CO && typeof box.run === 'function');
if (CO) {
    const now = Date.UTC(2026, 8, 23, 12, 0, 0);
    check('a countdown under an hour', CO.until(now + 42 * 60000 + 5000, now) === '42m');
    check('and over one', CO.until(now + 90 * 60000 + 5000, now) === '1h 30m');
    check('a day or more is a weekday and time', /^[A-Z][a-z]{2} \d\d:\d\d$/.test(CO.until(now + 3 * 86400000, now)));
    check('a reset that passed', CO.until(now - 1000, now) === 'reset');
    check('the bar is ten cells', CO.bar(42).length === 10 && CO.bar(0).length === 10 && CO.bar(150).length === 10);
    check('a snapshot goes stale', CO.stale({ at: now - 30000 }, now, 20000) && !CO.stale({ at: now - 5000 }, now, 20000) && CO.stale(null, now, 20000));
    const row = (n, status) => ({ key: 's:' + n, status: status, rank: status === 'waiting' ? 0 : 3, project: 'p', title: 'chat ' + n, prompt: 'prompt ' + n, stateText: status });
    const snap = {
        at: now, counts: { waiting: 1, needsInput: 1 }, config: { maxRows: 2, prompts: true },
        header: {
            usage: [{ provider: 'Claude', stale: false, windows: [{ label: '5h', percent: 42, resetsAt: now + 3600000, severity: 'normal', limited: false }] }],
            notes: [{ text: 'next queued prompt: 17:10', tone: 'dim' }]
        },
        rows: [row(1, 'waiting'), row(2, 'idle'), row(3, 'queued')]
    };
    const flat = CO.lines(snap, now, true).map(l => l.map(r => r[0]).join(''));
    check('usage first, then the notes', flat[0].indexOf('Claude') === 0 && flat[0].indexOf('42%') > 0 && flat[1] === 'next queued prompt: 17:10');
    // lines (the default): one a provider, its time at the end; bars: a row a window
    const two = Object.assign({}, snap, { header: { notes: [], usage: [
        { provider: 'Claude', stale: false, status: '22:22', windows: [{ label: '5h', percent: 42, severity: 'normal' }, { label: 'week', percent: 80, severity: 'warning' }] },
        { provider: 'Copilot', stale: false, status: '22:20', windows: [{ label: 'chat', percent: 5, severity: 'normal' }] }] } });
    const asLines = CO.lines(two, now, true).map(l => l.map(r => r[0]).join(''));
    const asBars = CO.lines(Object.assign({}, two, { config: { maxRows: 2, prompts: true, usageView: 'bars' } }), now, true).map(l => l.map(r => r[0]).join(''));
    check('usage as a line a provider ending in its time, or as bars when set',
        asLines[0].indexOf('Claude') === 0 && asLines[0].indexOf('5h 42% \u00B7 week 80%') > 0 && /22:22$/.test(asLines[0]) &&
        asLines[1].indexOf('Copilot') === 0 && asBars[1].indexOf('week') > 0 && asBars[2].indexOf('Copilot') === 0 &&
        /22:22$/.test(asBars[0]) && !/22:22/.test(asBars[1]));
    check('rows up to maxRows, each with its prompt, then "+N more"',
        flat.indexOf('    prompt 1') > 0 && flat.some(l => l.indexOf('chat 2') >= 0) && !flat.some(l => l.indexOf('chat 3') >= 0) && flat.indexOf('+1 more') > 0);
    const termSnap = Object.assign({}, snap, { rows: [Object.assign(row(1, 'idle'), { where: 'terminal' }), Object.assign(row(2, 'idle'), { where: 'vscode' })] });
    const termFlat = CO.lines(termSnap, now, true).map(l => l.map(r => r[0]).join(''));
    check('a chat in a terminal marked >_, one in VS Code not',
        termFlat.some(l => l.indexOf('>_ chat 1') >= 0) && termFlat.some(l => l.indexOf('chat 2') >= 0) && !termFlat.some(l => l.indexOf('>_ chat 2') >= 0));
    const newSnap = Object.assign({}, snap, { rows: [Object.assign(row(1, 'idle'), { unread: true }), row(2, 'idle')] });
    const newFlat = CO.lines(newSnap, now, true).map(l => l.map(r => r[0]).join(''));
    // unread is Windows only: no chip here clears it, so no mark is drawn
    check('no unread mark on macOS: a row that says unread draws as any other',
        newFlat.some(l => l.indexOf('chat 1') >= 0) && !newFlat.some(l => l.indexOf('* chat') >= 0));
    check('prompts hidden when turned off', !CO.lines(Object.assign({}, snap, { config: { maxRows: 8, prompts: false } }), now, true).some(l => l[0][0].indexOf('    prompt') === 0));
    check('a hint only while unlocked', !flat.some(l => l.indexOf('unlocked') === 0) && CO.lines(snap, now, false).some(l => l[0][0].indexOf('unlocked') === 0));
    check('nothing open says so', CO.lines({ at: now, rows: [], header: { usage: [], notes: [] } }, now, true).some(l => l[0][0] === 'no chats open'));
    const seen = {};
    const cmds = [{ id: 1, verb: 'lock', at: 100 }, { id: 2, verb: 'hide', at: 300 }];
    const first = CO.applyCommands(cmds, 200, seen);
    check('only commands newer than the panel, and each once', first.join() === 'hide' && CO.applyCommands(cmds, 200, seen).length === 0);
    check('the menu bar item counts what needs you', CO.menuTitle(snap) === 'CQ 2' && CO.menuTitle({ counts: {} }) === 'CQ');
    check('theme: dark by default, light when set, system follows the OS',
        CO.themeOf(null, true) === 'dark' && CO.themeOf({ theme: 'light' }, true) === 'light' &&
        CO.themeOf({ theme: 'system' }, true) === 'dark' && CO.themeOf({ theme: 'system' }, false) === 'light' &&
        CO.themeOf({ theme: 'nonsense' }, false) === 'dark');
    check('each look has every colour the lines use',
        Object.keys(CO.colors).every(k => Array.isArray(CO.light[k])) && CO.color('busy', 'light') !== CO.color('busy', 'dark') &&
        CO.color('no-such', 'light') === CO.light.text);
    check('opacity held to 0.3-1, 0.94 when unset', CO.opacityOf({ opacity: 0.1 }) === 0.3 && CO.opacityOf({ opacity: 0.8 }) === 0.8 && CO.opacityOf(null) === 0.94);

    // the reset time: noon local, so an hour on is the same date in any
    // zone; what is expected is built from new Date(ms), as the panel does
    const noon = new Date(2026, 8, 23, 12, 0, 0).getTime();
    const hm = ms => { const d = new Date(ms); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); };
    const day = ms => ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][new Date(ms).getDay()];
    const in1h = noon + 3600000, in2d = noon + 2 * 86400000;
    check('CO.at: HH:mm today, the weekday on another day, nothing once passed or unset',
        CO.at(in1h, noon) === hm(in1h) && /^\d\d:\d\d$/.test(CO.at(in1h, noon)) &&
        CO.at(in2d, noon) === day(in2d) + ' ' + hm(in2d) && /^[A-Z][a-z]{2} \d\d:\d\d$/.test(CO.at(in2d, noon)) &&
        CO.at(noon - 1000, noon) === '' && CO.at(noon, noon) === '' && CO.at(null, noon) === '' && CO.at(0, noon) === '');
    const w5 = (o) => Object.assign({ label: '5h', percent: 42, severity: 'normal', limited: false, resetsAt: in1h }, o);
    const wk = (o) => Object.assign({ label: 'week', percent: 46, severity: 'normal', limited: false, resetsAt: in2d }, o);
    check('CO.resetFor: the latest limited reset ahead, else the 5h one ahead, else null',
        CO.resetFor([w5({ limited: true }), wk({ limited: true })], noon) === 'week' &&
        CO.resetFor([w5({ limited: true }), wk()], noon) === '5h' &&
        CO.resetFor([w5(), wk({ limited: true, resetsAt: noon - 1000 })], noon) === '5h' &&
        CO.resetFor([w5(), wk()], noon) === '5h' &&
        CO.resetFor([w5({ resetsAt: noon - 1000 }), wk()], noon) === null &&
        CO.resetFor([wk({ label: 'chat' })], noon) === null &&
        CO.resetFor(null, noon) === null && CO.resetFor([], noon) === null);
    const resetSnap = (windows, view) => ({ at: noon, config: { maxRows: 2, usageView: view }, rows: [],
        header: { notes: [], usage: [{ provider: 'Claude', stale: false, status: '11:58', windows: windows }] } });
    const runs = (s) => CO.lines(s, noon, true)[0];
    const plain = runs(resetSnap([w5(), wk()]));
    const plainRun = plain.filter(r => r[0].indexOf(' resets ') === 0);
    check('lines view: " resets HH:mm" after the 5h percent, dim, once a line',
        plain.map(r => r[0]).join('').indexOf('5h 42% resets ' + hm(in1h) + ' \u00B7 week 46%') > 0 &&
        plainRun.length === 1 && plainRun[0][1] === 'dim' && plainRun[0][2] === false);
    const blocked = runs(resetSnap([w5({ limited: true, percent: 100 }), wk({ limited: true, percent: 100 })]));
    const blockedRun = blocked.filter(r => r[0].indexOf(' resets ') === 0);
    check('lines view: when limited, the latest reset, and critical',
        blocked.map(r => r[0]).join('').indexOf('week 100% resets ' + day(in2d) + ' ' + hm(in2d)) > 0 &&
        blockedRun.length === 1 && blockedRun[0][1] === 'critical');
    check('no reset text once it passed, with no reset, or in the bars view',
        !runs(resetSnap([w5({ resetsAt: noon - 1000 }), wk()])).some(r => r[0].indexOf(' resets ') === 0) &&
        !runs(resetSnap([w5({ resetsAt: undefined }), wk()])).some(r => r[0].indexOf(' resets ') === 0) &&
        !CO.lines(resetSnap([w5(), wk()], 'bars'), noon, true).some(l => l.some(r => r[0].indexOf(' resets ') === 0)));
    const askNote = { text: 'limit over at 13:00 - 3 chats it cut off can continue', tone: 'warn', kind: 'ask' };
    const askFlat = CO.lines({ at: noon, rows: [], header: { usage: [], notes: [askNote], ask: { count: 3 } } }, noon, true);
    check('the ask note is drawn as notes are, in warn', askFlat.some(l => l[0][0] === askNote.text && l[0][1] === 'warn'));
    check('the menu offers to continue only while the snapshot asks',
        CO.askTitle({ header: { ask: { count: 3 } } }) === 'Continue 3 cut-off chats' &&
        CO.askTitle({ header: { ask: { count: 1 } } }) === 'Continue 1 cut-off chat' &&
        CO.askTitle({ header: { ask: null } }) === '' && CO.askTitle({ header: {} }) === '' && CO.askTitle(null) === '');
    check('the menu answers through overlay-cmd as quit does, naming the cut-offs its items showed',
        /CO\.askLine\('ask-go', askKeys\) \+ '\\n'/.test(js) && /CO\.askLine\('ask-leave', askKeys\) \+ '\\n'/.test(js) && /' stop\\n'/.test(js) &&
        /askKeys = keys;/.test(js));
    check('its keys: the drawn snapshot\'s, only id_uuid shapes; none drawn says none, which answers nothing',
        CO.askKeys({ header: { ask: { count: 2, keys: ['a1-b_c2', 'bad key', 'x_y'] } } }) === 'a1-b_c2,x_y' && CO.askKeys({ header: {} }) === '' && CO.askKeys(null) === '' &&
        CO.askLine('ask-go', 'a1-b_c2,x_y') === 'ask-go a1-b_c2,x_y' && CO.askLine('ask-leave', '') === 'ask-leave none');

    // auto-continue's automatic mode (0.9.0): the CQ menu's item, checked
    // while the snapshot says on, and a click writes the verb for the
    // collector to set - on, or back to the default, ask
    check('auto-continue: checked only while the snapshot says on - ask, off or nothing are not; a click asks for on, or back to ask',
        !CO.autoOn(null) && !CO.autoOn({ header: {} }) && !CO.autoOn({ header: { autoContinue: 'ask' } }) && !CO.autoOn({ header: { autoContinue: 'off', autoOn: false } }) &&
        CO.autoOn({ header: { autoContinue: 'on', autoOn: true } }) &&
        CO.autoVerb({ header: { autoContinue: 'on' } }) === 'auto-ask' && CO.autoVerb({ header: { autoContinue: 'ask' } }) === 'auto-on' && CO.autoVerb({ header: { autoContinue: 'off' } }) === 'auto-on');
    check('auto-continue: the item is in the CQ menu, its check kept by each tick, its click through overlay-cmd',
        /add\('Auto-continue cut-off chats', 'toggleAuto:'\)/.test(js) && /autoItem\.setState\(CO\.autoOn\(snap\) \? 1 : 0\)/.test(js) &&
        /'toggleAuto:'[\s\S]*?CO\.autoVerb\(snap\)/.test(js));
    const autoRow = { key: 'c:1', status: 'cutoff', rank: 0.5, project: 'p', title: 'cut chat', prompt: null, stateText: '#12 auto 13:01' };
    const autoFlat = CO.lines({ at: noon, config: { maxRows: 4 }, rows: [autoRow], header: { usage: [], notes: [] } }, noon, true).map(l => l.map(r => r[0]).join(''));
    check('auto-continue: a cut-off row shows its words as the rows give them', autoFlat.some(l => l.indexOf('cut chat') >= 0 && /#12 auto 13:01$/.test(l)), autoFlat.join(' / '));
}
console.log('');
console.log('  ' + (total - failed) + ' passed, ' + failed + ' failed');
process.exit(failed);
