// Checks docs/reply.html's side of the PC -> phone channel and the phone's
// board (docs/phone-board-spec.md): lifts the page's crypto and board blocks
// out and holds them to tests/fixtures/down-vector.json and
// compose-vector.json - made by Node's own crypto and zlib, as the watcher is
// held to them in tests/sections/phone-board.ps1 - then drives what the board
// block decides (the answer's blocks, the search, each chat's acts), and last
// the whole page under a small fake DOM, a clock and timers it moves by
// hand, and a fake ntfy server: the board drawn from a sealed answer, a tap,
// an act sealed with the row's handle, the refresh budget, the whole answer
// on an alert's page, and that nothing opened or the raw key is ever kept.
//
//     node tests/board-page-check.js
//
// The exit code is the number of failed checks.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const nodeCrypto = require('crypto');
const webcrypto = globalThis.crypto || nodeCrypto.webcrypto;
let failed = 0, total = 0;
const check = (name, ok, detail) => {
    total++;
    if (!ok) failed++;
    console.log((ok ? '  ok    ' : '  FAIL  ') + name + (ok || detail === undefined ? '' : '  ' + detail));
};
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'docs', 'reply.html'), 'utf8');
const dv = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'down-vector.json'), 'utf8'));
const cv = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'compose-vector.json'), 'utf8'));
const HANGUL = String.fromCharCode(0xD55C, 0xAE00);

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64 = (s) => Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const hmac = (key, msg) => nodeCrypto.createHmac('sha256', key).update(typeof msg === 'string' ? Buffer.from(msg, 'utf8') : msg).digest();
const ABC = 'abcdefghijklmnopqrstuvwxyz234567';
const topicOf = (d) => 'chatq-' + Array.from(hmac(Buffer.from(d), 'chatq-down-topic').subarray(0, 24), (b) => ABC[b % 32]).join('');
// what the PC sends: "chatq3d." + did, the JSON raw-deflated then sealed
// under HMAC(D, "chatq-down:" + did). opt.raw: the bytes as given, no deflate
const sealDown = (d, did, obj, opt) => {
    opt = opt || {};
    const text = typeof obj === 'string' ? obj : JSON.stringify(obj);
    const z = opt.bytes || (opt.raw ? Buffer.from(text, 'utf8') : zlib.deflateRawSync(Buffer.from(text, 'utf8')));
    const k = hmac(Buffer.from(d), 'chatq-down:' + did);
    const iv = nodeCrypto.randomBytes(16);
    const c = nodeCrypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), iv);
    const head = (opt.prefix || 'chatq3d') + '.' + did + '.' + b64url(iv) + '.' + b64url(Buffer.concat([c.update(z), c.final()]));
    return head + '.' + b64url(hmac(hmac(k, 'mac'), head));
};
// what the watcher does with a "chatq3c." message: null for what it drops
const openCompose = (message, d) => {
    const p = String(message).split('.');
    if (p.length !== 5 || p[0] !== 'chatq3c' || !/^[a-z2-7]{10}$/.test(p[1])) return null;
    const k = hmac(Buffer.from(d), 'chatq-phone:' + p[1]);
    const want = hmac(hmac(k, 'mac'), p.slice(0, 4).join('.'));
    const got = unb64(p[4]);
    if (got.length !== want.length || !nodeCrypto.timingSafeEqual(got, want)) return null;
    try {
        const dc = nodeCrypto.createDecipheriv('aes-256-cbc', hmac(k, 'enc'), unb64(p[2]));
        const text = Buffer.concat([dc.update(unb64(p[3])), dc.final()]).toString('utf8');
        return { cid: p[1], text, json: JSON.parse(text) };
    } catch (e) {
        return null;
    }
};
const openAlert = (message, d) => {
    const p = String(message).split('.');
    if (p.length !== 5 || p[0] !== 'chatq1') return null;
    const k = hmac(Buffer.from(d), 'chatq-alert:' + p[1]);
    if (!hmac(hmac(k, 'mac'), p.slice(0, 4).join('.')).equals(unb64(p[4]))) return null;
    const dc = nodeCrypto.createDecipheriv('aes-256-cbc', hmac(k, 'enc'), unb64(p[2]));
    return { aid: p[1], json: JSON.parse(Buffer.concat([dc.update(unb64(p[3])), dc.final()]).toString('utf8')) };
};

// --- the fixtures: still what Node's crypto and zlib make --------------------------
{
    const master = unb64(dv.master);
    check('the down fixture: its topic is Node\'s HMAC of D, and its deflate is zlib\'s of the payload', topicOf(master) === dv.downTopic &&
        zlib.inflateRawSync(unb64(dv.deflated)).toString('utf8') === dv.payload && dv.payload.indexOf(HANGUL) > 0);
    const k = hmac(master, 'chatq-down:' + dv.did);
    const c = nodeCrypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), unb64(dv.iv));
    const head = 'chatq3d.' + dv.did + '.' + dv.iv + '.' + b64url(Buffer.concat([c.update(unb64(dv.deflated)), c.final()]));
    check('the down fixture: k and the message are Node\'s', dv.k === b64url(k) && dv.message === head + '.' + b64url(hmac(hmac(k, 'mac'), head)));
    const o = openCompose(cv.message, master);
    check('the compose fixture opens as the watcher opens it, to the payload exactly', !!o && o.cid === cv.cid && o.text === cv.payload && cv.k === b64url(hmac(master, 'chatq-phone:' + cv.cid)));
}

// --- the page's blocks -----------------------------------------------------------------
const slice = (name) => {
    const b = '/* chatq-' + name + '-begin */', e = '/* chatq-' + name + '-end */';
    const i = html.indexOf(b), j = html.indexOf(e);
    if (i < 0 || j < i || html.indexOf(b, i + 1) >= 0 || html.indexOf(e, j + 1) >= 0) return null;
    return html.slice(i + b.length, j);
};
const cryptoJs = slice('crypto'), logicJs = slice('logic'), boardJs = slice('board');
check('the board block is marked, once, after the logic block', boardJs !== null && html.indexOf('chatq-board-begin') > html.indexOf('chatq-logic-end'));
const codeOnly = (js) => String(js).replace(/'(?:[^'\\\n]|\\.)*'/g, "''").replace(/\/\/.*$/gm, '');
check('the board block touches no page: no document, window, location, storage, navigator or fetch',
    boardJs !== null && !/\b(document|window|location|sessionStorage|localStorage|indexedDB|navigator|fetch|XMLHttpRequest)\b/.test(codeOnly(boardJs)));
const GLOBALS = ['crypto', 'TextEncoder', 'btoa', 'atob', 'URL'];
const globalsArgs = [webcrypto, TextEncoder, btoa, atob, URL];
let B = null, P = null, C = null;
try {
    const all = new Function(...GLOBALS, (cryptoJs || '') + '\n' + (logicJs || '') + '\n' + (boardJs || '') + '\nreturn { C: ChatqCrypto, P: ChatqPage, B: ChatqBoard };')(...globalsArgs);
    B = all.B; P = all.P; C = all.C;
} catch (e) {
    console.log('  ' + e.message);
}
check('the board block runs on top of the other two, under Node\'s webcrypto', !!B && typeof B.openDown === 'function');

