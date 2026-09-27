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
    check('the usage lines: the provider on its first window, the reset when limited, "as of" when stale', JSON.stringify(B.usageLines([{ p: 'Claude', stale: true, asof: '2026-09-26T01:00:00Z', parts: [{ w: '5h', pct: 100, limited: true, reset: '2026-09-26T02:10:00Z' }, { w: 'week', pct: 18 }] }]).map((l) => [l.name, l.w, l.pct, l.tone, !!l.right])) ===
        JSON.stringify([['Claude', '5h', 100, 'bad', true], ['', 'week', 18, 'ok', false]]));
    check('the footer: listens all the time, or until when', B.listenText({ listen: 'always' }) === 'Listens all the time' && /^Listens until \d\d:\d\d \(an alert is out\)$/.test(B.listenText({ listen: 'alerts', until: '2026-09-26T02:10:00Z' })));

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
        const loc = { hash, pathname: '/VS-code-chat-manager/reply.html', search: '' };
        const hist = { replaceState: (s, t, url) => { loc.hash = url.indexOf('#') >= 0 ? url.slice(url.indexOf('#')) : ''; } };
        const win = { crypto: webcrypto, TextEncoder, addEventListener() { } };
        const page = { doc, posts: [], gets: [], feed: new Map(), files: new Map(), timers: [] };
        // the ntfy server: a POST recorded, a GET of the down topic answered
        // with what page.feed holds for that title, a GET of a file with page.files
        const fakeFetch = (url, o) => {
            if (o && o.method === 'POST') { page.posts.push({ url, o }); return Promise.resolve({ ok: true, status: 200 }); }
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
    pg.answer(n0 + 3, { kind: 'ack', act: 'send', ok: false, say: 'that list is out of date - refresh it' });
    await pg.run(4000);
    await waitFor(() => pg.posts.length === n0 + 5);
    check('an ack "that list is out of date": said in red, the board asked for again, the draft kept', pg.$('cStatus').getAttribute('data-kind') === 'bad' &&
        pg.opened(n0 + 4).json.act === 'board' && store.get('chatq-cdraft:claude:2b3c4d5e') === 'yes, commit it ' + HANGUL);
    pg.answer(n0 + 4, board);
    await pg.run(4000);
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
    pg.answer(p0, { kind: 'list', host: 'DESKTOP-M15B07E', cap: 'acceptEdits', compose: true, more: 40, folders: [],
        chats: [{ h: 'hlista', id: '2b3c4d5e', p: 'claude', t: 'Parser (the board has it)', f: 'parser', m: 'acceptEdits', mc: true, known: true, a: iso(clock), live: 'busy', q: 1, ni: 0 },
            { h: 'hlistb', id: '7a8b9c0d', p: 'codex', t: 'Codex thread', f: 'svc', w: 'D:\\src', m: 'workspace-write', mc: true, known: true, a: iso(clock - 3 * 86400000), live: '', q: 0, ni: 0 },
            { h: 'hlistc', id: '8b9c0d1e', p: 'claude', t: 'Old chat ' + HANGUL, f: 'docs', m: 'default', mc: false, known: true, a: iso(clock - 5 * 86400000), live: '', q: 0, ni: 0 }] });
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

    // nothing opened or the raw key is ever kept
    const forms = [b64url(D), D.toString('base64'), D.toString('hex')];
    const kept = [...store.values(), ...local.values()];
    check('the tab and the phone keep no form of the raw key, and nothing the PC sent - only the draft\'s own text', kept.every((t) => forms.every((f) => t.indexOf(f) < 0)) &&
        kept.every((t) => t.indexOf('Radar') < 0 && t.indexOf('tokenizer') < 0 && t.indexOf('from the file') < 0), JSON.stringify(kept));
}