// the watcher's own lists, read from its source: every act the page sends is
// one it takes, and every one it takes is one the page can send
const psBoard = fs.readFileSync(path.join(root, 'src', 'phone-board.ps1'), 'latin1');
const actsBlock = (/\$script:ChatqComposeActs = @\{([\s\S]*?)\n\}/.exec(psBoard) || [])[1] || '';
const watcherActs = [...actsBlock.matchAll(/^\s+(\w+) = @\{ Age/gm)].map((m) => m[1]).sort();
const psPhone = fs.readFileSync(path.join(root, 'src', 'phone.ps1'), 'latin1');

(async () => {
    if (!B) { finish(); return; }
    const master = new Uint8Array(unb64(dv.master));
    check('the down topic: the fixture\'s, from the raw D and from a key that will not export', (await B.downTopic(master)) === dv.downTopic &&
        (await B.downTopic(await C.phoneKey(new Uint8Array(master)))) === dv.downTopic);
    const od = await B.openDown(master, dv.message, dv.did);
    check('openDown: Node\'s message opens - MAC, AES, the browser\'s own raw inflate, JSON - to the payload exactly', od.ok && JSON.stringify(od.payload) === JSON.stringify(JSON.parse(dv.payload)) &&
        od.payload.parts[0].s === 'yes, commit it ' + HANGUL, JSON.stringify(od));
    const pk = await C.phoneKey(new Uint8Array(master));
    check('and with the kept key, which will not export', (await B.openDown(pk, dv.message, dv.did)).ok);
    const x = { h: 'k3m2qa', id: '1a2b3c4d', text: 'yes, commit it ' + HANGUL };
    check('the compose payload: the spec\'s key order, byte for byte the fixture\'s', B.buildComposePayload('send', B.fieldsFor('send', x), 'AAAAAAAAAAAAAAAAAAAAAA', 1790000000000) === cv.payload);
    const sealed = await B.compose(pk, 'send', x, { cid: cv.cid, iv: new Uint8Array(unb64(cv.iv)), nonce: 'AAAAAAAAAAAAAAAAAAAAAA', ts: 1790000000000 });
    check('compose(): the fixture\'s message, byte for byte, sealed with the kept key', sealed.message === cv.message, sealed.message);
    const fresh = await B.compose(pk, 'board', {});
    const fo = openCompose(fresh.message, master);
    check('a fresh one: a new cid, nonce and time each time, and the watcher opens it', !!fo && fo.cid === fresh.cid && B.idOk(fresh.cid) && fo.json.act === 'board' &&
        Object.keys(fo.json).join() === 'v,act,nonce,ts' && fresh.cid !== (await B.compose(pk, 'board', {})).cid);
    const orders = { send: 'v,act,h,id,text,nonce,ts', new: 'v,act,h,name,text,nonce,ts', now: 'v,act,h,n,nonce,ts', skip: 'v,act,h,n,nonce,ts', read: 'v,act,h,nonce,ts', continue: 'v,act,h,nonce,ts', list: 'v,act,nonce,ts', status: 'v,act,nonce,ts' };
    const wrongOrder = Object.keys(orders).filter((a) => Object.keys(JSON.parse(B.buildComposePayload(a, B.fieldsFor(a, { h: 'abcdef', id: 'x', text: 't', n: 3, name: 'n' }), 'n', 1))).join() !== orders[a]);
    check('every act\'s fields in the order the watcher reads them', wrongOrder.length === 0, wrongOrder.join());
    check('the page\'s acts are the watcher\'s ($script:ChatqComposeActs), both ways', watcherActs.length > 0 && B.ACTS.slice().sort().join() === watcherActs.join(), B.ACTS.slice().sort().join() + ' vs ' + watcherActs.join());
    check('and read, the alert act the page adds, is one Invoke-ChatqReply takes', B.ALERT_ACTS.join() === 'read' && /^\s+'read' \{/m.test(psPhone));
    check('answer is in both ACTS - the board\'s and the alert page\'s', B.ACTS.indexOf('answer') >= 0 && P.ACTS.indexOf('answer') >= 0);

    // --- what openDown refuses -------------------------------------------------------------
    const D = new Uint8Array(nodeCrypto.randomBytes(32)), did = 'klmnopqrst';
    const good = { v: 3, kind: 'ack', ref: did, ok: true, say: 'ok' };
    const why = async (m, d) => (await B.openDown(D, m, d === undefined ? did : d)).why;
    const flip = (m, i) => { const p = m.split('.'); p[i] = (p[i][0] === 'A' ? 'B' : 'A') + p[i].slice(1); return p.join('.'); };
    const ok1 = sealDown(D, did, good);
    check('openDown refuses: another prefix, another did, ref not its did, a changed byte, a key not the phone\'s', (await B.openDown(D, ok1, did)).ok &&
        (await why(sealDown(D, did, good, { prefix: 'chatq3c' }))) === 'format' && (await why(ok1, 'zzzzzzzzzz')) === 'did' &&
        (await why(sealDown(D, did, Object.assign({}, good, { ref: 'abcdefghij' })))) === 'json' && (await why(flip(ok1, 3))) === 'mac' && (await why(flip(ok1, 4))) === 'mac' &&
        (await B.openDown(new Uint8Array(32), ok1, did)).why === 'mac');
    check('openDown refuses: a payload that is not v 3, JSON that is not, bytes that are not raw deflate',
        (await why(sealDown(D, did, Object.assign({}, good, { v: 2 })))) === 'json' && (await why(sealDown(D, did, 'not json'))) === 'json' &&
        (await why(sealDown(D, did, good, { raw: true }))) === 'inflate');
    const bomb = zlib.deflateRawSync(Buffer.alloc(5 * 1024 * 1024, 0x61));
    check('openDown stops a deflate bomb: 5 MB from ' + bomb.length + ' bytes, refused past 4 MB', (await why(sealDown(D, did, null, { bytes: bomb }))) === 'inflate' &&
        (await B.inflateRaw(new Uint8Array(zlib.deflateRawSync(Buffer.from('x'.repeat(1000)))), 100)) === null);
    check('parseFeed: the messages only, oldest first; junk lines dropped', B.parseFeed('{"event":"open"}\nnot json\n{"event":"message","id":"a","message":"m1"}\n\n{"event":"message","id":"b"}').map((m) => m.id).join() === 'a,b');
    check('pollUrl: the down topic, since, and exactly its did as the title', B.pollUrl('https://ntfy.sh', 'chatq-x', 1790000000, 'abcdefghij') === 'https://ntfy.sh/chatq-x/json?poll=1&since=1790000000&title=abcdefghij');
    const att = (x) => Object.assign({ url: 'https://ntfy.sh/file/abc.txt', size: 5000, expires: 1790003600 }, x);
    check('an attachment: only the server\'s own /file/, 2 MB at most, and gone past its expiry',
        B.attachmentCheck('https://ntfy.sh', att(), 1790000000000) === 'ok' && B.attachmentCheck('https://ntfy.sh', att({ url: 'https://evil.example/file/abc.txt' }), 1790000000000) === 'bad' &&
        B.attachmentCheck('https://ntfy.sh', att({ url: 'https://ntfy.sh/other/abc.txt' }), 1790000000000) === 'bad' &&
        B.attachmentCheck('https://ntfy.sh', att({ url: 'http://ntfy.sh/file/abc.txt' }), 1790000000000) === 'bad' &&
        B.attachmentCheck('https://ntfy.sh', att({ size: 3 * 1024 * 1024 }), 1790000000000) === 'bad' && B.attachmentCheck('https://ntfy.sh', att(), 1790009999000) === 'gone');

    // --- the link, the answer's blocks, the search, the acts --------------------------------
    const fr = P.parseFragment('#v=2&a=abcdefgh23&e=done&n=3&c=x&p=claude&j=done&f=1&o=1790000000');
    check('parseFragment: f=1 and o= read; alertFragment keeps them', fr.ok && fr.f.full === true && fr.f.at === 1790000000 &&
        /&f=1&o=1790000000$/.test(P.alertFragment(fr.f)) && P.parseFragment('#v=2&a=abcdefgh23&e=done&o=x').f.at === 0 && P.parseFragment('#v=2&a=abcdefgh23&e=done').f.full === false);
    const md = B.mdBlocks('# Result\nIt is `x = 1` and **bold** here.\n\n```js\nconst a = 1;\n```\n| a | b |\n|---|---|\n- one\n- two');
    check('the answer as blocks: a heading, inline code and bold, a fence (its language word dropped), a table in one block, a list kept as written',
        md.map((b) => b.t).join() === 'h,p,pre,pre,p' && md[0].s === 'Result' && md[1].spans.map((s) => s.t).join() === 'text,code,text,b,text' &&
        md[2].s === 'const a = 1;' && md[3].table === true && md[3].s.split('\n').length === 2 && md[4].spans[0].s === '- one\n- two', JSON.stringify(md));
    const am = B.answerModel([{ t: 'text', s: 'a' }, { t: 'tool', s: 'Bash ls' }, { t: 'tool', s: 'Read x' }, { t: 'text', s: 'b' }, { t: 'tool', s: '1' }, { t: 'tool', s: '2' }, { t: 'tool', s: '3' }, { t: 'note', s: 'limit' }]);
    check('tools: two in a row as lines, three or more folded into one; a note on its own', am.map((b) => b.t).join() === 'p,tool,tool,p,tools,note' && am[4].items.join() === '1,2,3');
    check('Copy copies the text, a tool as "-> ..."', B.answerText([{ t: 'text', s: 'a' }, { t: 'tool', s: 'Bash ls' }]) === 'a\n\n-> Bash ls');
    const rows = [{ t: 'Parser ' + HANGUL + ' rewrite', f: 'parser' }, { t: 'Radar viewer', f: 'as_viewer' }, { t: 'Docs', f: 'proj_AS-BW' }];
    const nfd = HANGUL.normalize('NFD');
    check('search: every word in any order, over title and folder, Hangul NFC or NFD, case aside',
        B.filterRows(rows, 'rewrite parser').length === 1 && B.filterRows(rows, nfd).length === 1 && B.filterRows(rows, 'RADAR').length === 1 &&
        B.filterRows(rows, 'as-bw').length === 1 && B.filterRows(rows, 'radar docs').length === 0 && B.filterRows(rows, '  ').length === 3);
    const acts = (type, row, b) => B.chatActions(type, row, b || {}).map((a) => a.act + (a.confirm ? '!' : '')).join();
    check('a chat\'s acts: a queued job Send now and Skip (a second tap), running Stop, needs input Continue, Allow, Skip, failed Retry, Skip; the last answer',
        acts('open', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 1, s: 'queued' }] }) === 'now,skip!,read' && acts('open', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 1, s: 'running' }] }) === 'stop!,read' &&
        acts('open', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 1, s: 'needs-input', p: 'claude' }] }) === 'retry,allow,skip!,read' &&
        acts('open', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 1, s: 'needs-input', p: 'codex' }] }) === 'retry,skip!,read' &&
        acts('open', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 1, s: 'failed' }] }) === 'retry,skip!,read');
    check('cut off: Continue at reset with nothing queued; Don\'t continue for its continue', acts('cut', { h: 'aaaaaa', jobs: [] }) === 'continue,read' &&
        B.chatActions('cut', { h: 'aaaaaa', jobs: [{ h: 'jjjjjj', n: 4, s: 'queued', k: 'continue' }] }).map((a) => a.label).join('|') === 'Send now|Don\'t continue|Read the last answer');
    const bb = { open: [{ h: 'cccccc', id8: '1a2b3c4d', t: 'Parser' }] };
    check('a queue row: its job\'s acts, and its chat\'s last answer when the board shows the chat', acts('queue', { h: 'jjjjjj', n: 7, s: 'queued', id8: '1a2b3c4d' }, bb) === 'now,skip!,read' &&
        acts('queue', { h: 'jjjjjj', n: 7, s: 'queued', id8: 'ffffffff' }, bb) === 'now,skip!');
    const secs = B.sections({ open: [{ state: 'idle' }, { state: 'waiting' }, { state: 'busy' }], cut: [], queue: [{ n: 1 }], recent: [{}] });
    check('the sections in the overlay\'s order, an empty one left out', secs.map((s) => s.key).join() === 'waiting,working,queue,idle,recent');
    // the PC's list (act list) under the board, as Older chats
    const lst = { chats: [{ h: 'aaaaaa', id: '1a2b3c4d', p: 'claude', t: 'on the board' }, { h: 'bbbbbb', id: '5e6f7a8b', p: 'codex', t: 'Codex thread', f: 'svc', m: 'workspace-write', mc: true, known: true, live: '', q: 2, ni: 0 },
        { h: 'cccccc', id: '9a8b7c6d', p: 'claude', t: 'Old', m: 'acceptEdits', known: false, live: 'busy', ni: 12 }, { id: 'nohandle' }], more: 40 };
    const ol = B.olderRows(bb, lst);
    const olSecs = B.sections(bb, lst).map((s) => s.key).join();
    check('older chats: the list\'s, after Recent - none the board shows, none without a handle', olSecs === 'older' && ol.map((r) => r.h).join() === 'bbbbbb,cccccc' && ol[0].id8 === '5e6f7a8b' &&
        B.sections(bb, null).length === 0, olSecs + ' / ' + ol.map((r) => r.h).join());
    const cxv = B.rowView('older', ol[0], Date.now());
    check('an older chat: its folder and provider, its jobs as chips; its own mode once capped, else the cap; where a message goes',
        cxv.sub === 'svc \u00b7 codex' && cxv.chips.map((c) => c.text).join() === '2 queued' && B.modeText({ cap: 'acceptEdits' }, false, ol[0]) === 'workspace-write (phone\'s limit)' &&
        B.modeText({ cap: 'acceptEdits' }, false, ol[1]) === 'at most acceptEdits' && B.stateLine('older', ol[0]) === 'a message goes after the 2 queued for it' &&
        /^#12 needs input - a message does not answer it/.test(B.stateLine('older', ol[1])) && B.rowView('older', ol[1], Date.now()).sub === 'working',
        cxv.sub + ' / ' + B.modeText({ cap: 'acceptEdits' }, false, ol[0]) + ' / ' + B.stateLine('older', ol[0]));
    check('its acts: the last answer for a Claude chat only - the PC reads it from a Claude transcript', acts('older', ol[0]) === '' && acts('older', ol[1]) === 'read');
    // where 'run': a print-mode run - a queued prompt - is no terminal
    const runRow = { h: 'rrrrrr', id8: '7a7a7a7a', t: 'Run', f: 'proj', where: 'run', state: 'busy', jobs: [] };
    check('a chat a queued prompt runs in: "a queued prompt" where a terminal would say terminal, and a message goes after it',
        B.whereText('run') === 'a queued prompt' && B.whereText('terminal') === 'terminal' && B.whereText('bogus') === '' &&
        B.rowView('open', runRow, Date.now()).sub === 'proj \u00b7 a queued prompt' &&
        B.stateLine('open', runRow) === 'a queued prompt is running in it - a message goes after it' &&
        B.stateLine('open', Object.assign({}, runRow, { jobs: [{ n: 9, s: 'running' }] })) === '#9 is running now - a message goes after it',
        B.rowView('open', runRow, Date.now()).sub + ' / ' + B.stateLine('open', runRow));
    // what the watcher holds a job back for reads as it is, not after "sends"
    const heldBg = { h: 'hhhhhh', id8: '8b8b8b8b', t: 'Held', f: 'proj', where: 'vscode', state: 'idle', jobs: [{ n: 5, s: 'queued', e: 'waits for a background command (since 14:02)', k: 'prompt' }] };
    const heldTab = Object.assign({}, heldBg, { jobs: [{ n: 6, s: 'queued', e: 'waits for you to leave its tab', k: 'continue' }] });
    check('a job held for a background command, or for you to leave its tab: its chip and the chat view say so as they are; a time still "sends"',
        B.rowView('open', heldBg, Date.now()).chips[0].text === '#5 waits for a background command (since 14:02)' &&
        B.stateLine('open', heldBg) === '#5 is queued - waits for a background command (since 14:02)' &&
        B.rowView('open', heldTab, Date.now()).chips[0].text === '#6 waits for you to leave its tab' &&
        B.rowView('open', Object.assign({}, heldBg, { jobs: [{ n: 7, s: 'queued', e: '14:05', k: 'prompt' }] }), Date.now()).chips[0].text === '#7 sends 14:05',
        B.rowView('open', heldBg, Date.now()).chips[0].text + ' / ' + B.stateLine('open', heldBg));
    check('the usage lines: the provider on its first window, the reset when limited, "as of" when stale', JSON.stringify(B.usageLines([{ p: 'Claude', stale: true, asof: '2026-09-26T01:00:00Z', parts: [{ w: '5h', pct: 100, limited: true, reset: '2026-09-26T02:10:00Z' }, { w: 'week', pct: 18 }] }]).map((l) => [l.name, l.w, l.pct, l.tone, !!l.right])) ===
        JSON.stringify([['Claude', '5h', 100, 'bad', true], ['', 'week', 18, 'ok', false]]));
    check('the footer: listens all the time, or until when', B.listenText({ listen: 'always' }) === 'Listens all the time' && /^Listens until \d\d:\d\d \(an alert is out\)$/.test(B.listenText({ listen: 'alerts', until: '2026-09-26T02:10:00Z' })));
    const av = B.askView({ k: 'x', more: 2, cut: true, q: [{ h: 'Log', t: 'Which way? ' + HANGUL, m: false, o: [{ l: 'Integrate', d: 'one file' }, { l: 'Delete', x: 1 }] }, { h: '', t: 'Where?', m: true, o: [{ l: 'Bench', d: 'here' }] }] });
    check('askView: a card per question - n of m, its header, its text, every option and its description, a multiple choice said - the extra and the cut said, and answered at the PC',
        av.kicker === 'Claude asks 2 questions' && av.cards[0].n === '1 of 2' && av.cards[0].head === 'Log' && av.cards[0].text === 'Which way? ' + HANGUL && !av.cards[0].multi &&
        av.cards[0].options.map((o) => o.label + ':' + o.desc + ':' + o.cut).join('|') === 'Integrate:one file:false|Delete::true' && av.cards[1].multi && av.cards[1].head === '' &&
        av.notes.length === 2 && /2 more options or questions/.test(av.notes[0]) && /cut short/.test(av.notes[1]) && av.foot === 'Answer it at the PC.', JSON.stringify(av));
    check('askView: one question has no "1 of 1"; nothing to show is null', B.askView({ q: [{ t: 'Sure?', o: [] }] }).cards[0].n === '' && B.askView({ q: [{ t: 'Sure?' }] }).kicker === 'Claude asks' &&
        B.askView(null) === null && B.askView({ q: [] }) === null && B.askView({}) === null);
    check('askView, Part A (no can): no controls, no Send, answered at the PC', !av.open && av.send === null && av.cards.every((c) => c.input === '') && av.rid === '');

    // --- Part B: answering it from the phone (docs/phone-ask-spec.md, 4.5 and 5) ---
    const now0 = 1790000000000, untilIso = new Date(now0 + 3600000).toISOString(), hm = B.hhmm(untilIso);
    const q2 = [{ h: 'Log', t: 'Which way?', m: false, o: [{ l: 'Integrate', d: 'one file' }, { l: 'Delete' }] }, { h: 'Reach', t: 'Where?', m: true, o: [{ l: 'Bench' }, { l: 'Site' }, { l: 'Lab' }] }];
    const canAsk = { k: 'toolu_x', at: new Date(now0).toISOString(), more: 0, cut: false, q: q2, can: true, rid: 'mnopqrstuv', qh: 'QUJDREVGR0hJSktMTU5PUA', until: untilIso };
    const ov = B.askView(canAsk, now0);
    check('askView, can true before until: open - a radio group, checkboxes for a multiple choice, Send answer with a second tap, the footer with the time',
        ov.open && ov.cards[0].input === 'radio' && ov.cards[1].input === 'checkbox' && ov.send.act === 'answer' && ov.send.label === 'Send answer' &&
        ov.send.confirm === 'Tap again to send' && ov.rid === 'mnopqrstuv' && ov.qh === canAsk.qh && ov.until === now0 + 3600000 &&
        ov.foot === 'The PC\'s dialog stays open too - the first answer wins. Until ' + hm + '.', JSON.stringify(ov));
    const lv = B.askView(canAsk, now0 + 3600000);
    check('askView, can true at or past until: read-only, the late words', !lv.open && lv.send === null && lv.cards.every((c) => c.input === '') &&
        lv.foot === 'Answer it at the PC - the phone could answer until ' + hm + '.', lv.foot);
    check('askView, can true with a rid or qh not in its shape, or no until: never answerable', [{ rid: 'ABC' }, { qh: 'short' }, { until: undefined }].every((x) => !B.askView(Object.assign({}, canAsk, x), now0).open));
    const whyOf = (x) => B.askView(Object.assign({ q: q2, can: false }, x), now0).foot;
    const whys = {
        off: 'Answer it at the PC. To answer from the phone: chatnotify -Ask on.',
        hook: 'Answer it at the PC - no chatq hook holds this question (it was asked before the hook was loaded in that chat, or the hook did not start).',
        term: 'Answer it in the terminal.',
        busy: 'Answer it at the PC - too many questions wait on the phone right now.',
        weird: 'Answer it at the PC.'
    };
    const whyWrong = Object.keys(whys).filter((w) => whyOf({ why: w }) !== whys[w]);
    check('askView, can false: each why in the page\'s words, in place of the footer - and no controls', whyWrong.length === 0 &&
        whyOf({ why: 'cli', cli: '2.1.201' }) === 'Answer it at the PC - Claude Code 2.1.201 is too old for answers from the phone.' &&
        whyOf({ why: 'cli' }) === 'Answer it at the PC - Claude Code is too old for answers from the phone.' &&
        whyOf({ why: 'mode', mode: 'bypassPermissions', cap: 'acceptEdits' }) === 'Answer it at the PC - that chat runs in bypassPermissions, above the phone\'s limit (acceptEdits).' &&
        whyOf({ why: 'late', until: untilIso }) === 'Answer it at the PC - the phone could answer until ' + hm + '.' && whyOf({ why: 'late' }) === 'Answer it at the PC.' &&
        !B.askView({ q: q2, can: false, why: 'off' }, now0).open, whyWrong.join() + ' / ' + whyOf({ why: 'mode', mode: 'bypassPermissions', cap: 'acceptEdits' }));
    // the choices, the wire, Send off until every question has an answer
    const st = B.answerState(ov, null);
    const form = (s, wire) => B.answerForm(ov, s, wire || 'alert', { h: 'k3m2qa', id: '1a2b3c4d' }, P.MAX_PAYLOAD);
    const off0 = !form(st).ok && !form(st).done;
    B.pickOption(st, ov, 0, 1, true);
    const off1 = !form(st).ok;
    B.pickOption(st, ov, 1, 2, true);
    B.pickOption(st, ov, 1, 0, true);
    const on2 = form(st);
    check('Send off until every question has an answer; a is the indexes ascending, o empty', off0 && off1 && on2.ok && JSON.stringify(on2.x.a) === '[[1],[0,2]]' &&
        JSON.stringify(on2.x.o) === '["",""]' && Object.keys(on2.x).join() === 'rid,qh,a,o', JSON.stringify(on2));
    B.pickOption(st, ov, 0, 0, true);
    B.pickOption(st, ov, 1, 2, false);
    B.typeOther(st, ov, 1, '  free text ' + HANGUL + ' ');
    const w3 = form(st);
    check('a single choice takes one option; a checkbox off drops it; typing in Other chooses it, trimmed on the wire', JSON.stringify(w3.x.a) === '[[0],[0]]' &&
        JSON.stringify(w3.x.o) === JSON.stringify(['', 'free text ' + HANGUL]) && st.other[1] === true, JSON.stringify(w3.x));
    B.typeOther(st, ov, 0, 'mine');
    const w4 = form(st);
    B.pickOption(st, ov, 0, 1, true);
    const w5 = form(st);
    check('Other in a single choice drops its option, and an option drops Other - one answer each way', JSON.stringify(w4.x.a[0]) === '[]' && w4.x.o[0] === 'mine' && w4.ok &&
        JSON.stringify(w5.x.a[0]) === '[1]' && w5.x.o[0] === '' && w5.ok);
    const blankOther = B.answerState(ov, null);
    B.pickOption(blankOther, ov, 0, 0, true);
    B.pickOther(blankOther, ov, 1, true);
    check('Other chosen with no text is no answer', !form(blankOther).done);
    // the PC's cleaning (spec 5.4), done before the page calls it an answer
    const unseen = B.answerState(ov, null);
    B.pickOption(unseen, ov, 0, 0, true);
    B.typeOther(unseen, ov, 1, '\u200b\u200d\ufeff');
    const unseenOff = !form(unseen).done && !form(unseen).ok;
    B.typeOther(unseen, ov, 1, '\u00ad a\u200bb\u0007' + String.fromCodePoint(0xE0001) + ' ');
    check('Other is cleaned as the PC cleans it - control and format characters made spaces, then trimmed: a zero-width space alone keeps Send off, and o is the cleaned text',
        unseenOff && form(unseen).ok && form(unseen).x.o[1] === 'a b' && B.cleanOther('\u0600x\u202e\u2066y\u0085') === 'x  y' && B.cleanOther('\u2028') === '' &&
        B.cleanOther('\u00ad') === '' && B.cleanOther(HANGUL) === HANGUL, JSON.stringify(form(unseen).x.o));
    const back = B.answerState(ov, B.answerDraft(st));
    check('the draft: the choices and the Other texts only, and it reads back; one not in the questions\' shape is dropped',
        JSON.stringify(Object.keys(JSON.parse(B.answerDraft(st)))) === '["pick","other","text"]' && JSON.stringify(back) === JSON.stringify(st) &&
        JSON.stringify(B.answerState(ov, '{"pick":[[5],[]],"other":[false,false],"text":["",""]}').pick) === '[[],[]]' &&
        JSON.stringify(B.answerState(ov, '{"pick":[[0,1],[]],"other":[false,false],"text":["",""]}').pick) === '[[],[]]' &&
        JSON.stringify(B.answerState(ov, 'junk').pick) === '[[],[]]');
    const cf = form(st, 'compose');
    check('the byte count: the whole payload, the answer\'s own on each wire', form(st).bytes === Buffer.byteLength(C.buildAnswerPayload('AAAAAAAAAAAAAAAAAAAAAA', 1790000000000, form(st).x)) &&
        cf.bytes === B.composeBytes('answer', cf.x) && Object.keys(cf.x).join() === 'h,id,rid,qh,a,o');
    const long = B.answerState(ov, null);
    B.pickOption(long, ov, 0, 0, true);
    B.typeOther(long, ov, 1, HANGUL.repeat(500));
    const lf = form(long);
    check('Other text past the limit: Send off, "N bytes too long"', lf.done && lf.over && !lf.ok && lf.label === (lf.bytes - P.MAX_PAYLOAD) + ' bytes too long', lf.label);
    // the ask fixture, the board-bound answer: Node's seal, and the page's
    let avx = null;
    try { avx = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'ask-vector.json'), 'utf8')); } catch (e) { }
    check('the ask fixture: its compose message opens as the watcher opens it, to the payload exactly', !!avx && (openCompose(avx.composeMessage, master) || {}).text === avx.composePayload &&
        avx.kPhone === b64url(hmac(master, 'chatq-phone:' + avx.cid)) && (openAlert(avx.alertMessage, master) || {}).aid === avx.aid);
    if (avx) {
        const ax = { h: avx.h, id: avx.id, rid: avx.rid, qh: avx.qh, a: avx.a, o: avx.o };
        const ap = B.buildComposePayload('answer', B.fieldsFor('answer', ax), avx.nonce, avx.ts);
        check('fieldsFor answer: h, id, rid, qh, a, o - the ask fixture\'s compose payload byte for byte', ap === avx.composePayload &&
            Object.keys(JSON.parse(ap)).join() === 'v,act,h,id,rid,qh,a,o,nonce,ts', ap);
        const as = await B.compose(pk, 'answer', ax, { cid: avx.cid, iv: new Uint8Array(unb64(avx.iv)), nonce: avx.nonce, ts: avx.ts });
        check('compose(): the ask fixture\'s message byte for byte, sealed with the kept key', as.message === avx.composeMessage, as.message);
        check('and the alert-bound one from the crypto block, byte for byte', (await C.sealAnswer(await C.alertKey(pk, avx.aid), avx.aid, { rid: avx.rid, qh: avx.qh, a: avx.a, o: avx.o },
            { iv: new Uint8Array(unb64(avx.iv)), nonce: avx.nonce, ts: avx.ts })).message === avx.alertMessage);
    }

    // --- the page itself -----------------------------------------------------------------------
    check('the page sets no markup from anything: no innerHTML, outerHTML, insertAdjacentHTML or document.write', !/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(html));
    const csp = (html.match(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"/i) || [])[1];
    check('the CSP is 0.8.0\'s, unchanged', csp === "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src https:; img-src data:; base-uri 'none'; form-action 'none'", csp);
    check('the page is ASCII still', /^[\x00-\x7f]*$/.test(html));
    await drive();
    finish();
})().catch((e) => {
    console.log('  FAIL  threw: ' + (e && e.stack || e));
    failed++;
    finish();
});

function finish() {
    console.log('');
    console.log('  ' + (total - failed) + ' passed, ' + failed + ' failed');
    process.exit(failed);
}

// --- the page under a fake DOM ---------------------------------------------------------------
async function drive() {
    const script = (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
    const tags = [...html.matchAll(/<(\w+)\b([^>]*?)\bid="([^"]+)"([^>]*)>/g)];
    const SERVER = 'https://ntfy.sh', TOPIC = 'chatq-topictopictopictopic12';
    const D = nodeCrypto.randomBytes(32);
    const DOWN = topicOf(D);
    let clock = 1790000000000;
    class FakeDate extends Date {
        constructor(...a) { if (a.length) super(...a); else super(clock); }
        static now() { return clock; }
    }
    const realSetTimeout = setTimeout;
    const settle = () => new Promise((r) => realSetTimeout(r, 15));
    const waitFor = async (ok) => { for (let i = 0; i < 300 && !ok(); i++) await settle(); return ok(); };
    const dbs = new Map();
    const key = await webcrypto.subtle.importKey('raw', D, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const code = String(hmac(D, 'chatq-confirm').readUInt32BE(0) % 1000000).padStart(6, '0');
    // the phone, paired: its record in IndexedDB, the key a CryptoKey that will not export
    dbs.set('chatq', { version: 1, stores: new Map([['phone', new Map([['phone', { v: 3, s: SERVER, t: TOPIC, key, at: 1789990000000, h: 'DESKTOP-7', code }]])]]) });
    const idb = {
        open(name) {
            const req = {};
            realSetTimeout(() => {
                const db = dbs.get(name);
                req.result = {
                    objectStoreNames: { contains: (n) => db.stores.has(n) }, close() { },
                    transaction: (n) => {
                        const st = db.stores.get(n), tx = {}, work = [];
                        tx.objectStore = () => ({
                            get: (k) => { const r = {}; work.push(() => { r.result = st.get(k); if (r.onsuccess) r.onsuccess({}); }); return r; },
                            put: (v, k) => { const r = {}; work.push(() => { st.set(k, v); if (r.onsuccess) r.onsuccess({}); }); return r; }
                        });
                        realSetTimeout(() => { work.forEach((w) => w()); if (tx.oncomplete) tx.oncomplete({}); }, 0);
                        return tx;
                    }
                };
                if (req.onsuccess) req.onsuccess({});
            }, 0);
            return req;
        }
    };
    const store = new Map(), local = new Map();
    const storage = (m) => ({ setItem: (k, v) => m.set(k, String(v)), getItem: (k) => (m.has(k) ? m.get(k) : null), removeItem: (k) => m.delete(k) });
    const load = async (hash) => {
        const doc = { activeElement: null, title: '', els: {}, visibilityState: 'visible', on: {} };
        doc.addEventListener = (t, fn) => { (doc.on[t] = doc.on[t] || []).push(fn); };
        const el = (id, tag) => {
            const e = {
                id, tagName: String(tag || 'div').toUpperCase(), hidden: false, disabled: false, value: '', placeholder: '', type: '', className: '',
                attrs: {}, kids: [], on: {}, cls: new Set(), _text: '',
                get textContent() { return this._text; },
                set textContent(v) { this._text = String(v); this.kids = []; },
                get children() { return this.kids; },
                get firstChild() { return this.kids[0] || null; },
                get lastChild() { return this.kids[this.kids.length - 1] || null; },
                setAttribute(k, v) { this.attrs[k] = String(v); },
                getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
                removeAttribute(k) { delete this.attrs[k]; },
                addEventListener(t, fn) { (this.on[t] = this.on[t] || []).push(fn); },
                fire(t, ev) { (this.on[t] || []).forEach((fn) => fn(ev || { preventDefault() { } })); },
                appendChild(c) { this.kids.push(c); return c; },
                insertBefore(c, ref) { const i = ref ? this.kids.indexOf(ref) : -1; if (i < 0) this.kids.push(c); else this.kids.splice(i, 0, c); return c; },
                removeChild(c) { this.kids.splice(this.kids.indexOf(c), 1); return c; },
                querySelectorAll(sel) { return this.kids.filter((c) => c.tagName === sel.toUpperCase()); },
                focus() { doc.activeElement = this; },
                blur() { if (doc.activeElement === this) doc.activeElement = null; }
            };
            e.classList = { toggle: (c, on) => { if (on === undefined ? !e.cls.has(c) : on) e.cls.add(c); else e.cls.delete(c); }, contains: (c) => e.cls.has(c) };
            return e;
        };
        tags.forEach((m) => { doc.els[m[3]] = el(m[3], m[1]); doc.els[m[3]].hidden = /\shidden(\s|=|$)/.test(m[2] + ' ' + m[4]); });
        doc.getElementById = (id) => doc.els[id] || null;
        doc.createElement = (tag) => el('', tag);
        const loc = { hash, pathname: '/claude-codex-chat-manager/reply.html', search: '' };
        const hist = { replaceState: (s, t, url) => { loc.hash = url.indexOf('#') >= 0 ? url.slice(url.indexOf('#')) : ''; } };
        const win = { crypto: webcrypto, TextEncoder, addEventListener() { } };
        const page = { doc, posts: [], gets: [], feed: new Map(), files: new Map(), timers: [] };
        // the ntfy server: a POST recorded, a GET of the down topic answered
        // with what page.feed holds for that title, a GET of a file with page.files
        const fakeFetch = (url, o) => {
            // page.postAnswer: what the server says to a POST, 200 unless set
            if (o && o.method === 'POST') { page.posts.push({ url, o }); return Promise.resolve(page.postAnswer || { ok: true, status: 200 }); }
            page.gets.push({ url, o });
            const u = new URL(url);
            if (u.pathname.indexOf('/file/') === 0) {
                const f = page.files.get(u.pathname);
                return Promise.resolve(f ? { ok: true, status: 200, text: async () => f } : { ok: false, status: 404 });
            }
            const lines = (page.feed.get(u.searchParams.get('title')) || []).map((m, i) => JSON.stringify(Object.assign({ id: 'm' + i, time: 1, event: 'message', topic: DOWN, title: u.searchParams.get('title') }, m)));
            return Promise.resolve({ ok: true, status: 200, text: async () => lines.join('\n') + '\n' });
        };
        const fakeSetTimeout = (fn, ms) => { page.timers.push({ fn, ms, at: clock + (ms || 0) }); return page.timers.length; };
        const nav = { userAgent: 'Mozilla/5.0 (Linux; Android 14) Chrome/128.0.0.0 Mobile' };
        const names = ['document', 'window', 'location', 'history', 'sessionStorage', 'localStorage', 'indexedDB', 'navigator', 'fetch', 'crypto', 'TextEncoder',
            'btoa', 'atob', 'URL', 'Date', 'setTimeout', 'clearTimeout', 'AbortController'];
        new Function(...names, script)(doc, win, loc, hist, storage(store), storage(local), idb, nav, fakeFetch, webcrypto, TextEncoder, btoa, atob, URL, FakeDate,
            fakeSetTimeout, (id) => { if (page.timers[id - 1]) page.timers[id - 1].done = true; }, AbortController);
        page.$ = (id) => doc.els[id];
        // every timer due by now, run - and the ones they set, up to ms ahead
        page.run = async (ms) => {
            const until = clock + (ms || 0);
            for (let n = 0; n < 1000; n++) {
                await settle();
                const due = page.timers.filter((t) => !t.done && t.at <= until);
                if (!due.length) break;
                due.sort((a, b) => a.at - b.at);
                const t = due[0];
                t.done = true;
                if (t.at > clock) clock = t.at;
                await t.fn();
            }
            if (clock < until) clock = until;
            await settle();
        };
        page.opened = (i) => openCompose(page.posts[i].o.body, D);
        page.answer = (i, obj) => {
            const cid = page.opened(i).cid;
            page.feed.set(cid, (page.feed.get(cid) || []).concat([{ message: sealDown(D, cid, Object.assign({ v: 3, ref: cid, ts: clock }, obj)) }]));
            return cid;
        };
        const walk = (e, out) => { out.push(e); e.kids.forEach((k) => walk(k, out)); return out; };
        page.all = (id) => walk(doc.els[id], []);
        page.text = (e) => walk(e, []).map((x) => x._text).join(' ');
        page.rows = () => page.all('bList').filter((e) => e.className === 'row');
        page.row = (t) => page.rows().find((r) => page.text(r).indexOf(t) >= 0);
        page.heads = () => page.all('bList').filter((e) => e.className === 'shead').map((e) => e.getAttribute('data-sec'));
        page.btn = (label) => page.$('cActs').kids.find((b) => b._text === label || b.getAttribute('data-label') === label);
        await waitFor(() => !doc.els.board.hidden || !doc.els.app.hidden || !doc.els.card.hidden);
        return page;
    };

    // the board: asked for at once, drawn from the PC's sealed answer
    const pg = await load('');
    await waitFor(() => pg.posts.length === 1);
    const q0 = pg.opened(0);
    check('the bare page: the board, "chatq on DESKTOP-7", three grey rows while it asks, and one board act posted to the reply topic',
        !pg.$('board').hidden && pg.$('app').hidden && pg.$('card').hidden && pg.$('bHost')._text === 'chatq on DESKTOP-7' && !!q0 && q0.json.act === 'board' &&
        pg.posts[0].url === SERVER + '/' + TOPIC && pg.all('bList').filter((e) => e.className === 'skel').length === 3 && /Asking the PC for your chats/.test(pg.text(pg.$('bList'))));
    const iso = (ms) => new Date(ms).toISOString();
    const board = {
        kind: 'board', host: 'DESKTOP-M15B07E', cap: 'acceptEdits', newMode: 'default', listen: 'always', until: null, compose: true, from: 'overlay', left: 180,
        usage: [{ p: 'Claude', parts: [{ w: '5h', pct: 37, reset: iso(clock + 7200000), limited: false, sev: 'normal' }, { w: 'week', pct: 18, reset: null, limited: false }], asof: iso(clock), stale: false },
            { p: 'Codex', parts: [{ w: 'week', pct: 3, reset: null, limited: false }], asof: iso(clock - 7200000), stale: true }],
        open: [
            { h: 'hwaita', id8: '1a2b3c4d', t: 'Radar viewer', f: 'as_viewer', where: 'vscode', state: 'waiting', what: 'permission (Bash)', prompt: '', new: false, age: iso(clock - 180000), jobs: [] },
            { h: 'hbusya', id8: '2b3c4d5e', t: 'Parser ' + HANGUL + ' rewrite', f: 'parser', where: 'terminal', state: 'busy', what: '', prompt: 'fix the tokenizer', new: true, age: iso(clock - 720000), jobs: [{ h: 'hjobqa', n: 14, s: 'queued', e: 'after #13', k: 'prompt' }] },
            { h: 'hidlea', id8: '3c4d5e6f', t: 'Notify feature', f: 'chatq', where: 'vscode', state: 'idle', what: '', prompt: 'add the board', new: true, age: iso(clock - 120000), jobs: [{ h: 'hjobni', n: 12, s: 'needs-input', e: 'needs you', k: 'prompt' }] }
        ],
        cut: [{ h: 'hcutaa', id8: '4d5e6f70', t: 'Plugin unification', f: 'plugins', where: '', why: 'limit', d: 'cut off - resets 02:10', reset: iso(clock + 3600000), age: iso(clock - 600000), jobs: [] }],
        queue: [{ h: 'hjobqa', n: 14, t: 'Parser ' + HANGUL + ' rewrite', s: 'queued', e: 'after #13', k: 'prompt', p: 'claude', f: 'parser', id8: '2b3c4d5e' },
            { h: 'hjobni', n: 12, t: 'Notify feature', s: 'needs-input', e: 'needs you', k: 'prompt', p: 'claude', f: 'chatq', id8: '3c4d5e6f' }],
        recent: [{ h: 'hrecen', id8: '5e6f7081', t: 'Chat open investigation', f: 'chatq', age: iso(clock - 10800000) }],
        folders: [{ h: 'hfolda', n: 'proj_AS-BW', w: 'd:\\Workspace' }, { h: 'hfoldb', n: 'chatq', w: 'C:\\Tools' }],
        more: 14
    };
    pg.answer(0, board);
    await pg.run(4000);
    const heads = pg.heads().join();
    check('the answer on the down topic, found by its title, opened and drawn: the overlay\'s sections in its order, a row each',
        heads === 'waiting,working,cut,queue,idle,recent' && pg.rows().length === 7 && pg.gets.length >= 1 && pg.gets[0].url.indexOf(SERVER + '/' + DOWN + '/json?poll=1&since=') === 0 &&
        pg.gets[0].url.indexOf('&title=' + q0.cid) > 0, heads + ' / ' + pg.rows().length + ' rows / ' + (pg.gets[0] || {}).url);
    check('the GET sends no header, no cookie, no referrer', pg.gets.every((g) => !g.o.headers && g.o.credentials === 'omit' && g.o.referrerPolicy === 'no-referrer' && g.o.method === 'GET'));
    const busyRow = pg.row('Parser');
    check('a row: the title with its Hangul, where it runs, the newest prompt, its age, its job, the blue new-turn dot',
        !!busyRow && busyRow.getAttribute('data-sec') === 'working' && /Parser .* rewrite/.test(pg.text(busyRow)) && pg.text(busyRow).indexOf(HANGUL) > 0 &&
        /parser \u00b7 terminal/.test(pg.text(busyRow)) && /"fix the tokenizer"/.test(pg.text(busyRow)) && /12m/.test(pg.text(busyRow)) && /#14 sends after #13/.test(pg.text(busyRow)) &&
        pg.all('bList').some((e) => e.className === 'nd'), pg.text(busyRow || { kids: [], _text: '' }));
    check('usage: a line per window, a bar each, the stale one "as of"', pg.$('bUsage').hidden === false && pg.all('bUsage').filter((e) => e.tagName === 'PROGRESS').length === 3 &&
        /as of \d\d:\d\d/.test(pg.text(pg.$('bUsage'))) && /^Claude/.test(pg.$('bUsage').kids[0]._text));
    check('the footer: + New chat, listens all the time, Status; "+14 older chats"', !pg.$('bNew').hidden && pg.$('bListen')._text === 'Listens all the time' &&
        /\+14 older chats are not listed\./.test(pg.text(pg.$('bList'))) && pg.$('bNote').hidden);
    pg.$('bSearch').value = 'plugin';
    pg.$('bSearch').fire('input');
    const afterSearch = pg.rows().length;
    pg.$('bSearch').value = 'nothing like it';
    pg.$('bSearch').fire('input');
    const none = pg.text(pg.$('bList'));
    pg.$('bSearch').value = '';
    pg.$('bSearch').fire('input');
    check('search as you type: one row for "plugin", and "No chat matches" for nothing', afterSearch === 1 && /No chat matches "nothing like it"\./.test(none) && pg.rows().length === 7);

    // a tap: the chat view, and each act sealed with the row's own handle
    busyRow.fire('click');
    check('a tap: the chat view - its title, folder, where it runs, the cap, what a message waits on, the newest prompt, its acts',
        !pg.$('chat').hidden && pg.$('board').hidden && pg.$('cTitle')._text === 'Parser ' + HANGUL + ' rewrite' && /parser \u00b7 claude \u00b7 terminal/.test(pg.$('cMeta')._text) &&
        pg.$('cMode')._text === 'at most acceptEdits' && /^working now - .*#14 is queued - sends after #13$/.test(pg.$('cState')._text) && pg.$('cPrompt')._text === 'fix the tokenizer' &&
        pg.$('cActs').kids.map((b) => b.getAttribute('data-act')).join() === 'now,skip,read' && !pg.$('cCompose').hidden, pg.$('cState')._text + ' / ' + pg.$('cActs').kids.map((b) => b._text).join('|'));
    const n0 = pg.posts.length;
    pg.btn('Send now').fire('click');
    await waitFor(() => pg.posts.length === n0 + 1);
    const nowMsg = pg.opened(n0);
    check('Send now: the act now, the job\'s handle and number', !!nowMsg && nowMsg.json.act === 'now' && nowMsg.json.h === 'hjobqa' && nowMsg.json.n === 14 && /Sent - waiting for the PC/.test(pg.$('cStatusText')._text));
    pg.answer(n0, { kind: 'ack', act: 'now', ok: true, say: '#14 goes next' });
    await pg.run(4000);
    check('its ack: said, in green', pg.$('cStatus').getAttribute('data-kind') === 'ok' && pg.$('cStatusText')._text === '#14 goes next');
    const skip = pg.btn('Skip #14');
    skip.fire('click');
    const armed = skip._text;
    clock += 600;
    skip.fire('click');
    await waitFor(() => pg.posts.length === n0 + 2);
    check('Skip: the first tap only asks, a second one sends skip for that job', armed === 'Tap again to skip' && pg.opened(n0 + 1).json.act === 'skip' && pg.opened(n0 + 1).json.h === 'hjobqa');
    pg.answer(n0 + 1, { kind: 'ack', act: 'skip', ok: true, say: '#14 skipped' });
    await pg.run(4000);
    pg.$('cText').value = 'yes, commit it ' + HANGUL;
    pg.$('cText').fire('input');
    check('the box counts bytes as the alert form does, and keeps a draft for this chat', /bytes$/.test(pg.$('cCount')._text) && !pg.$('cSend').disabled &&
        store.get('chatq-cdraft:claude:2b3c4d5e') === 'yes, commit it ' + HANGUL);
    pg.$('cSend').fire('click');
    await waitFor(() => pg.posts.length === n0 + 3);
    const sendMsg = pg.opened(n0 + 2);
    check('Send: the act send, the chat\'s handle, the first 8 of its id, the text', sendMsg.json.act === 'send' && sendMsg.json.h === 'hbusya' && sendMsg.json.id === '2b3c4d5e' &&
        sendMsg.json.text === 'yes, commit it ' + HANGUL && Object.keys(sendMsg.json).join() === 'v,act,h,id,text,nonce,ts');
    await pg.run(50000);
    check('no ack in 45 s: said, and Try again offered - the draft kept', /Sent, but no answer yet/.test(pg.$('cStatusText')._text) && !pg.$('cAgain').hidden &&
        store.get('chatq-cdraft:claude:2b3c4d5e') === 'yes, commit it ' + HANGUL && pg.$('cSend')._text === 'Try again',
        pg.$('cStatusText')._text + ' | again hidden ' + pg.$('cAgain').hidden + ' | ' + pg.$('cSend')._text + ' | ' + store.get('chatq-cdraft:claude:2b3c4d5e'));
    pg.$('cAgain').fire('click');
    await waitFor(() => pg.posts.length === n0 + 4);
    check('Try again posts the very same message, so the PC drops a copy', pg.posts[n0 + 3].o.body === pg.posts[n0 + 2].o.body);
    pg.answer(n0 + 3, { kind: 'ack', act: 'send', ok: false, say: 'that chat moved on at the PC - the list is out of date, refresh it' });
    await pg.run(4000);
    await waitFor(() => pg.posts.length === n0 + 5);
    check('an ack "out of date": back to the board, asked for afresh, the refusal said there - the draft kept for the chat', !pg.$('board').hidden && pg.$('chat').hidden &&
        pg.opened(n0 + 4).json.act === 'board' && /that chat moved on at the PC - the list is out of date, refresh it\./.test(pg.$('bNote')._text) &&
        store.get('chatq-cdraft:claude:2b3c4d5e') === 'yes, commit it ' + HANGUL, pg.$('bNote')._text + ' / board hidden ' + pg.$('board').hidden);
    pg.answer(n0 + 4, board);
    await pg.run(4000);
    check('the new board keeps saying it until a chat is opened', /moved on at the PC/.test(pg.$('bNote')._text), pg.$('bNote')._text);
    pg.row('Parser').fire('click');
    check('the chat opened again, as the new board has it: the text back from its draft', !pg.$('chat').hidden && pg.$('cText').value === 'yes, commit it ' + HANGUL &&
        pg.$('cStatus').hidden, pg.$('cText').value);
    pg.btn('Read the last answer').fire('click');
    await waitFor(() => pg.posts.length === n0 + 6);
    const readMsg = pg.opened(n0 + 5);
    pg.answer(n0 + 5, { kind: 'reply', event: '', title: 'Parser', at: iso(clock), cut: 1234, parts: [{ t: 'text', s: 'Done. Run `npm test`:\n```\nok 12\n```' }, { t: 'tool', s: 'Bash npm test' }] });
    await pg.run(4000);
    const panel = pg.all('cAnswer');
    check('Read the last answer: act read with the chat\'s handle, and the turn drawn - code, a fence, the tool, what was cut', readMsg.json.act === 'read' && readMsg.json.h === 'hbusya' &&
        !pg.$('cAnswer').hidden && pg.$('cAnswer').getAttribute('data-state') === 'shown' && panel.some((e) => e.tagName === 'PRE') && panel.some((e) => e.tagName === 'CODE' && e._text === 'npm test') &&
        panel.some((e) => e.className === 'tool' && /Bash npm test/.test(e._text)) && /The first 1,234 characters are left out\./.test(pg.text(pg.$('cAnswer'))), pg.text(pg.$('cAnswer')));

    // back, the refresh budget, a hidden page
    pg.$('cBack').fire('click');
    check('back: the board again', !pg.$('board').hidden && pg.$('chat').hidden);
    let p0 = pg.posts.length;
    await pg.run(31000);
    const refreshed = pg.posts.length > p0 && pg.opened(pg.posts.length - 1).json.act === 'board';
    pg.answer(pg.posts.length - 1, board);
    await pg.run(4000);
    check('in view, the board asks again every 30 s', refreshed);
    pg.doc.visibilityState = 'hidden';
    p0 = pg.posts.length;
    await pg.run(31000);
    const whileHidden = pg.posts.length - p0;
    pg.doc.visibilityState = 'visible';
    (pg.doc.on.visibilitychange || []).forEach((fn) => fn());
    await waitFor(() => pg.posts.length > p0);
    check('hidden, it asks nothing; seen again, it asks at once', whileHidden === 0 && pg.posts.length === p0 + 1);
    pg.answer(pg.posts.length - 1, board);
    await pg.run(4000);
    clock += 11 * 60000;
    p0 = pg.posts.length;
    await pg.run(31000);
    check('after 10 minutes it stops, and says Paused - tap Refresh', pg.posts.length === p0 && /Paused - tap Refresh\./.test(pg.$('bNote')._text));
    pg.$('bRefresh').fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    check('Refresh asks again, and the budget starts over', pg.opened(p0).json.act === 'board');
    pg.answer(p0, Object.assign({}, board, { left: 12, from: 'scan' }));
    await pg.run(4000);
    check('the board\'s notices: from a scan, and few refreshes left today', /overlay is not running/.test(pg.$('bNote')._text) && /Few refreshes left today/.test(pg.$('bNote')._text));

    // Older chats: the PC's list, asked for once, drawn under the board's
    const olderBtn = pg.all('bList').find((e) => e.id === 'bOlder');
    p0 = pg.posts.length;
    olderBtn.fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    const lq = pg.opened(p0);
    const listAnswer = { kind: 'list', host: 'DESKTOP-M15B07E', cap: 'acceptEdits', compose: true, more: 40, folders: [],
        chats: [{ h: 'hlista', id: '2b3c4d5e', p: 'claude', t: 'Parser (the board has it)', f: 'parser', m: 'acceptEdits', mc: true, known: true, a: iso(clock), live: 'busy', q: 1, ni: 0 },
            { h: 'hlistb', id: '7a8b9c0d', p: 'codex', t: 'Codex thread', f: 'svc', w: 'D:\\src', m: 'workspace-write', mc: true, known: true, a: iso(clock - 3 * 86400000), live: '', q: 0, ni: 0 },
            { h: 'hlistc', id: '8b9c0d1e', p: 'claude', t: 'Old chat ' + HANGUL, f: 'docs', m: 'default', mc: false, known: true, a: iso(clock - 5 * 86400000), live: '', q: 0, ni: 0 }] };
    pg.answer(p0, listAnswer);
    await pg.run(4000);
    const olderRowsDrawn = pg.rows().filter((r) => r.getAttribute('data-sec') === 'older');
    check('Older chats: one list act; its chats the board does not show drawn under the board\'s, "+40 older chats"', lq.json.act === 'list' &&
        pg.heads().slice(-1)[0] === 'older' && olderRowsDrawn.length === 2 && /\+40 older chats are not listed\./.test(pg.text(pg.$('bList'))) &&
        !pg.all('bList').some((e) => e.id === 'bOlder'), pg.heads().join() + ' / ' + olderRowsDrawn.length);
    pg.row('Codex thread').fire('click');
    check('an older Codex chat: its folder and provider, its own mode brought down, no last answer to read, the box',
        pg.$('cTitle')._text === 'Codex thread' && pg.$('cMeta')._text === 'svc \u00b7 codex' && pg.$('cMode')._text === 'workspace-write (phone\'s limit)' &&
        pg.$('cActs').hidden && !pg.$('cCompose').hidden && pg.$('cState')._text === 'a message goes next', pg.$('cMeta')._text + ' / ' + pg.$('cMode')._text);
    pg.$('cText').value = 'rerun the tests';
    pg.$('cText').fire('input');
    p0 = pg.posts.length;
    pg.$('cSend').fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    const ls = pg.opened(p0);
    check('Send to it: the act send with the list\'s handle and the first 8 of its id; its draft kept under codex', ls.json.act === 'send' && ls.json.h === 'hlistb' &&
        ls.json.id === '7a8b9c0d' && ls.json.text === 'rerun the tests' && store.get('chatq-cdraft:codex:7a8b9c0d') === 'rerun the tests');
    pg.answer(p0, { kind: 'ack', act: 'send', ok: true, say: 'queued #16 for Codex thread' });
    await pg.run(4000);
    pg.$('cBack').fire('click');
    await pg.run(4000);
    if (pg.posts.length > p0 + 1) { pg.answer(pg.posts.length - 1, board); await pg.run(4000); }
    // an older chat that moved on: its handle comes only from the list, so the
    // list is asked for again with the board - a board alone would leave it
    pg.row('Old chat').fire('click');
    pg.$('cText').value = 'and the docs';
    pg.$('cText').fire('input');
    p0 = pg.posts.length;
    pg.$('cSend').fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    pg.answer(p0, { kind: 'ack', act: 'send', ok: false, say: 'that chat moved on at the PC - the list is out of date, refresh it' });
    await pg.run(4000);
    await waitFor(() => pg.posts.length === p0 + 3);
    const reAsked = [pg.opened(p0 + 1).json.act, pg.opened(p0 + 2).json.act].sort().join();
    check('an older chat moved on: back to the board, and the older chats asked for again with it, the draft kept', !pg.$('board').hidden && reAsked === 'board,list' &&
        store.get('chatq-cdraft:claude:8b9c0d1e') === 'and the docs', reAsked);
    const listAgain = Object.assign({}, listAnswer, { chats: listAnswer.chats.map((c) => Object.assign({}, c, c.id === '8b9c0d1e' ? { h: 'hlistx' } : {})) });
    for (const i of [p0 + 1, p0 + 2]) pg.answer(i, pg.opened(i).json.act === 'list' ? listAgain : board);
    await pg.run(4000);
    pg.row('Old chat').fire('click');
    check('opened again from the list asked for afresh: its draft back', pg.$('cText').value === 'and the docs', pg.$('cText').value);
    p0 = pg.posts.length;
    pg.$('cSend').fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    check('and its send goes with the list\'s fresh handle', pg.opened(p0).json.h === 'hlistx', pg.opened(p0).json.h);
    // left before the answer came: it lands in no other chat's view
    pg.$('cBack').fire('click');
    pg.row('Codex thread').fire('click');
    pg.$('cText').value = 'for the codex one';
    pg.$('cText').fire('input');
    pg.answer(p0, { kind: 'ack', act: 'send', ok: true, say: 'queued #17 for Old chat' });
    await pg.run(4000);
    check('an answer to a view left since changes nothing in the one opened after it: its text, its draft, its status', pg.$('cTitle')._text === 'Codex thread' &&
        pg.$('cText').value === 'for the codex one' && store.get('chatq-cdraft:codex:7a8b9c0d') === 'for the codex one' && pg.$('cStatus').hidden,
        pg.$('cText').value + ' / ' + pg.$('cStatusText')._text);
    pg.$('cText').value = '';
    pg.$('cText').fire('input');
    pg.$('cBack').fire('click');
    await pg.run(4000);
    if (pg.posts.length > p0 + 1) { pg.answer(pg.posts.length - 1, board); await pg.run(4000); }

    // + New chat: the folders, then the new chat's view
    pg.$('bNew').fire('click');
    const folders = pg.all('cList').filter((e) => e.className === 'row');
    check('+ New chat: the folders chatq knows, as rows', !pg.$('chat').hidden && folders.length === 2 && pg.$('cTitle')._text === 'New chat' && pg.$('cCompose').hidden);
    folders[0].fire('click');
    check('a folder: "New chat in proj_AS-BW", a name, the mode it runs in', pg.$('cTitle')._text === 'New chat in proj_AS-BW' && !pg.$('cName').hidden &&
        pg.$('cMode')._text === 'default - anything that would ask is denied' && !pg.$('cCompose').hidden);
    pg.$('cName').value = 'Docs pass';
    pg.$('cText').value = 'write the docs';
    pg.$('cText').fire('input');
    p0 = pg.posts.length;
    pg.$('cSend').fire('click');
    await waitFor(() => pg.posts.length === p0 + 1);
    const nw = pg.opened(p0);
    check('Send: the act new with the folder\'s handle, the name and the text', nw.json.act === 'new' && nw.json.h === 'hfolda' && nw.json.name === 'Docs pass' && nw.json.text === 'write the docs');
    pg.answer(p0, { kind: 'ack', act: 'new', ok: true, say: 'new chat "Docs pass" queued as #15 in proj_AS-BW - runs in default' });
    await pg.run(4000);
    check('an ack ok: the draft cleared', pg.$('cStatus').getAttribute('data-kind') === 'ok' && !store.has('chatq-cdraft:new:proj_AS-BW') && pg.$('cText').value === '');

    // nobody listening: the card, after 45 s
    const quiet = await load('');
    await waitFor(() => quiet.posts.length === 1);
    await quiet.run(50000);
    const card = quiet.all('bList').find((e) => e.getAttribute && e.getAttribute('data-kind') === 'nolisten');
    check('no answer in 45 s: "No answer from the PC", how to have it listen, the older-PC line, the phone\'s code, Try again', !!card && /No answer from the PC/.test(quiet.text(card)) &&
        /chatnotify -Listen always/.test(quiet.text(card)) && /older than 0\.9\.0/.test(quiet.text(card)) && quiet.text(card).indexOf(code.slice(0, 3) + ' ' + code.slice(3)) >= 0);

    // a waiting chat's question on the board (docs/phone-ask-spec.md) - before
    // any alert's page, which the bare page would go back to
    const askObj = { k: 'toolu_askone', at: iso(clock), more: 0, cut: false, q: [
        { h: 'Stability log', t: 'Which way? ' + HANGUL, m: false, o: [{ l: 'Integrate (recommended)', d: 'One rolling file' }, { l: 'Just delete it', d: 'Less code' }] },
        { h: 'Reach', t: 'Where are the gateways?', m: true, o: [{ l: 'Bench', d: '' }, { l: 'Site fleet', d: 'behind the relay' }] }] };
    const qBoard = await load('');
    await waitFor(() => qBoard.posts.length === 1);
    const qbWait = Object.assign({}, board.open[0], { what: '2 questions: Stability log, Reach', ask: askObj });
    qBoard.answer(0, Object.assign({}, board, { open: [qbWait, board.open[1]] }));
    await qBoard.run(4000);
    const qRow = qBoard.row('Radar');
    check('the board: the waiting row says what it asks', !!qRow && /2 questions: Stability log, Reach/.test(qBoard.text(qRow)), qRow ? qBoard.text(qRow) : 'no row');
    qRow.fire('click');
    check('its chat view: the question drawn, every option with its description', !qBoard.$('cAsk').hidden && /Site fleet/.test(qBoard.text(qBoard.$('cAsk'))) &&
        /behind the relay/.test(qBoard.text(qBoard.$('cAsk'))) && /Answer it at the PC\./.test(qBoard.text(qBoard.$('cAsk'))));
    qBoard.$('cBack').fire('click');
    qBoard.row('Parser').fire('click');
    check('another chat\'s view: no question left over from the last', qBoard.$('cAsk').hidden);

    // Part B: the question answered from the board's chat view - act answer
    // on the compose wire, its ack in the chat's status line
    const RID = 'mnopqrstuv', QH = 'QUJDREVGR0hJSktMTU5PUA';
    const askCan = (x) => Object.assign({}, askObj, { can: true, rid: RID, qh: QH, until: iso(clock + 3600000) }, x);
    const aBoard = await load('');
    await waitFor(() => aBoard.posts.length === 1);
    const soonRow = Object.assign({}, board.open[0], { h: 'hsoona', id8: '6a6b6c6d', t: 'Soon over', ask: askCan({ rid: 'soonsoonso', until: iso(clock + 90000) }) });
    const lateRow = Object.assign({}, board.open[0], { h: 'hlatea', id8: '7a7b7c7d', t: 'Late one', ask: askCan({ rid: 'latelatela', until: iso(clock - 60000) }) });
    const hookRow = Object.assign({}, board.open[0], { h: 'hhooka', id8: '8a8b8c8d', t: 'Hookless', ask: Object.assign({}, askObj, { can: false, why: 'hook' }) });
    const aBoardAnswer = Object.assign({}, board, { open: [Object.assign({}, board.open[0], { ask: askCan() }), soonRow, lateRow, hookRow, board.open[1]] });
    aBoard.answer(0, aBoardAnswer);
    await aBoard.run(4000);
    const inputs = (pg, id, type) => pg.all(id).filter((e) => e.tagName === 'INPUT' && (!type || e.type === type));
    const sendOf = (pg, id) => pg.all(id).find((e) => e.tagName === 'BUTTON' && e.getAttribute('data-act') === 'answer');
    const pick = (e, on) => { e.checked = on !== false; e.fire('change'); };
    const type = (e, v) => { e.value = v; e.fire('input'); };
    // until passes while the card is shown: read-only on the minute's tick
    aBoard.row('Soon over').fire('click');
    const soonHad = !!sendOf(aBoard, 'cAsk');
    await aBoard.run(125000);
    check('an answerable card whose until passes while shown: on the one-minute tick, read-only with the late words, no Send',
        soonHad && !sendOf(aBoard, 'cAsk') && inputs(aBoard, 'cAsk').length === 0 && /the phone could answer until \d\d:\d\d\./.test(aBoard.text(aBoard.$('cAsk'))), aBoard.text(aBoard.$('cAsk')));
    let n1 = aBoard.posts.length;
    aBoard.$('cBack').fire('click');
    await waitFor(() => aBoard.posts.length === n1 + 1);
    aBoard.answer(n1, Object.assign({}, aBoardAnswer, { open: [Object.assign({}, board.open[0], { ask: askCan() }), lateRow, hookRow, board.open[1]] }));
    await aBoard.run(4000);
    aBoard.row('Late one').fire('click');
    check('a card already past until: no controls, no Send, the late words', !aBoard.$('cAsk').hidden && !sendOf(aBoard, 'cAsk') && inputs(aBoard, 'cAsk').length === 0 &&
        /Answer it at the PC - the phone could answer until \d\d:\d\d\./.test(aBoard.text(aBoard.$('cAsk'))));
    aBoard.$('cBack').fire('click');
    aBoard.row('Hookless').fire('click');
    check('can false: the Part A card, its why in place of the footer', !sendOf(aBoard, 'cAsk') && /no chatq hook holds this question/.test(aBoard.text(aBoard.$('cAsk'))) &&
        !/Answer it at the PC\.$/.test(aBoard.text(aBoard.$('cAsk'))));
    aBoard.$('cBack').fire('click');
    aBoard.row('Radar').fire('click');
    const radios = inputs(aBoard, 'cAsk', 'radio'), boxes = inputs(aBoard, 'cAsk', 'checkbox'), texts = inputs(aBoard, 'cAsk', 'text');
    const aSend = sendOf(aBoard, 'cAsk');
    check('answerable in the chat view: a radio group and Other for the single choice, checkboxes and Other for the multiple, Send answer off, the footer with the time',
        radios.length === 3 && boxes.length === 3 && texts.length === 2 && radios[0].name === radios[2].name && radios[0].name !== boxes[0].name && !!aSend && aSend.disabled &&
        aSend._text === 'Send answer' && /The PC's dialog stays open too - the first answer wins\. Until \d\d:\d\d\./.test(aBoard.text(aBoard.$('cAsk'))) &&
        /behind the relay/.test(aBoard.text(aBoard.$('cAsk'))), radios.length + '/' + boxes.length + '/' + texts.length);
    pick(radios[0]);
    const offOne = aSend.disabled;
    pick(boxes[1]);
    type(texts[1], 'free text ' + HANGUL);
    check('Send answer off until every question has an answer; typing in Other chooses it', offOne && !aSend.disabled && boxes[2].checked === true && radios[0].checked === true &&
        !radios[1].checked);
    const adraft = store.get('chatq-adraft:' + RID);
    check('the draft, per rid: the choices and the Other texts only', adraft === JSON.stringify({ pick: [[0], [1]], other: [false, true], text: ['', 'free text ' + HANGUL] }), adraft);
    aBoard.$('cBack').fire('click');
    aBoard.row('Radar').fire('click');
    const r2 = inputs(aBoard, 'cAsk', 'radio'), b2 = inputs(aBoard, 'cAsk', 'checkbox'), t2 = inputs(aBoard, 'cAsk', 'text');
    check('drawn again: the draft restored - the choices checked, the Other text back, Send on', r2[0].checked && b2[1].checked && b2[2].checked && !b2[0].checked &&
        t2[1].value === 'free text ' + HANGUL && !sendOf(aBoard, 'cAsk').disabled);
    const bSend = sendOf(aBoard, 'cAsk');
    n1 = aBoard.posts.length;
    bSend.fire('click');
    const askedB = bSend._text;
    clock += 120;
    bSend.fire('click');
    await new Promise((r) => realSetTimeout(r, 30));
    const earlyB = aBoard.posts.length;
    clock += 500;
    bSend.fire('click');
    await waitFor(() => aBoard.posts.length === n1 + 1);
    const ansB = aBoard.opened(n1);
    check('Send answer: the first tap asks, a second within 500 ms does nothing, one past it sends', askedB === 'Tap again to send' && earlyB === n1 && !!ansB);
    check('the answer on the compose wire: act answer, the row\'s handle and id, rid, qh, a and o as chosen - in the watcher\'s key order, no label',
        !!ansB && ansB.json.act === 'answer' && ansB.json.h === 'hwaita' && ansB.json.id === '1a2b3c4d' && ansB.json.rid === RID && ansB.json.qh === QH &&
        JSON.stringify(ansB.json.a) === '[[0],[1]]' && JSON.stringify(ansB.json.o) === JSON.stringify(['', 'free text ' + HANGUL]) &&
        Object.keys(ansB.json).join() === 'v,act,h,id,rid,qh,a,o,nonce,ts' && ansB.text.indexOf('Site fleet') < 0, ansB && ansB.text);
    aBoard.answer(n1, { kind: 'ack', act: 'answer', ok: false, say: 'that chat moved on at the PC - the list is out of date, refresh it' });
    await aBoard.run(4000);
    await waitFor(() => aBoard.posts.length === n1 + 2);
    check('an ack "out of date": back to the board, asked for afresh, the refusal said there - the draft kept', !aBoard.$('board').hidden && aBoard.opened(n1 + 1).json.act === 'board' &&
        /out of date/.test(aBoard.$('bNote')._text) && store.get('chatq-adraft:' + RID) === adraft);
    aBoard.answer(n1 + 1, aBoardAnswer);
    await aBoard.run(4000);
    aBoard.row('Radar').fire('click');
    const cSendA = sendOf(aBoard, 'cAsk');
    n1 = aBoard.posts.length;
    cSendA.fire('click');
    clock += 600;
    cSendA.fire('click');
    await waitFor(() => aBoard.posts.length === n1 + 1 && /Sent - waiting/.test(aBoard.$('cStatusText')._text));
    check('sent again from the restored draft: the same answer', JSON.stringify(aBoard.opened(n1).json.a) === '[[0],[1]]' && /Sent - waiting for the PC/.test(aBoard.$('cStatusText')._text));
    aBoard.answer(n1, { kind: 'ack', act: 'answer', ok: true, say: 'sent your answer to Radar viewer - it goes on, unless it was answered at the PC first' });
    await aBoard.run(4000);
    const doneSend = sendOf(aBoard, 'cAsk');
    check('its ack ok: said in the chat\'s status line, in green; the draft gone; Send says Sent and stays off', aBoard.$('cStatus').getAttribute('data-kind') === 'ok' &&
        aBoard.$('cStatusText')._text === 'sent your answer to Radar viewer - it goes on, unless it was answered at the PC first' && !store.has('chatq-adraft:' + RID) &&
        !!doneSend && doneSend._text === 'Sent' && doneSend.disabled && inputs(aBoard, 'cAsk').every((e) => e.disabled), aBoard.$('cStatusText')._text);
    // the chat view's own read leaves the row's question where it is
    n1 = aBoard.posts.length;
    aBoard.btn('Read the last answer').fire('click');
    await waitFor(() => aBoard.posts.length === n1 + 1);
    aBoard.answer(n1, { kind: 'reply', event: '', title: 'Radar viewer', at: iso(clock), cut: 0, parts: [{ t: 'text', s: 'Which way do you want it?' }] });
    await aBoard.run(4000);
    check('Read the last answer in the chat view: a reply with no question leaves the row\'s card up', !aBoard.$('cAsk').hidden && !!sendOf(aBoard, 'cAsk') &&
        aBoard.$('cAnswer').getAttribute('data-state') === 'shown');

    // an alert's page: the whole answer above the box
    const aid = 'abcdefgh23';
    const alert = await load('#v=2&a=' + aid + '&e=done&n=3&c=Parser&p=claude&j=done&f=1&o=' + Math.floor(clock / 1000));
    alert.feed.set(aid, [{ message: sealDown(D, aid, { v: 3, kind: 'reply', ref: aid, ts: clock, event: 'done', title: 'Parser', at: iso(clock), cut: 0, parts: [{ t: 'text', s: '# Result\nAll **green**.' }, { t: 'tool', s: 'a' }, { t: 'tool', s: 'b' }, { t: 'tool', s: 'c' }] }) }]);
    await alert.run(100);
    const ap = alert.all('answer');
    check('f=1: the whole answer looked for at once and shown above the box - the heading, bold, three tools folded', !alert.$('app').hidden && alert.$('answer').getAttribute('data-state') === 'shown' &&
        ap.some((e) => e.className === 'ah' && e._text === 'Result') && ap.some((e) => e.tagName === 'STRONG' && e._text === 'green') && ap.some((e) => e.className === 'tools' && /3 tools/.test(e._text)) &&
        /Claude's answer - \d\d:\d\d/.test(alert.text(alert.$('answer'))) && alert.gets[0].url.indexOf('since=' + (Math.floor(clock / 1000) - 120)) > 0, alert.text(alert.$('answer')));
    const copy = ap.find((e) => e._text === 'Copy');
    copy.fire('click');
    check('Copy with no clipboard here: says so', /Copy is blocked here/.test(alert.text(alert.$('answer'))));
    // an attachment, and one gone
    const aid2 = 'bcdefgh234';
    const big = await load('#v=2&a=' + aid2 + '&e=needs%20input&n=4&c=x&p=claude&j=needs-input&f=1&o=' + Math.floor(clock / 1000));
    big.files.set('/file/zz.txt', sealDown(D, aid2, { v: 3, kind: 'reply', ref: aid2, ts: clock, event: 'needs input', title: 'x', at: iso(clock), cut: 0, parts: [{ t: 'text', s: 'from the file' }] }));
    big.feed.set(aid2, [{ message: 'chatq', attachment: { name: aid2 + '.txt', url: SERVER + '/file/zz.txt', size: 5000, expires: Math.floor(clock / 1000) + 3600 } }]);
    await big.run(100);
    check('a long answer as an attachment: fetched from the server\'s /file/, and shown', big.$('answer').getAttribute('data-state') === 'shown' && /from the file/.test(big.text(big.$('answer'))) &&
        big.gets.some((g) => g.url === SERVER + '/file/zz.txt'));
    const aid3 = 'cdefgh2345';
    const gone = await load('#v=2&a=' + aid3 + '&e=done&n=5&c=x&p=claude&j=done&f=1&o=' + Math.floor(clock / 1000));
    gone.feed.set(aid3, [{ message: 'chatq', attachment: { name: 'x.txt', url: SERVER + '/file/gone.txt', size: 5000, expires: Math.floor(clock / 1000) - 10 } }]);
    await gone.run(35000);
    check('an attachment past its 3 hours: said, and Ask the PC for it', gone.$('answer').getAttribute('data-state') === 'gone' && /that one is gone/.test(gone.text(gone.$('answer'))));
    const ask = gone.all('answer').find((e) => e._text === 'Ask the PC for it');
    ask.fire('click');
    await waitFor(() => gone.posts.length === 1);
    const readA = openAlert(gone.posts[0].o.body, D);
    check('Ask the PC for it: the alert act read, sealed for that alert, and it waits', !!readA && readA.aid === aid3 && readA.json.act === 'read' && readA.json.text === '' &&
        gone.$('answer').getAttribute('data-state') === 'asked');
    await gone.run(65000);
    check('no answer to the ask in a minute: said, and it can be asked again', gone.$('answer').getAttribute('data-state') === 'noanswer' && /The PC may be asleep/.test(gone.text(gone.$('answer'))));
    const nof = await load('#v=2&a=defgh23456&e=failed&n=6&c=x&p=claude&j=failed');
    check('no f=1: nothing looked for, "The whole answer is not here." and the button', nof.gets.length === 0 && nof.$('answer').getAttribute('data-state') === 'none' &&
        nof.all('answer').some((e) => e._text === 'Ask the PC for it'));
    const started = await load('#v=2&a=efgh234567&e=started&n=7&c=x&p=claude&j=running&f=1');
    check('a started alert, or one about no chat: no answer panel', started.$('answer').hidden && (await load('#v=2&a=fgh2345678&e=done&x=1')).$('answer').hidden);

    // the question on a live needs input alert's page
    const qa = 'ghjk234567';
    const qAlone = await load('#v=2&a=' + qa + '&e=needs%20input&n=0&c=Feed&p=claude&j=live&f=1&o=' + Math.floor(clock / 1000));
    qAlone.feed.set(qa, [{ message: sealDown(D, qa, { v: 3, kind: 'reply', ref: qa, ts: clock, event: 'needs input', title: 'Feed', at: null, cut: 0, parts: [], ask: askObj }) }]);
    await qAlone.run(100);
    const qText = qAlone.text(qAlone.$('ask'));
    check('a needs input alert with the question alone (whole answers off): the question drawn above the box - both, the options with their descriptions, answered at the PC - and no empty answer panel',
        !qAlone.$('ask').hidden && qAlone.$('answer').hidden && /Claude asks 2 questions/.test(qText) && /1 of 2/.test(qText) && /Stability log/.test(qText) && qText.indexOf(HANGUL) >= 0 &&
        /Integrate \(recommended\)/.test(qText) && /One rolling file/.test(qText) && /choose any/.test(qText) && /Answer it at the PC\./.test(qText) &&
        qAlone.all('ask').filter((e) => e.tagName === 'LI').length === 4, qText);
    const qb = 'hjkm234567';
    const qBoth = await load('#v=2&a=' + qb + '&e=needs%20input&n=0&c=Feed&p=claude&j=live&f=1&o=' + Math.floor(clock / 1000));
    qBoth.feed.set(qb, [{ message: sealDown(D, qb, { v: 3, kind: 'reply', ref: qb, ts: clock, event: 'needs input', title: 'Feed', at: iso(clock), cut: 0, parts: [{ t: 'text', s: 'Before I go on:' }], ask: askObj }) }]);
    await qBoth.run(100);
    check('with the whole answer too: both, the question first', !qBoth.$('ask').hidden && qBoth.$('answer').getAttribute('data-state') === 'shown' && /Before I go on/.test(qBoth.text(qBoth.$('answer'))));

    // Part B on a needs input alert's page: act answer on the alert wire,
    // sealed with the alert's key, the page's status and log below
    const qc = 'jkmn234567', ARID = 'pqrstuvwxy';
    const aAlert = await load('#v=2&a=' + qc + '&e=needs%20input&n=0&c=Feed&p=claude&j=live&f=1&o=' + Math.floor(clock / 1000));
    aAlert.feed.set(qc, [{ message: sealDown(D, qc, { v: 3, kind: 'reply', ref: qc, ts: clock, event: 'needs input', title: 'Feed', at: null, cut: 0, parts: [], ask: askCan({ rid: ARID }) }) }]);
    await aAlert.run(100);
    const ar = inputs(aAlert, 'ask', 'radio'), ab = inputs(aAlert, 'ask', 'checkbox'), at = inputs(aAlert, 'ask', 'text'), aS = sendOf(aAlert, 'ask');
    check('an answerable question on the alert\'s page: its controls, Send answer off, the prompt box below as it was', !aAlert.$('ask').hidden && ar.length === 3 && ab.length === 3 &&
        !!aS && aS.disabled && !aAlert.$('compose').hidden && aAlert.$('text').placeholder === 'Prompt for after it is answered');
    pick(ar[1]);
    type(at[1], HANGUL.repeat(1000));
    const cnt = aAlert.all('ask').find((e) => /\bacount\b/.test(e.className || ''));
    check('Other text past the payload limit: "N bytes too long", Send answer stays off', !!cnt && !cnt.hidden && /^\d+ bytes too long$/.test(cnt._text) && aS.disabled, cnt && cnt._text);
    type(at[1], 'x');
    pick(ab[0]);
    check('trimmed back and a box ticked: Send answer on, the count gone', !aS.disabled && cnt.hidden && store.get('chatq-adraft:' + ARID) === JSON.stringify({ pick: [[1], [0]], other: [false, true], text: ['', 'x'] }));
    aS.fire('click');
    const armedA = aS._text;
    clock += 600;
    aS.fire('click');
    await waitFor(() => aAlert.posts.length === 1 && aAlert.$('status').getAttribute('data-kind') === 'ok');
    const ansA = aAlert.posts[0] ? openAlert(aAlert.posts[0].o.body, D) : null;
    check('two taps: posted to the paired topic, opened with the alert\'s key - act answer, text empty, rid, qh, a and o as chosen, in the wire\'s key order',
        armedA === 'Tap again to send' && !!ansA && ansA.aid === qc && aAlert.posts[0].url === SERVER + '/' + TOPIC && ansA.json.act === 'answer' && ansA.json.text === '' &&
        ansA.json.rid === ARID && ansA.json.qh === QH && JSON.stringify(ansA.json.a) === '[[1],[0]]' && JSON.stringify(ansA.json.o) === '["","x"]' &&
        Object.keys(ansA.json).join() === 'v,act,text,nonce,ts,rid,qh,a,o', ansA && JSON.stringify(ansA.json));
    check('after it: "Sent - the PC reads it within about 20 s.", the draft gone, Send says Sent and stays off', aAlert.$('statusText')._text === 'Sent - the PC reads it within about 20 s.' &&
        !store.has('chatq-adraft:' + ARID) && aS._text === 'Sent' && aS.disabled && aAlert.$('log').kids.length === 1, aAlert.$('statusText')._text);
    const aLate = await load('#v=2&a=kmnp234567&e=needs%20input&n=0&c=Feed&p=claude&j=live&f=1&o=' + Math.floor(clock / 1000));
    aLate.feed.set('kmnp234567', [{ message: sealDown(D, 'kmnp234567', { v: 3, kind: 'reply', ref: 'kmnp234567', ts: clock, event: 'needs input', title: 'Feed', at: null, cut: 0, parts: [],
        ask: askCan({ rid: 'qrstuvwxyz', until: iso(clock - 1000) }) }) }]);
    await aLate.run(100);
    check('on an alert\'s page past until: no Send, no controls, the late words', !aLate.$('ask').hidden && !sendOf(aLate, 'ask') && inputs(aLate, 'ask').length === 0 &&
        /the phone could answer until/.test(aLate.text(aLate.$('ask'))));

    // Explicit reads on an alert's page (Ask the PC for it): each reply is
    // the PC's word now. The button is kept from the first draw and tapped
    // again, as a slow page might show it, to read the question three times
    const qd = 'mnpq234567', RID_A = 'aaaaabbbbb', RID_B = 'cccccddddd';
    const reads = await load('#v=2&a=' + qd + '&e=needs%20input&n=0&c=Feed&p=claude&j=live');
    const askBtn = reads.all('answer').find((e) => e._text === 'Ask the PC for it');
    const replyWith = (x) => reads.feed.set(qd, [{ message: sealDown(D, qd, Object.assign({ v: 3, kind: 'reply', ref: qd, ts: clock, event: 'needs input', title: 'Feed', at: iso(clock), cut: 0, parts: [] }, x)) }]);
    const readOnce = async () => { const n = reads.posts.length; askBtn.fire('click'); await waitFor(() => reads.posts.length === n + 1); await reads.run(5000); };
    replyWith({ ask: askCan({ rid: RID_A }) });
    await readOnce();
    let rr = inputs(reads, 'ask', 'radio'), rb = inputs(reads, 'ask', 'checkbox'), rt = inputs(reads, 'ask', 'text'), rs = sendOf(reads, 'ask');
    pick(rr[0]);
    type(rt[1], '\u200b');
    const zwOff = rs.disabled;
    type(rt[1], '');
    pick(rb[0]);
    reads.postAnswer = { ok: false, status: 503 };
    rs.fire('click');
    clock += 600;
    rs.fire('click');
    await waitFor(() => reads.$('status').getAttribute('data-kind') === 'bad');
    const failedA = reads.posts[reads.posts.length - 1].o.body;
    check('a zero-width space alone in Other keeps Send answer off; a failed send offers Try again for that question', !!rs && !!askBtn && zwOff &&
        !reads.$('again').hidden && rs._text === 'Try again' && openAlert(failedA, D).json.rid === RID_A, rs && rs._text);
    reads.postAnswer = null;
    // the same questions, now held under another rid: A's sealed message is not B's
    replyWith({ ask: askCan({ rid: RID_B }), parts: [{ t: 'text', s: 'Still waiting.' }] });
    await readOnce();
    rr = inputs(reads, 'ask', 'radio');
    rb = inputs(reads, 'ask', 'checkbox');
    rs = sendOf(reads, 'ask');
    pick(rr[0]);
    pick(rb[0]);
    const offerB = rs._text, againB = reads.$('again').hidden;
    let n2 = reads.posts.length;
    rs.fire('click');
    clock += 600;
    rs.fire('click');
    await waitFor(() => reads.posts.length === n2 + 1 && reads.$('status').getAttribute('data-kind') === 'ok');
    const sentB = openAlert(reads.posts[n2].o.body, D);
    check('a card for another question (rid) drops the failed answer: no Try again, and the same choices go sealed afresh, for the new rid',
        againB && offerB === 'Send answer' && reads.posts[n2].o.body !== failedA && !!sentB && sentB.json.rid === RID_B && JSON.stringify(sentB.json.a) === '[[0],[0]]',
        offerB + ' / ' + (sentB && sentB.json.rid));
    // answered at the PC meanwhile: the reply comes without the question
    replyWith({ parts: [{ t: 'text', s: 'Thanks, going on.' }] });
    await readOnce();
    check('an explicit read whose reply has no question: the old card comes off, the answer shown', reads.$('ask').hidden && !sendOf(reads, 'ask') &&
        reads.$('answer').getAttribute('data-state') === 'shown' && /Thanks, going on/.test(reads.text(reads.$('answer'))));

    // nothing opened or the raw key is ever kept
    const forms = [b64url(D), D.toString('base64'), D.toString('hex')];
    const kept = [...store.values(), ...local.values()];
    check('the tab and the phone keep no form of the raw key, and nothing the PC sent - only the draft\'s own text', kept.every((t) => forms.every((f) => t.indexOf(f) < 0)) &&
        kept.every((t) => t.indexOf('Radar') < 0 && t.indexOf('tokenizer') < 0 && t.indexOf('from the file') < 0), JSON.stringify(kept));
}
