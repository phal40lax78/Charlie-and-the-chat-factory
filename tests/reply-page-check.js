// Checks docs/reply.html, the page a phone pairs and replies from: lifts its
// crypto block out and holds it to tests/fixtures/reply-vector.json and
// pair-vector.json (made by Node's own crypto, independent of the page and of
// the watcher), opens what it seals with Node's crypto the way the watcher
// does, drives its pure logic - the links it reads, what the phone keeps, the
// buttons each alert gets - and then the whole page against a small fake DOM
// and an in-memory IndexedDB: what it posts, where, what it keeps (a key that
// will not export, never the raw bytes) and what it shows. Last, what the page
// must never do: load anything, or post anything but text/plain. A wrong byte
// anywhere here fails silently on the phone - the watcher drops a message
// whose MAC does not verify, or a pairing it cannot open, and says nothing.
//
//     node tests/reply-page-check.js
//
// The exit code is the number of failed checks.
const fs = require('fs');
const path = require('path');
const nodeCrypto = require('crypto');
const webcrypto = globalThis.crypto || nodeCrypto.webcrypto;
let failed = 0, total = 0;
const check = (name, ok, detail) => {
    total++;
    if (!ok) failed++;
    console.log((ok ? '  ok    ' : '  FAIL  ') + name + (ok || detail === undefined ? '' : '  ' + detail));
};
const root = path.join(__dirname, '..');
const pagePath = path.join(root, 'docs', 'reply.html');
const html = fs.readFileSync(pagePath, 'utf8');
const vectorText = fs.readFileSync(path.join(__dirname, 'fixtures', 'reply-vector.json'), 'utf8');
const vec = JSON.parse(vectorText);
const pairText = fs.readFileSync(path.join(__dirname, 'fixtures', 'pair-vector.json'), 'utf8');
const pv = JSON.parse(pairText);
const HANGUL = String.fromCharCode(0xD55C, 0xAE00);
const ANDROID_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36';

// --- Node's side: what the watcher does with a message ------------------------
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64 = (s) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const hmac = (key, msg) => nodeCrypto.createHmac('sha256', key).update(typeof msg === 'string' ? Buffer.from(msg, 'utf8') : msg).digest();
const alertKeyOf = (d, aid) => hmac(Buffer.from(d), 'chatq-alert:' + aid);
// the confirmation code of a phone key, as the PC works it out
const codeOf = (d) => String(hmac(Buffer.from(d), 'chatq-confirm').readUInt32BE(0) % 1000000).padStart(6, '0');
// verify, then decrypt: null for anything the watcher would drop
const openMessage = (message, k) => {
    const parts = String(message).split('.');
    if (parts.length !== 5 || parts[0] !== 'chatq1' || !/^[a-z2-7]{10}$/.test(parts[1])) return null;
    const want = hmac(hmac(k, 'mac'), parts.slice(0, 4).join('.'));
    const got = unb64(parts[4]);
    if (got.length !== want.length || !nodeCrypto.timingSafeEqual(got, want)) return null;
    try {
        const d = nodeCrypto.createDecipheriv('aes-256-cbc', hmac(k, 'enc'), unb64(parts[2]));
        const text = Buffer.concat([d.update(unb64(parts[3])), d.final()]).toString('utf8');
        return { aid: parts[1], text, json: JSON.parse(text) };
    } catch (e) {
        return null;
    }
};
// the same for a message about no alert, "chatq3c.", under k_phone
const openComposeMessage = (message, k) => {
    const parts = String(message).split('.');
    if (parts.length !== 5 || parts[0] !== 'chatq3c' || !/^[a-z2-7]{10}$/.test(parts[1])) return null;
    const want = hmac(hmac(k, 'mac'), parts.slice(0, 4).join('.'));
    const got = unb64(parts[4]);
    if (got.length !== want.length || !nodeCrypto.timingSafeEqual(got, want)) return null;
    try {
        const d = nodeCrypto.createDecipheriv('aes-256-cbc', hmac(k, 'enc'), unb64(parts[2]));
        const text = Buffer.concat([d.update(unb64(parts[3])), d.final()]).toString('utf8');
        return { cid: parts[1], text, json: JSON.parse(text) };
    } catch (e) {
        return null;
    }
};
// the PC's private key, from the fixture's .NET-shaped fields
const pairKey = (() => {
    try {
        const p = pv.private;
        const u = (s) => b64url(Buffer.from(s, 'base64'));
        return nodeCrypto.createPrivateKey({ format: 'jwk', key: { kty: 'RSA', n: u(p.Modulus), e: u(p.Exponent), d: u(p.D), p: u(p.P), q: u(p.Q), dp: u(p.DP), dq: u(p.DQ), qi: u(p.InverseQ) } });
    } catch (e) {
        return null;
    }
})();
// what the PC does with a pairing message: null for anything it would drop
const openPair = (message) => {
    const m = /^chatq2p\.([a-z2-7]{10})\.([A-Za-z0-9_-]+)$/.exec(String(message));
    if (!m || !pairKey) return null;
    try {
        const text = nodeCrypto.privateDecrypt({ key: pairKey, padding: nodeCrypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, unb64(m[2])).toString('utf8');
        return { pid: m[1], text, json: JSON.parse(text) };
    } catch (e) {
        return null;
    }
};

// --- the fixtures themselves: still what Node's crypto makes -------------------
{
    const master = unb64(vec.master), iv = unb64(vec.iv);
    const k = hmac(master, 'chatq-alert:' + vec.aid);
    const c = nodeCrypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), iv);
    const ct = Buffer.concat([c.update(Buffer.from(vec.payload, 'utf8')), c.final()]);
    const head = 'chatq1.' + vec.aid + '.' + b64url(iv) + '.' + b64url(ct);
    check('the reply fixture: the spec\'s fixed inputs', master.equals(Buffer.from(Array.from({ length: 32 }, (_, i) => i))) &&
        iv.equals(Buffer.from(Array.from({ length: 16 }, (_, i) => 0x10 + i))) && vec.aid === 'abcdefghij' &&
        vec.payload === '{"v":1,"act":"prompt","text":"yes, commit it ' + HANGUL + '","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}');
    check('the reply fixture: the Hangul raw in the payload, 6 bytes of UTF-8, and the file itself ASCII',
        Buffer.from(vec.payload, 'utf8').length === vec.payload.length + 4 && /^[\x00-\x7f]*$/.test(vectorText));
    check('the reply fixture: k and the message are what Node\'s crypto makes of them',
        vec.k === b64url(k) && vec.message === head + '.' + b64url(hmac(hmac(k, 'mac'), head)), vec.message);
    check('the reply fixture opens as the watcher opens it', (openMessage(vec.message, k) || {}).text === vec.payload);

    const p = pv.private || {};
    const len = (s) => Buffer.from(String(s || ''), 'base64').length;
    check('the pair fixture: ASCII, pid and the spec\'s payload verbatim', /^[\x00-\x7f]*$/.test(pairText) && pv.pid === 'abcdefghij' &&
        pv.payload === '{"v":2,"d":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","label":"Android - Chrome 128","ts":1790000000000}');
    check('the pair fixture: a 2048-bit key, every private field at the full width .NET\'s ImportParameters wants',
        len(p.Modulus) === 256 && len(p.D) === 256 && ['P', 'Q', 'DP', 'DQ', 'InverseQ'].every((n) => len(p[n]) === 128) &&
        len(p.Exponent) >= 1 && ['Modulus', 'Exponent', 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ'].every((n) => /^[A-Za-z0-9+/]+=*$/.test(p[n])));
    check('the pair fixture: the link\'s n and x are the private key\'s modulus and exponent, base64url',
        unb64(pv.modulus).equals(Buffer.from(p.Modulus, 'base64')) && unb64(pv.exponent).equals(Buffer.from(p.Exponent, 'base64')) &&
        /^[A-Za-z0-9_-]+$/.test(pv.modulus + pv.exponent));
    const o = openPair(pv.message);
    check('the pair fixture: its message opens with its private key to the payload exactly', !!o && o.pid === pv.pid && o.text === pv.payload,
        pairKey ? 'did not open' : 'the private key would not load');
    check('the pair fixture: its code is the confirmation code of the payload\'s D, six digits with the leading zeros',
        /^[0-9]{6}$/.test(pv.code || '') && pv.code === codeOf(unb64(JSON.parse(pv.payload).d)) && pv.code === codeOf(Buffer.from(Array.from({ length: 32 }, (_, i) => i))),
        String(pv.code));
}

// --- the page's two marked blocks ---------------------------------------------
const slice = (name) => {
    const b = '/* chatq-' + name + '-begin */', e = '/* chatq-' + name + '-end */';
    const i = html.indexOf(b), j = html.indexOf(e);
    if (i < 0 || j < i || html.indexOf(b, i + 1) >= 0 || html.indexOf(e, j + 1) >= 0) return null;
    return html.slice(i + b.length, j);
};
const cryptoJs = slice('crypto');
const logicJs = slice('logic');
check('the crypto block is marked, once', cryptoJs !== null);
check('the logic block is marked, once, after it', logicJs !== null && html.indexOf('chatq-logic-begin') > html.indexOf('chatq-crypto-end'));
// the code only: what its strings and comments say (a "setup window") is not a use
const codeOnly = (js) => String(js).replace(/'(?:[^'\\\n]|\\.)*'/g, "''").replace(/\/\/.*$/gm, '');
check('the crypto and logic blocks touch no page: no document, window, location, storage or fetch',
    cryptoJs !== null && logicJs !== null && !/\b(document|window|location|sessionStorage|localStorage|indexedDB|navigator|fetch|XMLHttpRequest)\b/.test(codeOnly(cryptoJs + logicJs)));
const GLOBALS = ['crypto', 'TextEncoder', 'btoa', 'atob', 'URL'];
const globalsArgs = [webcrypto, TextEncoder, btoa, atob, URL];
let C = null, P = null;
try {
    C = new Function(...GLOBALS, (cryptoJs || '') + '\nreturn ChatqCrypto;')(...globalsArgs);
    P = new Function(...GLOBALS, (cryptoJs || '') + '\n' + (logicJs || '') + '\nreturn ChatqPage;')(...globalsArgs);
} catch (e) {
    console.log('  ' + e.message);
}
check('the crypto block runs alone under Node\'s webcrypto', !!C && typeof C.seal === 'function' && typeof C.pair === 'function');
check('the logic block runs on top of it', !!P && typeof P.parseFragment === 'function');

const randomAid = () => Array.from(nodeCrypto.randomBytes(10), (b) => 'abcdefghijklmnopqrstuvwxyz234567'[b % 32]).join('');

(async () => {
    if (C) {
        const master = C.unb64url(vec.master), iv = C.unb64url(vec.iv);
        check('b64url: the page reads the fixture\'s keys back to the bytes they were',
            master.length === 32 && master.every((b, i) => b === i) && iv.length === 16 && iv.every((b, i) => b === 0x10 + i) &&
            C.b64url(master) === vec.master && C.b64url(iv) === vec.iv);
        check('b64url: every length, padding stripped, and no + or /', [0, 1, 2, 3, 4, 31, 32, 33].every((n) => {
            const b = nodeCrypto.randomBytes(n);
            const s = C.b64url(new Uint8Array(b));
            return s === b64url(b) && Buffer.from(C.unb64url(s)).equals(b);
        }) && C.b64url(new Uint8Array([0xfb, 0xff])) === '-_8');
        check('b64url: what is not base64url is null, not a guess',
            C.unb64url('ab+c') === null && C.unb64url('ab/c') === null && C.unb64url('abcde') === null && C.unb64url('ab=') === null && C.unb64url(7) === null);
        // v2: the fixture's master is the phone's key D, kept on the phone
        const k = await C.alertKey(master, vec.aid);
        check('the alert key: k from the phone\'s key, as the fixture has it from the master', C.b64url(k) === vec.k, C.b64url(k));
        const keys = await C.deriveKeys(k);
        check('deriveKeys: enc and mac are HMACs of k, as Node makes them',
            Buffer.from(keys.enc).equals(hmac(Buffer.from(k), 'enc')) && Buffer.from(keys.mac).equals(hmac(Buffer.from(k), 'mac')));
        const text = 'yes, commit it ' + HANGUL;
        check('the payload: JSON.stringify gives the spec\'s JSON exactly - key order, no spaces, Hangul raw',
            C.buildPayload('prompt', text, 'AAAAAAAAAAAAAAAAAAAAAA', 1790000000000) === vec.payload);
        const sealed = await C.seal(k, vec.aid, 'prompt', text, { iv, nonce: 'AAAAAAAAAAAAAAAAAAAAAA', ts: 1790000000000 });
        check('the test vector: the phone\'s key -> k -> seal() makes the fixture\'s message, byte for byte', sealed.message === vec.message, sealed.message);
        check('and sealPayload() over the verbatim payload too', (await C.sealPayload(C.unb64url(vec.k), vec.aid, vec.payload, iv)) === vec.message);

        // a fresh message each time: random key, alert, text; Node opens it
        const hard = 'line one\nline "two" \\ tab\there ' + HANGUL + ' ' + String.fromCodePoint(0x1F600) + ' </script> %20 & = #';
        const rk = new Uint8Array(nodeCrypto.randomBytes(32));
        const raid = randomAid();
        const before = Date.now();
        const s1 = await C.seal(rk, raid, 'prompt', hard);
        const s2 = await C.seal(rk, raid, 'prompt', hard);
        const o1 = openMessage(s1.message, Buffer.from(rk));
        check('round trip: Node verifies the MAC and decrypts a random message', !!o1 && o1.aid === raid && o1.json.text === hard && o1.json.act === 'prompt' && o1.json.v === 1);
        check('round trip: the payload\'s keys in the spec\'s order', !!o1 && Object.keys(o1.json).join() === 'v,act,text,nonce,ts');
        check('round trip: a nonce of 16 random bytes, and ts the time now in ms', !!o1 && /^[A-Za-z0-9_-]{22}$/.test(o1.json.nonce) &&
            unb64(o1.json.nonce).length === 16 && o1.json.ts >= before && o1.json.ts <= Date.now());
        check('round trip: two sends of one text differ in iv, nonce and all', s1.message !== s2.message && s1.nonce !== s2.nonce &&
            s1.message.split('.')[2] !== s2.message.split('.')[2]);
        check('round trip: the message is plain ASCII, five parts', /^[\x21-\x7e]+$/.test(s1.message) && s1.message.split('.').length === 5);
        const flip = (m, part) => { const p = m.split('.'); const c = p[part][5]; p[part] = p[part].slice(0, 5) + (c === 'A' ? 'B' : 'A') + p[part].slice(6); return p.join('.'); };
        check('a changed byte anywhere - the aid, iv, ciphertext or MAC - does not verify',
            openMessage(flip(s1.message, 1).replace(/^chatq1\.[^.]*/, 'chatq1.' + (raid[0] === 'a' ? 'b' : 'a') + raid.slice(1)), Buffer.from(rk)) === null &&
            [2, 3, 4].every((i) => openMessage(flip(s1.message, i), Buffer.from(rk)) === null));
        check('nor does another alert\'s key', openMessage(s1.message, nodeCrypto.randomBytes(32)) === null);
        const lost = [];
        for (const act of ['prompt', 'retry', 'allow', 'skip', 'stop', 'status', 'ping', 'wake']) {
            const o = openMessage((await C.seal(rk, raid, act, act === 'prompt' ? 'x' : '')).message, Buffer.from(rk));
            if (!o || o.json.act !== act) lost.push(act);
        }
        check('round trip: every act the watcher knows', lost.length === 0, lost.join());

        // --- pairing: the page seals, Node's privateDecrypt opens ------------------
        const pm = await C.sealPair(pv.modulus, pv.exponent, pv.pid, pv.payload).catch((e) => 'threw: ' + e.message);
        const po = openPair(pm);
        check('pairing: the page\'s RSA-OAEP (WebCrypto, JWK import) opens with Node\'s privateDecrypt to the payload exactly',
            !!po && po.pid === pv.pid && po.text === pv.payload, String(pm).slice(0, 80));
        check('pairing: "chatq2p." + pid + "." + 256 bytes of ciphertext, base64url, ASCII',
            /^chatq2p\.abcdefghij\.[A-Za-z0-9_-]{342}$/.test(String(pm)) && unb64(String(pm).split('.')[2]).length === 256);
        const fixedD = new Uint8Array(Array.from({ length: 32 }, (_, i) => i));
        const pp = await C.pair(pv.modulus, pv.exponent, pv.pid, 'Android - Chrome 128', { d: fixedD, ts: 1790000000000 });
        check('pairing: pair() writes the fixture\'s payload byte for byte from D, the label and ts', pp.payload === pv.payload &&
            (openPair(pp.message) || {}).text === pv.payload, pp.payload);
        const pr = await C.pair(pv.modulus, pv.exponent, pv.pid, 'x');
        const pro = openPair(pr.message);
        check('pairing: a fresh D of 32 random bytes each time, and it is the D in the message',
            pr.d.length === 32 && !!pro && pro.json.d === C.b64url(pr.d) && pro.json.v === 2 && Object.keys(pro.json).join() === 'v,d,label,ts' &&
            C.b64url((await C.pair(pv.modulus, pv.exponent, pv.pid, 'x')).d) !== C.b64url(pr.d));
        const worst = C.buildPairPayload(C.b64url(new Uint8Array(32).fill(255)), 'W'.repeat(40), 9999999999999);
        check('pairing: a 40-character label keeps the payload within RSA-OAEP\'s 190 bytes', Buffer.byteLength(worst) <= 190 && C.MAX_PAIR_PAYLOAD === 190,
            Buffer.byteLength(worst) + ' bytes');
        let over = false;
        try { await C.sealPair(pv.modulus, pv.exponent, pv.pid, 'x'.repeat(191)); } catch (e) { over = true; }
        check('pairing: a payload over 190 bytes is refused before it is sealed', over);
        const bogus = await C.sealPair(b64url(nodeCrypto.randomBytes(256)), pv.exponent, pv.pid, pv.payload).catch(() => null);
        check('pairing: sealed to another key, the PC cannot open it', bogus === null || openPair(bogus) === null);

        // --- the confirmation code, and the key the phone keeps -------------------
        check('the code: the fixture D\'s is the fixture\'s, as Node makes it', (await C.confirmCode(fixedD)) === pv.code, await C.confirmCode(fixedD));
        const codeMiss = [];
        let zeros = 0;
        for (let i = 0; i < 300; i++) {
            const d = nodeCrypto.randomBytes(32);
            const c = await C.confirmCode(new Uint8Array(d));
            if (c !== codeOf(d)) codeMiss.push(b64url(d) + ' ' + c + ' != ' + codeOf(d));
            if (c[0] === '0') zeros++;
        }
        check('the code: 300 random keys, each the code Node\'s HMAC gives (' + zeros + ' of them with a leading zero)', codeMiss.length === 0 && zeros > 0, codeMiss.slice(0, 3).join(' | '));
        const pk = await C.phoneKey(new Uint8Array(fixedD));
        const exportRefused = await webcrypto.subtle.exportKey('raw', pk).then(() => false, () => true);
        check('the kept key: HMAC SHA-256, sign only, and it will not export',
            pk.type === 'secret' && pk.extractable === false && pk.algorithm.name === 'HMAC' && pk.algorithm.hash.name === 'SHA-256' &&
            pk.usages.join() === 'sign' && exportRefused && C.isKey(pk) && !C.isKey(fixedD) && !C.isKey(null));
        check('the kept key: k from it is k from the raw D - the fixture\'s k', C.b64url(await C.alertKey(pk, vec.aid)) === vec.k);
        const kMiss = [];
        for (let i = 0; i < 20; i++) {
            const d = new Uint8Array(nodeCrypto.randomBytes(32)), aid = randomAid();
            const fromKey = await C.alertKey(await C.phoneKey(d), aid);
            if (!Buffer.from(fromKey).equals(Buffer.from(await C.alertKey(d, aid))) || !Buffer.from(fromKey).equals(alertKeyOf(d, aid))) kMiss.push(aid);
        }
        check('the kept key: 20 random keys and alerts, k the same from the key, from the bytes and from Node', kMiss.length === 0, kMiss.join());
        check('the kept key: its code is the raw D\'s', (await C.confirmCode(pk)) === pv.code);
        const viaKey = await C.seal(await C.alertKey(pk, vec.aid), vec.aid, 'prompt', text, { iv, nonce: 'AAAAAAAAAAAAAAAAAAAAAA', ts: 1790000000000 });
        check('the test vector through the kept key: the fixture\'s message, byte for byte', viaKey.message === vec.message);
    }

    if (P) {
        // --- the label the PC names this phone by ------------------------------
        const labels = {
            [ANDROID_UA]: 'Android - Chrome 128',
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1': 'iPhone - Safari 17',
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/128.0.6613.98 Mobile/15E148 Safari/604.1': 'iPhone - Chrome 128',
            'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36': 'Android - Samsung Internet 25',
            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36 EdgA/128.0.0.0': 'Android - Edge 128',
            'Mozilla/5.0 (Android 14; Mobile; rv:130.0) Gecko/130.0 Firefox/130.0': 'Android - Firefox 130',
            '': 'Phone'
        };
        const wrongLabels = Object.keys(labels).filter((ua) => P.deviceLabel(ua) !== labels[ua]);
        check('the label: OS and browser, as "Android - Chrome 128"', wrongLabels.length === 0, wrongLabels.map((ua) => P.deviceLabel(ua)).join(' | '));
        const odd = P.deviceLabel('Mozilla/5.0 (Linux; Android 14) SamsungBrowser/12345678901234567890123 "x"');
        check('the label: never past 40 characters, printable ASCII, no quote or backslash',
            odd.length <= 40 && /^[\x20-\x7e]*$/.test(odd) && !/["\\]/.test(odd) && P.LABEL_MAX === 40, odd);

        // --- the links -------------------------------------------------------
        const alertLink = (x) => {
            const q = Object.assign({ v: '2', a: 'k2m3n4p5q6', e: 'needs input', n: '7', c: 'fix the build ' + HANGUL, p: 'claude', j: 'needs-input' }, x);
            return '#' + Object.keys(q).filter((n) => q[n] !== undefined).map((n) => n + '=' + encodeURIComponent(q[n])).join('&');
        };
        const r = P.parseFragment(alertLink({}));
        check('an alert link: every field read, the title decoded',
            r.ok && r.mode === 'alert' && r.f.aid === 'k2m3n4p5q6' && r.f.event === 'needs input' && r.f.seq === '7' &&
            r.f.title === 'fix the build ' + HANGUL && r.f.provider === 'claude' && r.f.job === 'needs-input' && r.f.jobless === false, JSON.stringify(r));
        check('an alert link: with or without its #', P.parseFragment(alertLink({}).slice(1)).ok);
        const smuggled = P.parseFragment(alertLink({ k: b64url(nodeCrypto.randomBytes(32)), s: 'https://evil.example', t: 'evil-topic' }));
        check('an alert link: k, s and t in it are never read - nothing of a key or a destination comes from an alert',
            smuggled.ok && !('key' in smuggled.f) && !('server' in smuggled.f) && !('topic' in smuggled.f) &&
            !/evil|k=/.test(P.alertFragment(smuggled.f)), JSON.stringify(smuggled.f));
        check('an alert link: x=1 marks an alert about no chat', P.parseFragment(alertLink({ x: '1', n: '', j: '', e: 'reply' })).f.jobless === true);
        const kept = P.alertFragment(r.f);
        const back = P.parseFragment(kept);
        check('what a tab keeps of an alert: its own fields, and it reads back the same', /^v=2&a=k2m3n4p5q6&/.test(kept) &&
            back.ok && JSON.stringify(back.f) === JSON.stringify(r.f), kept);
        check('the heading: #seq and the title; none, the title alone', P.heading(r.f) === '#7 fix the build ' + HANGUL &&
            P.heading(P.parseFragment(alertLink({ n: '' })).f) === 'fix the build ' + HANGUL && P.heading(P.parseFragment(alertLink({ n: '', c: '', e: 'test' })).f) === 'chatq test');
        check('an event with a dash or in capitals reads as the words', P.parseFragment(alertLink({ e: 'Needs-Input' })).f.event === 'needs input');
        check('a seq that is no number is dropped', P.parseFragment(alertLink({ n: '7; x' })).f.seq === '');
        check('control characters in a title become spaces', P.parseFragment(alertLink({ c: 'a\nb\tc' })).f.title === 'a b c');
        check('no fragment, or none of ours: missing', ['', '#', '#foo=bar', undefined].every((h) => P.parseFragment(h).why === 'missing'));
        check('a v1 link, with its key in it: refused as from before pairing',
            P.parseFragment('#v=1&s=https%3A%2F%2Fntfy.sh&t=chatq-x&a=k2m3n4p5q6&k=' + b64url(nodeCrypto.randomBytes(32)) + '&e=done').why === 'old' &&
            P.cardText('old').code === 'chatnotify -Pair');
        check('a newer version of the link says so', P.parseFragment(alertLink({ v: '3' })).why === 'version' && P.parseFragment(alertLink({ m: 'unpair' })).why === 'version');

        const pairLink = (x) => {
            const q = Object.assign({ v: '2', m: 'pair', s: 'https://ntfy.sh', t: 'chatq-abcdefghijklmnopqrstuvwx', a: 'abcdefghij', n: pv.modulus, x: pv.exponent, h: 'DESKTOP-7' }, x);
            return '#' + Object.keys(q).filter((n) => q[n] !== undefined).map((n) => n + '=' + encodeURIComponent(q[n])).join('&');
        };
        const pl = P.parseFragment(pairLink({}));
        check('a pairing link: server, topic, pid, the key and the host read',
            pl.ok && pl.mode === 'pair' && pl.f.server === 'https://ntfy.sh' && pl.f.topic === 'chatq-abcdefghijklmnopqrstuvwx' && pl.f.pid === 'abcdefghij' &&
            pl.f.n === pv.modulus && pl.f.e === pv.exponent && pl.f.host === 'DESKTOP-7', JSON.stringify(pl));
        check('a pairing link: posted to the server, then the topic', pl.ok && P.postUrl(pl.f) === 'https://ntfy.sh/chatq-abcdefghijklmnopqrstuvwx');
        const self = P.parseFragment(pairLink({ s: 'https://push.example.org/ntfy/' }));
        check('a server of its own: its path kept, the trailing slash dropped', self.ok && self.f.server === 'https://push.example.org/ntfy');
        check('a host name: control characters out, 30 characters at most', P.parseFragment(pairLink({ h: 'A\nB' + 'x'.repeat(40) })).f.host === 'A B' + 'x'.repeat(27));
        const badPair = {
            'no server': { s: undefined },
            'an http server': { s: 'http://ntfy.sh' },
            'a server with a query': { s: 'https://ntfy.sh/?x=1' },
            'a server with a login': { s: 'https://u:p@ntfy.sh' },
            'not a url': { s: 'ntfy.sh' },
            'no topic': { t: undefined },
            'a topic with a slash': { t: 'a/b' },
            'a pid in capitals': { a: 'ABCDEFGHIJ' },
            'a pid of 9': { a: 'abcdefghi' },
            'no modulus': { n: undefined },
            'a modulus under 2048 bits': { n: b64url(nodeCrypto.randomBytes(128)) },
            'a modulus in plain base64': { n: pv.modulus.slice(0, -1) + '+' },
            'no exponent': { x: undefined },
            'an exponent of 9 bytes': { x: b64url(nodeCrypto.randomBytes(9)) }
        };
        const wrongPair = Object.keys(badPair).filter((n) => P.parseFragment(pairLink(badPair[n])).why !== 'bad');
        check('a damaged pairing link is refused: ' + Object.keys(badPair).length + ' ways', wrongPair.length === 0, wrongPair.join(', '));
        const badAlert = { 'no version': { v: undefined, m: undefined }, 'no aid': { a: undefined }, 'an aid in capitals': { a: 'K2M3N4P5Q6' }, 'an aid with a 1': { a: 'k2m3n4p5q1' } };
        const wrongAlert = Object.keys(badAlert).filter((n) => P.parseFragment(alertLink(badAlert[n])).why !== 'bad');
        check('a damaged alert link is refused: ' + Object.keys(badAlert).length + ' ways', wrongAlert.length === 0, wrongAlert.join(', '));
        check('and a broken %-escape too', P.parseFragment(alertLink({}) + '&c=%E0%A4%A').why === 'bad');

        // --- what the phone keeps --------------------------------------------
        const D = nodeCrypto.randomBytes(32);
        const rec = P.phoneRecord(pl.f, new Uint8Array(D), 1790000000000);
        const ph = P.parsePhone(rec);
        check('the phone\'s record: v, s, t, d, at, h - and it reads back',
            Object.keys(JSON.parse(rec)).join() === 'v,s,t,d,at,h' && !!ph && Buffer.from(ph.d).equals(D) && ph.server === 'https://ntfy.sh' &&
            ph.topic === pl.f.topic && ph.at === 1790000000000 && ph.host === 'DESKTOP-7', rec);
        const recObj = JSON.parse(rec);
        const badRec = [null, '', 'x', '{}', JSON.stringify(Object.assign({}, recObj, { v: 1 })), JSON.stringify(Object.assign({}, recObj, { d: recObj.d.slice(1) })),
            JSON.stringify(Object.assign({}, recObj, { s: 'http://ntfy.sh' })), JSON.stringify(Object.assign({}, recObj, { t: 'a/b' }))];
        check('a record that is not whole and sane reads as not paired', badRec.every((t) => P.parsePhone(t) === null));
        // v3, in IndexedDB: the key a CryptoKey that will not export
        const hk = (ext) => webcrypto.subtle.importKey('raw', new Uint8Array(D), { name: 'HMAC', hash: 'SHA-256' }, ext, ['sign']);
        const lockedKey = await hk(false);
        const sr = P.storedRecord(pl.f, lockedKey, 1790000000000, '026316');
        const sp = P.parseStored(sr);
        check('the kept record: {v: 3, s, t, key, at, h, code}, the key the CryptoKey itself, and it reads back',
            Object.keys(sr).join() === 'v,s,t,key,at,h,code' && sr.v === 3 && sr.key === lockedKey && !!sp && sp.key === lockedKey && sp.server === 'https://ntfy.sh' &&
            sp.topic === pl.f.topic && sp.at === 1790000000000 && sp.host === 'DESKTOP-7' && sp.code === '026316' && sp.readable === false);
        const badStored = {
            'v 2': Object.assign({}, sr, { v: 2 }),
            'a key that exports': Object.assign({}, sr, { key: await hk(true) }),
            'raw bytes for a key': Object.assign({}, sr, { key: new Uint8Array(D) }),
            'an AES key': Object.assign({}, sr, { key: await webcrypto.subtle.importKey('raw', new Uint8Array(D), { name: 'AES-CBC' }, false, ['encrypt']) }),
            'an http server': Object.assign({}, sr, { s: 'http://ntfy.sh' }),
            'a topic with a slash': Object.assign({}, sr, { t: 'a/b' }),
            'nothing': undefined, 'a string': '{"v":3}'
        };
        const wrongStored = Object.keys(badStored).filter((n) => P.parseStored(badStored[n]) !== null);
        check('a kept record that is not whole and sane reads as not paired: ' + Object.keys(badStored).length + ' ways', wrongStored.length === 0, wrongStored.join(', '));
        check('a kept record with a code that is not six digits: paired, and no code shown', P.parseStored(Object.assign({}, sr, { code: '12345' })).code === '');
        check('the code as shown: "026 316"; nothing for what is not six digits', P.codeText('026316') === '026 316' && P.codeText('12345') === '' && P.codeText(undefined) === '');
        check('where a pairing link sends replies: the host and the topic\'s start past chatq-',
            P.whereTo(pl.f) === 'ntfy.sh, topic chatq-abcdef\u2026' && P.whereTo({ server: 'https://push.example.org/ntfy', topic: 'evil' }) === 'push.example.org, topic evil' &&
            P.whereTo({ server: 'https://ntfy.sh', topic: 'phishyphishy' }) === 'ntfy.sh, topic phishy\u2026', P.whereTo(pl.f));
        const rc = P.cardText('replace', { pf: pl.f, phone: { host: 'LAPTOP' } });
        check('the replace card: only if you just pressed Pair phone, where replies would go, the pairing it ends, and a second tap',
            /^Only continue if you just pressed Pair phone on your PC\./.test(rc.warn) && rc.warn.indexOf('ntfy.sh, topic chatq-abcdef\u2026') >= 0 &&
            /chatq on LAPTOP/.test(rc.warn) && rc.button === 'Replace pairing' && rc.confirm === 'Tap again to replace', rc.warn);
        const fc = P.cardText('pair', { pf: pl.f });
        check('a first pairing: no warning, one tap', !fc.warn && fc.button === 'Pair' && !fc.confirm);
        const cc = P.cardText('paired', { pf: pl.f, phone: { code: '026316' } });
        check('after the pairing POST: the code big, "On the PC, confirm this code"', cc.big === '026 316' && cc.head === 'On the PC, confirm this code' && !cc.warn);
        check('a phone with no IndexedDB is told its key is readable to this site\'s pages',
            /keeps the key readable to this site's pages/.test(P.READABLE) && ['paired', 'same', 'home'].every((k) => P.cardText(k, { pf: pl.f, phone: { code: '026316', readable: true } }).warn === P.READABLE) &&
            ['paired', 'same', 'home'].every((k) => !P.cardText(k, { pf: pl.f, phone: { code: '026316' } }).warn));

        // --- the buttons each alert gets ----------------------------------------
        const acts = (e, p, x) => { const b = P.buttonsFor(e, p, x); return b.send.act + '|' + b.more.map((y) => y.act).join(','); };
        check('done: Send | Status', acts('done', 'claude') === 'prompt|status');
        check('needs input, Claude: Send | Allow edits & continue | Continue | Skip | Status',
            acts('needs input', 'claude') === 'prompt|allow,retry,skip,status' &&
            P.buttonsFor('needs input', 'claude').more.map((x) => x.label).join('|') === 'Allow edits & continue|Continue|Skip|Status');
        check('needs input, Codex: no Allow - raising the mode is Claude\'s alone', acts('needs input', 'codex') === 'prompt|retry,skip,status' &&
            acts('needs input', '') === 'prompt|retry,skip,status');
        check('failed: Send | Retry | Skip | Status', acts('failed', 'codex') === 'prompt|retry,skip,status');
        check('started: Send, queued after this run | Stop | Status', acts('started', 'claude') === 'prompt|stop,status' && /after this run|this run finishes/.test(P.buttonsFor('started').hint));
        check('test: only Send a test reply, a ping, no box', acts('test') === 'ping|' && P.buttonsFor('test').text === false &&
            P.buttonsFor('test').send.label === 'Send a test reply' && acts('test', '', true) === 'ping|');
        check('the rest - limited, overloaded, waiting, a reply, none: Send | Status',
            ['limited', 'overloaded', 'waiting', 'reply', '', 'something new'].every((e) => acts(e, 'claude') === 'prompt|status'));
        check('about no chat (x=1): no box, Status; a reply (the PC\'s answer, a pairing\'s confirmation) also offers a test reply',
            acts('reply', '', true) === 'status|ping' && acts('done', 'claude', true) === 'status|' && P.buttonsFor('reply', '', true).text === false &&
            ['reply', 'done', 'needs input', 'failed', 'started'].every((e) => !P.buttonsFor(e, 'claude', true).text));
        check('Skip and Stop ask for a second tap; nothing else does',
            ['done', 'needs input', 'failed', 'started', 'test', 'waiting'].every((e) => P.buttonsFor(e, 'claude').more.concat([P.buttonsFor(e, 'claude').send])
                .every((b) => !!b.confirm === (b.act === 'skip' || b.act === 'stop'))));
        const EVENTS = ['done', 'needs input', 'failed', 'started', 'limited', 'overloaded', 'waiting', 'reply', ''];
        const live = (e, p) => { const b = P.buttonsFor(e, p, false, 'live'); return b.send.act + '|' + b.more.map((y) => y.act).join(','); };
        check('a chat run in VS Code (j=live): Send | Status whatever the event - no Continue, Allow, Retry, Skip or Stop',
            EVENTS.every((e) => ['claude', 'codex', ''].every((p) => live(e, p) === 'prompt|status' && P.buttonsFor(e, p, false, 'live').text === true)),
            EVENTS.map((e) => e + '=' + live(e, 'claude')).join(' '));
        check('j=live: the hint says it goes into that chat when it is idle - needs input aside',
            EVENTS.filter((e) => e !== 'needs input').every((e) => /goes into this chat when it is idle/.test(P.buttonsFor(e, 'claude', false, 'live').hint)));
        const liveHeld = P.buttonsFor('needs input', 'claude', false, 'live');
        check('j=live needing input: the hint says it goes once its prompt is answered at the PC, and nothing offers to answer it',
            /once its prompt is answered at the PC/.test(liveHeld.hint) && !/answer it/i.test(liveHeld.placeholder) &&
            P.buttonsFor('needs-input', 'codex', false, 'live').hint === liveHeld.hint, liveHeld.hint + ' | ' + liveHeld.placeholder);
        check('j=live does not leak: a real job id still gets the full set',
            acts('needs input', 'claude') === 'prompt|allow,retry,skip,status' &&
            P.buttonsFor('needs input', 'claude', false, 'j-20260926-abc').more.map((x) => x.act).join() === 'allow,retry,skip,status' &&
            P.buttonsFor('started', 'claude', false, 'live').more.every((x) => x.act !== 'stop'));
        const lp = P.parseFragment(alertLink({ e: 'needs input', p: 'claude', j: 'live' }));
        check('a j=live link parses to job live and keeps it in the tab\'s fragment',
            lp.ok && lp.f.job === 'live' && /(^|&)j=live(&|$)/.test(P.alertFragment(lp.f)) &&
            P.buttonsFor(lp.f.event, lp.f.provider, lp.f.jobless, lp.f.job).more.map((x) => x.act).join() === 'status', JSON.stringify(lp));
        // auto-continue (0.9.0): limited about a continue still queued offers
        // Don't continue - skip, which the watcher knows, two taps
        const lim = P.buttonsFor('limited', 'claude', false, 'queued');
        const dont = lim.more[0] || {};
        check('limited, a continue queued (j=queued): Send | Don\'t continue, two taps | Status, and the box says the prompt goes after it',
            lim.send.act === 'prompt' && lim.more.map((x) => x.act).join() === 'skip,status' && dont.label === 'Don\'t continue' &&
            dont.confirm === 'Tap again - it will not continue' && lim.placeholder === 'Next prompt - goes after the continue' &&
            P.buttonsFor('limited', 'claude', false, 'live').more.map((x) => x.act).join() === 'status' &&
            P.buttonsFor('limited', 'claude', false, 'running').more.map((x) => x.act).join() === 'status', JSON.stringify(lim));
        const ACTS = ['prompt', 'retry', 'allow', 'skip', 'stop', 'status', 'ping', 'wake',
            'permit', 'refuse'];
        const offered = new Set();
        for (const e of ['done', 'needs input', 'failed', 'started', 'test', 'limited', 'overloaded', 'waiting', 'reply', 'usage', 'summary', '']) {
            for (const p of ['claude', 'codex', '']) {
                for (const x of [false, true]) {
                    for (const w of [false, true]) {
                        const b = P.buttonsFor(e, p, x, '', w);
                        [b.send].concat(b.more).forEach((y) => offered.add(y.act));
                    }
                }
            }
        }
        // a permission request: with a card that opened, and with none
        for (const perm of [{ u: 1790000600000, h: 'AAAAAAAAAAAAAAAAAAAAAA' }, null]) {
            const b = P.buttonsFor('permission', 'claude', false, 'running', false, perm, 1790000000000);
            [b.send].concat(b.more).forEach((y) => offered.add(y.act));
        }
        check('every act a button sends is one the watcher knows, and every one is offered somewhere',
            [...offered].every((a) => ACTS.includes(a)) && ACTS.every((a) => offered.has(a)) && P.ACTS.join() === ACTS.join(), [...offered].join());

        // --- usage alerts, and text from outside the page (phone-extras-spec) ---
        const wl = P.parseFragment(alertLink({ e: 'usage', n: '', c: '', p: '', j: '', x: '1', w: '1' }));
        check('a usage alert about a reset coming: w=1 read as wake, and kept in the tab\'s fragment',
            wl.ok && wl.f.wake === true && wl.f.jobless === true && /(^|&)w=1(&|$)/.test(P.alertFragment(wl.f)) &&
            P.parseFragment(alertLink({})).f.wake === false && !/(^|&)w=/.test(P.alertFragment(P.parseFragment(alertLink({})).f)), JSON.stringify(wl.f));
        check('usage with wake: no box, Send now big (wake), Status small; without: Status alone',
            acts('usage', '', true) === 'status|' && (() => { const b = P.buttonsFor('usage', '', true, '', true); return b.send.act === 'wake' && b.send.label === 'Send now' &&
                b.more.map((y) => y.act).join() === 'status' && b.text === false && /a probe goes first/.test(b.about); })() &&
            /About usage limits/.test(P.buttonsFor('usage', '', true, '').about) && acts('summary', '', true) === 'status|' &&
            P.buttonsFor('done', 'claude', true, '', true).send.act === 'status');
        check('Send now says so once sent', P.sentText({ act: 'wake', label: 'Send now' }) === 'Sent "Send now". The PC answers with a push.');
        const tx = (t) => P.parseFragment('#v=2&a=abcdefghij&e=done&n=3&c=x' + (t === undefined ? '' : '&text=' + t));
        const t1 = tx('hello%20world');
        check('text=: read into f.text, the link otherwise the same', t1.ok && t1.mode === 'alert' && t1.f.text === 'hello world' && t1.f.aid === 'abcdefghij', JSON.stringify(t1));
        check('text=: + is a space, %2B a plus', tx('a+b%2Bc').f.text === 'a b+c');
        check('text=: Hangul and a 4-byte emoji survive, CRLF is a newline, NUL and other controls go, the tab stays',
            tx('%ED%95%9C%20%F0%9F%98%80').f.text === HANGUL[0] + ' ' + String.fromCodePoint(0x1F600) && tx('a%0D%0Ab%00c%07%09d').f.text === 'a\nbc\td', JSON.stringify(tx('a%0D%0Ab%00c%07%09d').f.text));
        const brokenText = tx('%E0%A4');
        check('text=: a broken escape is no text - and the link is still good', brokenText.ok === true && brokenText.f.text === '' && brokenText.f.event === 'done');
        check('text=: over 16,000 characters is dropped, not cut', tx('a'.repeat(16001)).f.text === '' && tx('a'.repeat(16000)).f.text.length === 16000 && P.TEXT_MAX === 16000);
        check('text=: none is empty; surrounding space trimmed', tx().f.text === '' && tx('%20%20hi%0A').f.text === 'hi');
        const pairWithText = P.parseFragment(pairLink({}) + '&text=hello');
        check('text= on a pairing link is not read; a v1 link is refused whole as ever', pairWithText.ok && pairWithText.mode === 'pair' && !('text' in pairWithText.f) &&
            P.parseFragment('#v=1&a=abcdefghij&e=done&text=hi').why === 'old');
        check('the tab\'s kept fragment never carries the text', !/text/.test(P.alertFragment(t1.f)) && P.parseFragment(P.alertFragment(t1.f)).f.text === '');
        const specDone = P.buttonsFor('done', 'claude', false, 'done'), specTest = P.buttonsFor('test');
        const pTest = P.prefill(specTest, { text: 'hi' }, null);
        const pNew = P.prefill(specDone, { text: 'hi' }, null);
        const pOver = P.prefill(specDone, { text: 'hi' }, { text: 'what I typed' });
        const pSame = P.prefill(specDone, { text: 'hi' }, { text: 'hi' });
        const pNone = P.prefill(specDone, { text: '' }, { text: 'draft' });
        check('prefill: an alert that takes no text drops it and says so',
            pTest.text === null && pTest.note === 'This alert takes no text - what was sent along was left out.' && P.prefill(specTest, { text: '' }, null).note === '');
        check('prefill: the link\'s text wins, with the note; over a different draft the note says it replaced it',
            pNew.text === 'hi' && pNew.note === P.PREFILL_NOTE && P.PREFILL_NOTE === 'Filled in from outside the page - check it, then Send.' &&
            pOver.text === 'hi' && /It replaced what was typed here before\.$/.test(pOver.note) && pSame.note === P.PREFILL_NOTE);
        check('prefill: no text from the link - the draft as ever, no note', pNone.text === 'draft' && pNone.note === '' && P.prefill(specDone, { text: '' }, null).text === '');
        check('nothing a link can say names an act: no field of parseFragment\'s answer is act, send, press or confirm',
            ['act', 'send', 'press', 'confirm', 'go'].every((k) => !(k in P.parseFragment(alertLink({ act: 'stop', send: '1', press: '1', confirm: '1', go: '1' })).f)));

        // --- the payload limit ---------------------------------------------------
        if (C) {
            const rk = new Uint8Array(nodeCrypto.randomBytes(32));
            const base = P.payloadBytes('');
            const fill = (n) => HANGUL[0].repeat(Math.floor(n / 3)) + 'a'.repeat(n % 3);
            const biggest = fill(P.MAX_PAYLOAD - base);
            const big = await C.seal(rk, randomAid(), 'prompt', biggest);
            check('the limit: a payload of exactly 2900 bytes seals under ntfy\'s 4096-byte message',
                P.MAX_PAYLOAD === 2900 && P.payloadBytes(biggest) === 2900 && Buffer.from(big.payload, 'utf8').length === 2900 && big.message.length <= 4096,
                P.payloadBytes(biggest) + ' ' + big.message.length);
            check('the counter: fine, then warned before the limit, then over and Send off',
                P.counter('hi').state === 'ok' && P.counter(fill(P.WARN_AT - base)).state === 'warn' && P.WARN_AT < P.MAX_PAYLOAD &&
                P.counter(biggest).state === 'warn' && P.counter(biggest + 'a').state === 'over' && /1 bytes too long/.test(P.counter(biggest + 'a').label));
            check('the counter: an empty box reads 0 of what the payload leaves the text', P.counter('').label === '0 / ' + (2900 - base) + ' bytes', P.counter('').label);
            check('the counter counts Hangul as the 3 bytes it takes', P.payloadBytes(HANGUL) - P.payloadBytes('') === 6);
            check('and a quote or newline as the escape JSON writes', P.payloadBytes('"\n') - P.payloadBytes('') === 4);
        }
    }

    // --- a permission request's card and answer (docs/phone-permit-spec.md) ----
    await checkPermitLogic();

    // --- the whole page, against a fake DOM ------------------------------------
    await driveThePage();

    // --- what the page must never do ------------------------------------------
    check('the page is pure ASCII', /^[\x00-\x7f]*$/.test(html));
    check('no URL of its own: neither http:// nor https:// anywhere in it', !/https?:\/\//i.test(html));
    check('no <script src>: every script is inline', !/<script\b[^>]*\bsrc\s*=/i.test(html) && (html.match(/<script\b/gi) || []).length === 1);
    check('no <link> but the empty data: icon', (html.match(/<link\b[^>]*>/gi) || []).every((l) => /\bhref\s*=\s*"data:/i.test(l)));
    check('no <img>, <iframe>, <object>, <embed>, <base>, <form>, <use> or <image>', !/<(img|iframe|object|embed|base|form|audio|video|source|use|image)\b/i.test(html));
    const css = (html.match(/<style>([\s\S]*?)<\/style>/) || [])[1] || '';
    check('no CSS that loads: no url() but data:, no @import, no style="" to hide one in',
        css.length > 0 && !/url\(\s*["']?(?!data:)/i.test(css) && !/@import/i.test(html) && !/\sstyle\s*=/i.test(html));
    const csp = (html.match(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"/i) || [])[1] || '';
    const dirs = {};
    csp.split(';').map((d) => d.trim().split(/\s+/)).filter((d) => d[0]).forEach((d) => { dirs[d[0]] = d.slice(1).join(' '); });
    check('the CSP meta: nothing by default, inline style and script only, connect to https only, images data: only',
        dirs['default-src'] === "'none'" && dirs['style-src'] === "'unsafe-inline'" && dirs['script-src'] === "'unsafe-inline'" &&
        dirs['connect-src'] === 'https:' && dirs['img-src'] === 'data:', csp);
    check('the referrer meta: no-referrer', /<meta\s+name="referrer"\s+content="no-referrer">/i.test(html));
    const fetches = html.match(/\bfetch\(/g) || [];
    const at = html.indexOf('fetch(');
    const opts = at < 0 ? '' : html.slice(at, html.indexOf('})', at) + 2);
    // the POST, and since 0.9.0 the GET that reads the down topic
    const at2 = html.indexOf('fetch(', at + 1);
    const getOpts = at2 < 0 ? '' : html.slice(at2, html.indexOf('})', at2) + 2);
    check('two requests only, both fetch - the POST and the GET of the down topic; no XHR, beacon, socket or event source',
        fetches.length === 2 && !/XMLHttpRequest|sendBeacon|WebSocket|EventSource|importScripts|\bimport\(/.test(html));
    check('the GET: no header at all, no cookie, no referrer - a CORS simple request',
        /method:\s*'GET'/.test(getOpts) && !/headers:/.test(getOpts) && /credentials:\s*'omit'/.test(getOpts) && /referrerPolicy:\s*'no-referrer'/.test(getOpts), getOpts);
    check('the POST: Content-Type text/plain and no other header - a CORS simple request',
        /method:\s*'POST'/.test(opts) && /headers:\s*\{\s*'Content-Type':\s*'text\/plain'\s*\}/.test(opts) && (opts.match(/headers:/g) || []).length === 1, opts);
    check('the POST sends no cookie and no referrer', /credentials:\s*'omit'/.test(opts) && /referrerPolicy:\s*'no-referrer'/.test(opts));
    const named = [...html.matchAll(/\bact:\s*'([^']*)'/g)].map((m) => m[1]);
    // an alert's acts, read (the whole answer again), and the board's
    // (docs/phone-board-spec.md) - tests/board-page-check.js holds those to
    // the watcher's own list
    const boardActs = ['read', 'board', 'list', 'send', 'new', 'continue', 'now'];
    check('every act written in the page is one the watcher knows', named.length > 0 &&
        named.every((a) => ['prompt', 'retry', 'allow', 'skip', 'stop', 'status', 'ping', 'wake', 'permit', 'refuse'].concat(boardActs).includes(a)), named.join());
    check('the key is kept in IndexedDB chatq / phone, imported as a key that will not export; localStorage chatq-phone only without it',
        /var DB = 'chatq', DB_STORE = 'phone'/.test(html) && /indexedDB\.open\(DB, 1\)/.test(html) &&
        /importKey\('raw', d, \{ name: 'HMAC', hash: 'SHA-256' \}, false, \['sign'\]\)/.test(html) && !/importKey\('raw'[^)]*\btrue\b/.test(html) &&
        /'chatq-phone'/.test(html) && (html.match(/localStorage\.setItem\(/g) || []).length === 2 && /localStorage\.setItem\(PHONE, P\.phoneRecord/.test(html));
    check('no request event is told preventDefault inside a transaction: a failed write aborts, never completes as kept',
        !/tx\.onerror[^\n]*preventDefault/.test(html));
    // No auto-send: press(, deliver( and seal( are called only from inside
    // a click or keydown handler, or from press itself - so a link, a
    // reload or any code that runs as the page opens can never send. A
    // crude walk over the script (strings and comments skipped, braces
    // counted) finds what each call sits inside.
    {
        const js = (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1] || '';
        const opens = [];
        const calls = [];
        for (let i = 0; i < js.length; i++) {
            const c = js[i];
            if (c === '/' && js[i + 1] === '/') { const nl = js.indexOf('\n', i); i = nl < 0 ? js.length : nl; continue; }
            if (c === '/' && js[i + 1] === '*') { const e = js.indexOf('*/', i + 2); i = e < 0 ? js.length : e + 1; continue; }
            if (c === '\'' || c === '"') { let j = i + 1; while (j < js.length && js[j] !== c) { if (js[j] === '\\') j++; j++; } i = j; continue; }
            if (c === '/' && /[(,=:[!&|?{};]$|^$/.test(js.slice(0, i).trimEnd().slice(-1))) {
                // a regex literal: to its closing slash, past any [...] in it
                let j = i + 1, cls = false;
                while (j < js.length && (cls || js[j] !== '/')) { if (js[j] === '\\') j++; else if (js[j] === '[') cls = true; else if (js[j] === ']') cls = false; j++; }
                i = j;
                continue;
            }
            if (c === '{') { opens.push(i); continue; }
            if (c === '}') { opens.pop(); continue; }
            if (/[\w$.]/.test(js[i - 1] || '')) continue;
            const m = /^(?:C\.)?(press|deliver|seal)\(/.exec(js.slice(i, i + 12));
            if (!m) continue;
            if (/function\s+$/.test(js.slice(Math.max(0, i - 20), i))) continue;
            calls.push({ name: m[1], at: i, stack: opens.slice() });
            i += m[0].length - 1;
        }
        // askAlertRead seals act read - the whole answer sent again, which
        // changes nothing on the PC - and runs only as a panel button's
        // click (drawPanel's ask): held to that just below
        const allowed = (pos) => {
            const head = js.slice(Math.max(0, pos - 160), pos);
            return /function press\s*\([^)]*\)\s*$/.test(head) || /addEventListener\('(click|keydown)',\s*function\s*\([^)]*\)\s*$/.test(head) ||
                /async function askAlertRead\s*\(\)\s*$/.test(head);
        };
        const bad = calls.filter((c) => !c.stack.some(allowed));
        check('no auto-send: every press(, deliver( and seal( is inside a click or keydown handler, or press itself',
            calls.length >= 6 && calls.some((c) => c.name === 'seal') && calls.some((c) => c.name === 'deliver') && bad.length === 0,
            calls.length + ' calls; outside: ' + bad.map((c) => c.name + ' @ ' + js.slice(c.at - 60, c.at + 20).replace(/\s+/g, ' ')).join(' | '));
        const readCalls = [...js.matchAll(/askAlertRead\(/g)].map((m) => js.slice(Math.max(0, m.index - 40), m.index));
        check('askAlertRead is called only from a panel button\'s click, as its ask',
            readCalls.length === 2 && readCalls.some((h) => /async function $/.test(h)) && readCalls.some((h) => /var ask = function \(\) \{ $/.test(h)) &&
            /ask\.addEventListener\('click', extra\.ask\)/.test(js), readCalls.join(' | '));
    }
    check('the box autofocuses', /<textarea\b[^>]*\bautofocus\b/.test(html));
    check('dark and light by prefers-color-scheme', /@media \(prefers-color-scheme: dark\)/.test(html) && /<meta name="color-scheme" content="light dark">/.test(html));
    check('the keyboard resizes the page rather than covering Send', /interactive-widget=resizes-content/.test(html));
    const nj = path.join(root, 'docs', '.nojekyll');
    check('docs/.nojekyll is there, empty: GitHub Pages serves docs/ as it is', fs.existsSync(nj) && fs.statSync(nj).size === 0);

    console.log('');
    console.log('  ' + (total - failed) + ' passed, ' + failed + ' failed');
    process.exit(failed);
})().catch((e) => {
    console.log('  FAIL  threw: ' + (e && e.stack || e));
    process.exit(failed + 1);
});

// A card sealed the way the PC seals one (Protect-ChatqPermitCard), by
// Node's own crypto: the page is only ever asked to open it
function sealCard(d, aid, obj, iv) {
    const kc = hmac(Buffer.from(d), 'chatq-card:' + aid);
    iv = iv || nodeCrypto.randomBytes(16);
    const c = nodeCrypto.createCipheriv('aes-256-cbc', hmac(kc, 'enc'), iv);
    const ct = Buffer.concat([c.update(Buffer.from(typeof obj === 'string' ? obj : JSON.stringify(obj), 'utf8')), c.final()]);
    const head = 'chatq1c.' + aid + '.' + b64url(iv) + '.' + b64url(ct);
    return head + '.' + b64url(hmac(hmac(kc, 'mac'), head));
}

// The card, the permit's payload and the buttons, held to
// tests/fixtures/card-vector.json (Node's own crypto) and to the watcher:
// every act the page can send is one Invoke-ChatqReply has a case for.
async function checkPermitLogic() {
    let cv = null;
    try { cv = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'card-vector.json'), 'utf8')); } catch (e) { }
    check('the card fixture is there, ASCII', !!cv && /^[\x00-\x7f]*$/.test(fs.readFileSync(path.join(__dirname, 'fixtures', 'card-vector.json'), 'latin1')));
    if (!cv || !C || !P) return;
    const master = C.unb64url(cv.master);
    const want = JSON.parse(cv.card);
    const fromBytes = await C.openCard(master, cv.aid, cv.sealed);
    const fromKey = await C.openCard(await C.phoneKey(new Uint8Array(master)), cv.aid, cv.sealed);
    check('openCard: the fixture\'s card opens with the raw key and with the kept CryptoKey, to the card exactly',
        JSON.stringify(fromBytes) === JSON.stringify(want) && JSON.stringify(fromKey) === JSON.stringify(want) && want.w.indexOf(HANGUL) > 0, JSON.stringify(fromBytes));
    check('the card fixture: its seal is Node\'s, and the card names the request\'s own digest',
        sealCard(master, cv.aid, cv.card, unb64(cv.iv)) === cv.sealed && want.h === cv.digest &&
        cv.digest === b64url(nodeCrypto.createHash('sha256').update(Buffer.from('chatq-permit\n' + cv.rid + '\n' + cv.tool + '\n' + cv.inputRaw, 'utf8')).digest().subarray(0, 16)));
    const parts = cv.sealed.split('.');
    const flip = (i) => { const p = parts.slice(); const c = p[i][3]; p[i] = p[i].slice(0, 3) + (c === 'A' ? 'B' : 'A') + p[i].slice(4); return p.join('.'); };
    const bad = [flip(2), flip(3), flip(4)];
    const opened = await Promise.all(bad.map((m) => C.openCard(master, cv.aid, m)));
    check('openCard: a changed byte in the iv, the ciphertext or the MAC gives null', opened.every((o) => o === null));
    check('openCard: another alert\'s id, another key, a reply message or junk gives null',
        (await C.openCard(master, 'zzzzzzzzzz', cv.sealed)) === null && (await C.openCard(new Uint8Array(nodeCrypto.randomBytes(32)), cv.aid, cv.sealed)) === null &&
        (await C.openCard(master, cv.aid, cv.permitMessage)) === null && (await C.openCard(master, cv.aid, 'chatq1c.abcdefghij.x.y.z')) === null &&
        (await C.openCard(master, cv.aid, '')) === null);
    // the permit: h last, and only when given
    check('buildPayload without h is the reply fixture\'s payload still; with h, the permit fixture\'s',
        C.buildPayload('prompt', 'yes, commit it ' + HANGUL, 'AAAAAAAAAAAAAAAAAAAAAA', 1790000000000) === vec.payload &&
        C.buildPayload('permit', '', 'AAAAAAAAAAAAAAAAAAAAAA', 1790000000000, cv.digest) === cv.permitPayload);
    const sp = await C.seal(await C.alertKey(master, cv.aid), cv.aid, 'permit', '', { iv: C.unb64url(cv.replyIv), nonce: 'AAAAAAAAAAAAAAAAAAAAAA', ts: 1790000000000 }, cv.digest);
    const spo = openMessage(sp.message, alertKeyOf(master, cv.aid));
    check('the sealed permit: the fixture\'s message byte for byte, and h opens intact', sp.message === cv.permitMessage && !!spo && spo.json.h === cv.digest &&
        Object.keys(spo.json).join() === 'v,act,text,nonce,ts,h', sp.message);
    const rk = new Uint8Array(nodeCrypto.randomBytes(32)), raid = randomAid();
    const lost = [];
    for (const act of ['permit', 'refuse']) {
        const o = openMessage((await C.seal(rk, raid, act, act === 'refuse' ? 'not now ' + HANGUL : '', undefined, act === 'permit' ? cv.digest : undefined)).message, Buffer.from(rk));
        if (!o || o.json.act !== act || (act === 'permit') !== ('h' in o.json)) lost.push(act);
    }
    check('round trip: permit (with h) and refuse (without)', lost.length === 0, lost.join());

    // the buttons, and what the page shows
    const now = 1790000000000;
    const card = { v: 1, t: 'Bash', w: 'git push', d: 'Push', f: 'parser', c: 'Parser', n: 12, h: cv.digest, u: now + 12 * 60000 };
    const open = P.buttonsFor('permission', 'claude', false, 'running', false, card, now);
    check('a permission request with its card: Allow once (a second tap), Deny, Status; the box a note for Deny, optional',
        open.send.act === 'permit' && open.send.label === 'Allow once' && open.send.confirm === 'Tap again to allow' &&
        open.more.map((b) => b.act + ':' + b.label).join('|') === 'refuse:Deny|status:Status' && !open.more[0].confirm && open.text === true && open.optional === true &&
        open.placeholder === 'A note for Claude, with Deny (optional)' && open.hint === 'the note goes only with Deny');
    const late = P.buttonsFor('permission', 'claude', false, 'running', false, card, card.u);
    const none = P.buttonsFor('permission', 'claude', false, 'running', false, null, now);
    const acts = (b) => [b.send].concat(b.more).map((y) => y.act);
    check('no Allow after the deadline (Status alone), nor without a card that opened (Deny and Status)',
        acts(late).join() === 'status' && late.text === false && acts(none).join() === 'refuse,status' && none.text === true &&
        acts(late).concat(acts(none)).indexOf('permit') < 0);
    check('ACTS holds permit and refuse', P.ACTS.indexOf('permit') >= 0 && P.ACTS.indexOf('refuse') >= 0);
    const ps1 = fs.readFileSync(path.join(root, 'src', 'phone.ps1'), 'latin1');
    check('and each is an act the watcher has a case for (Invoke-ChatqReply)', P.ACTS.every((a) => ps1.indexOf("'" + a + "' {") >= 0), P.ACTS.filter((a) => ps1.indexOf("'" + a + "' {") < 0).join());
    const pv = P.permitView(Object.assign({}, card, { c: 'Parser rewrite ' + HANGUL }), {}, now);
    check('the card shown: #12 and the chat, Allow this once?, the call, the tool and folder, Claude\'s words, the time left, the fine print',
        pv.state === 'open' && pv.kicker === '#12 Parser rewrite ' + HANGUL && pv.head === 'Allow this once?' && pv.what === 'git push' &&
        pv.where === 'Bash \u00b7 in parser' && pv.detail === 'Claude: Push' && /^answer by \d\d:\d\d - 12 min left$/.test(pv.left) &&
        pv.fine === 'Allow runs this one call. It changes nothing else the run may do.' && !pv.body, JSON.stringify(pv));
    const px = P.permitView(Object.assign({}, card, { x: 1 }), {}, now);
    check('a card whose call is not all there (x): says so, and to deny what cannot be told', px.state === 'open' &&
        /^Not all of this call is shown - parts are hidden \(\*\*\*\) or cut\. If you cannot tell what it does, Deny\.$/.test(px.body), JSON.stringify(px));
    const pl = P.permitView(card, {}, card.u + 1);
    const pn = P.permitView(null, { seq: '12', title: 'Parser' }, now);
    check('too late: At <time> the run went on without it; no card: nothing to approve here',
        pl.state === 'late' && pl.head === 'Too late' && /^At \d\d:\d\d the run went on without it\.$/.test(pl.body) &&
        pn.state === 'none' && pn.head === 'Nothing to approve here' && /sealed for another key, or changed on the way/.test(pn.body) && pn.kicker === '#12 Parser');
    // the link: r read only in a card's own shape, and kept for a reload
    const withCard = P.parseFragment('#v=2&a=abcdefghij&e=permission&n=12&c=x&p=claude&j=running&r=' + encodeURIComponent(cv.sealed));
    const junk = P.parseFragment('#v=2&a=abcdefghij&e=permission&n=12&r=' + encodeURIComponent('<script>'));
    check('a permission link: r read as the card, kept in the tab\'s fragment; anything else in r is dropped',
        withCard.ok && withCard.f.card === cv.sealed && P.parseFragment(P.alertFragment(withCard.f)).f.card === cv.sealed &&
        junk.ok && junk.f.card === '' && P.alertFragment(junk.f).indexOf('r=') < 0);
}

// An in-memory IndexedDB, as much of one as the page uses: open with an
// upgrade, object stores, get / put / delete in a transaction that completes
// (or aborts) after its requests, every callback on a later turn as a
// browser's are. A value goes in as a structured clone would take it: plain
// data copied, a CryptoKey kept as the object it is (a browser clones one
// with its extractable flag, which is what is checked). dbs outlives a
// reload, as the phone's database does. opt: throwOpen (open itself throws,
// as some private modes do), refuseOpen (open fails), failPut (a write
// aborts, as a full disk does).
const fakeIndexedDb = (dbs, opt) => {
    opt = opt || {};
    const later = (fn) => setTimeout(fn, 0);
    const isCryptoKey = (x) => !!x && typeof x === 'object' && x.constructor && x.constructor.name === 'CryptoKey';
    const clone = (v) => {
        if (!v || typeof v !== 'object' || isCryptoKey(v)) return isCryptoKey(v) ? v : structuredClone(v);
        const out = Array.isArray(v) ? [] : {};
        Object.keys(v).forEach((k) => { out[k] = clone(v[k]); });
        return out;
    };
    const transaction = (db, name, mode) => {
        const st = db.stores.get(name);
        if (!st) throw new Error('NotFoundError');
        const tx = {}, work = [];
        let failed = false;
        const request = (fn) => {
            const r = {};
            work.push(() => {
                try {
                    r.result = fn();
                    if (r.onsuccess) r.onsuccess({});
                } catch (e) {
                    failed = true;
                    r.error = e;
                    if (r.onerror) r.onerror({ preventDefault() { } });
                }
            });
            return r;
        };
        tx.objectStore = (n) => {
            if (n !== name) throw new Error('NotFoundError');
            return {
                get: (k) => request(() => (st.has(k) ? st.get(k) : undefined)),
                put: (v, k) => {
                    if (mode !== 'readwrite') throw new Error('ReadOnlyError');
                    return request(() => { if (opt.failPut) throw new Error('QuotaExceededError'); st.set(k, clone(v)); return k; });
                },
                delete: (k) => {
                    if (mode !== 'readwrite') throw new Error('ReadOnlyError');
                    return request(() => { st.delete(k); });
                }
            };
        };
        later(() => {
            work.forEach((w) => w());
            if (failed) {
                if (tx.onerror) tx.onerror({});
                if (tx.onabort) tx.onabort({});
            } else if (tx.oncomplete) tx.oncomplete({});
        });
        return tx;
    };
    return {
        open(name, version) {
            if (opt.throwOpen) throw new Error('InvalidStateError');
            const req = {};
            later(() => {
                if (opt.refuseOpen) {
                    req.error = new Error('UnknownError');
                    if (req.onerror) req.onerror({ preventDefault() { } });
                    return;
                }
                let db = dbs.get(name);
                if (!db) dbs.set(name, db = { version: 0, stores: new Map() });
                req.result = {
                    objectStoreNames: { contains: (n) => db.stores.has(n) },
                    createObjectStore: (n) => { db.stores.set(n, new Map()); return {}; },
                    transaction: (n, mode) => transaction(db, n, mode),
                    close() { }
                };
                if (db.version < version) {
                    db.version = version;
                    if (req.onupgradeneeded) req.onupgradeneeded({});
                }
                if (req.onsuccess) req.onsuccess({});
            });
            return req;
        }
    };
};

// The page's whole script under a fake DOM: just enough elements, a clock it
// reads, storage that outlives a reload as a tab's and a phone's do (the
// phone's IndexedDB too), and a fetch that records what it was given and
// answers as it is told - or holds its answer until released.
async function driveThePage() {
    const script = (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
    const tags = [...html.matchAll(/<\w+\b([^>]*?)\bid="([^"]+)"([^>]*)>/g)];
    const ids = tags.map((m) => m[2]);
    // what the HTML itself hides until the script shows it
    const hiddenAtFirst = new Set(tags.filter((m) => /\shidden(\s|=|$)/.test(m[1] + ' ' + m[3])).map((m) => m[2]));
    const D = nodeCrypto.randomBytes(32);
    const SERVER = 'https://ntfy.sh', TOPIC = 'chatq-topictopictopictopic12';
    const phoneRec = (d, x) => JSON.stringify(Object.assign({ v: 2, s: SERVER, t: TOPIC, d: b64url(d), at: 1789990000000, h: 'DESKTOP-7' }, x));
    const frag = (x) => '#' + Object.entries(Object.assign({ v: '2', a: 'abcdefgh23', e: 'needs input', n: '12', c: 'Fix the build', p: 'claude', j: 'needs-input' }, x))
        .filter(([, v]) => v !== undefined).map(([n, v]) => n + '=' + encodeURIComponent(v)).join('&');
    const pairFrag = (x) => '#' + Object.entries(Object.assign({ v: '2', m: 'pair', s: SERVER, t: 'chatq-newtopicnewtopicnewtopi', a: 'pairpairpa', n: pv.modulus, x: pv.exponent, h: 'DESKTOP-7' }, x))
        .map(([n, v]) => n + '=' + encodeURIComponent(v)).join('&');
    const realSetTimeout = setTimeout;
    const waitFor = async (ok) => {
        for (let i = 0; i < 400 && !ok(); i++) await new Promise((r) => realSetTimeout(r, 5));
        return ok();
    };
    let clock = 1790000000000;
    class FakeDate extends Date {
        constructor(...a) { if (a.length) super(...a); else super(clock); }
        static now() { return clock; }
    }

    // one run of the page: a fresh document; the tab's sessionStorage and
    // the phone's localStorage kept across runs, as a reload keeps them
    const store = new Map(), local = new Map(), dbs = new Map();
    const storage = (m, opt) => ({
        setItem: (k, v) => { if (opt && opt.refuse) throw new Error('QuotaExceededError'); m.set(k, String(v)); },
        getItem: (k) => (m.has(k) ? m.get(k) : null),
        removeItem: (k) => { m.delete(k); }
    });
    // the phone's record in IndexedDB (db chatq, store phone), or undefined
    const kept = () => {
        const db = dbs.get('chatq');
        const st = db && db.stores.get('phone');
        return st ? st.get('phone') : undefined;
    };
    // Everything the phone and the tab keep, as text, CryptoKeys aside: no
    // form of D may be in it - base64url, base64, hex, or the bytes as a list
    const noRawKey = (d) => {
        d = Buffer.from(d);
        const forms = [b64url(d), d.toString('base64'), d.toString('hex'), Array.from(d).join(',')];
        const texts = [...local.values(), ...store.values()];
        for (const db of dbs.values()) {
            for (const st of db.stores.values()) {
                for (const v of st.values()) {
                    texts.push(JSON.stringify(v, (k, x) => (x && x.constructor && x.constructor.name === 'CryptoKey' ? '[CryptoKey]' :
                        x instanceof Uint8Array || x instanceof ArrayBuffer || Buffer.isBuffer(x) ? Array.from(new Uint8Array(x.buffer || x)).join(',') : x)));
                }
            }
        }
        return texts.every((t) => forms.every((f) => String(t).indexOf(f) < 0));
    };
    // opt: noIdb (no IndexedDB at all), idb (fakeIndexedDb's options),
    // refuseLocal (localStorage throws on a write)
    const load = async (hash, opt) => {
        opt = opt || {};
        const doc = { activeElement: null, title: '', els: {} };
        const el = (id, tag) => {
            const e = {
                id, tagName: (tag || 'div').toUpperCase(), hidden: false, disabled: false, value: '', placeholder: '', type: '',
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
                classList: null,
                focus() { doc.activeElement = this; },
                blur() { if (doc.activeElement === this) doc.activeElement = null; }
            };
            e.classList = { toggle: (c, on) => { if (on === undefined ? !e.cls.has(c) : on) e.cls.add(c); else e.cls.delete(c); }, contains: (c) => e.cls.has(c) };
            return e;
        };
        ids.forEach((id) => {
            doc.els[id] = el(id, id === 'text' ? 'textarea' : ['send', 'again', 'pair'].includes(id) ? 'button' : 'div');
            doc.els[id].hidden = hiddenAtFirst.has(id);
        });
        doc.getElementById = (id) => doc.els[id] || null;
        doc.createElement = (tag) => el('', tag);
        const loc = { hash, pathname: '/VS-code-chat-manager/reply.html', search: '' };
        const hist = { replaceState: (s, t, url) => { loc.hash = url.indexOf('#') >= 0 ? url.slice(url.indexOf('#')) : ''; } };
        const winOn = {};
        const win = { crypto: webcrypto, TextEncoder, addEventListener(t, fn) { (winOn[t] = winOn[t] || []).push(fn); } };
        const posts = [];
        const page = { doc, loc, posts, answer: { ok: true, status: 200 }, release: null };
        const fakeFetch = (url, o) => {
            posts.push({ url, o });
            const a = page.answer;
            if (a.hold) return new Promise((res) => { page.release = (x) => res(x || { ok: true, status: 200 }); });
            return a.throw ? Promise.reject(a.throw) : Promise.resolve(a);
        };
        const idb = opt.noIdb ? undefined : fakeIndexedDb(dbs, opt.idb);
        win.indexedDB = idb;
        const names = ['document', 'window', 'location', 'history', 'sessionStorage', 'localStorage', 'indexedDB', 'navigator', 'fetch', 'crypto', 'TextEncoder',
            'btoa', 'atob', 'URL', 'Date', 'setTimeout', 'clearTimeout', 'AbortController'];
        new Function(...names, script)(doc, win, loc, hist, storage(store), storage(local, { refuse: opt.refuseLocal }), idb, { userAgent: ANDROID_UA },
            fakeFetch, webcrypto, TextEncoder, btoa, atob, URL, FakeDate, () => 0, () => { }, AbortController);
        page.$ = (id) => doc.els[id];
        page.more = () => doc.els.more.kids;
        page.btn = (act) => page.more().find((b) => b.getAttribute('data-act') === act);
        page.go = (h) => { loc.hash = h; (winOn.hashchange || []).forEach((fn) => fn()); };
        page.open = (i) => (posts[i] ? openMessage(posts[i].o.body, alertKeyOf(D, posts[i].o.body.split('.')[1])) : null);
        page.cardKind = () => (doc.els.card.hidden ? null : doc.els.card.getAttribute('data-kind'));
        // the page reads what the phone keeps before it shows anything
        page.ready = await waitFor(() => !doc.els.app.hidden || !doc.els.card.hidden || (doc.els.board && !doc.els.board.hidden));
        // the bare page on a paired phone is the board, which asks for itself
        page.board = () => !!doc.els.board && !doc.els.board.hidden;
        page.openCompose = (i, d) => {
            const m = posts[i] && /^chatq3c\.([a-z2-7]{10})\./.exec(posts[i].o.body);
            return m ? openComposeMessage(posts[i].o.body, hmac(Buffer.from(d), 'chatq-phone:' + m[1])) : null;
        };
        return page;
    };
    if (!script || !ids.includes('text') || !ids.includes('pair')) {
        check('the page: its script and elements found', false);
        return;
    }

    // --- not paired ------------------------------------------------------------
    let pg;
    try {
        pg = await load(frag({ e: 'done' }));
    } catch (e) {
        check('the page loads under a fake DOM', false, e.message);
        return;
    }
    check('the page shows something once it has read what the phone keeps', pg.ready);
    check('not paired, an alert: a card that says exactly what to run on the PC, and no form',
        pg.$('app').hidden && pg.cardKind() === 'unpaired' && pg.$('cardHead').textContent === 'This phone is not paired' &&
        pg.$('cardCode').textContent === 'chatnotify -Pair' && !pg.$('cardCode').hidden && /Pair phone in the setup window/.test(pg.$('cardAfter').textContent) &&
        pg.$('pair').hidden && pg.$('kicker').textContent === '#12 Fix the build - done' && pg.$('cardBig').hidden, pg.$('cardHead').textContent);
    check('not paired: nothing posted', pg.posts.length === 0);
    store.clear();
    const none = await load('');
    check('no link and not paired: the same card', none.cardKind() === 'unpaired' && none.$('kicker').hidden);

    // --- pairing ---------------------------------------------------------------
    const pf = pairFrag({});
    pg = await load(pf);
    check('a pairing link: "Pair this phone with chatq on <h>", what it does, one big Pair button',
        pg.cardKind() === 'pair' && pg.$('cardHead').textContent === 'Pair this phone with chatq on DESKTOP-7' && pg.$('cardBody').textContent.length > 40 &&
        !pg.$('pair').hidden && pg.$('pair').textContent === 'Pair' && pg.$('cardWarn').hidden && pg.posts.length === 0, pg.$('cardHead').textContent);
    check('a pairing link is not kept in the tab\'s storage, and stays in the bar until it is used', !store.has('chatq-reply') && pg.loc.hash === pf);
    pg.answer = { ok: false, status: 503 };
    pg.$('pair').fire('click');
    check('Pair: busy at once', pg.$('pair').disabled && pg.$('pair').textContent === 'Pairing\u2026');
    await waitFor(() => pg.posts.length === 1 && !pg.$('pair').disabled);
    check('a failed pairing POST: said, Try again offered, and NOTHING kept on the phone',
        pg.$('cardStatusText').textContent === 'ntfy.sh answered 503.' && pg.$('pair').textContent === 'Try again' && !local.has('chatq-phone') &&
        kept() === undefined && pg.loc.hash === pf);
    pg.answer = { ok: true, status: 200 };
    pg.$('pair').fire('click');
    await waitFor(() => pg.posts.length === 2 && pg.cardKind() === 'paired');
    const p0 = pg.posts[0] || { o: {} }, p1 = pg.posts[1] || { o: {} };
    check('Pair: to the link\'s server and topic, text/plain alone', p1.url === SERVER + '/chatq-newtopicnewtopicnewtopi' && p1.o.method === 'POST' &&
        JSON.stringify(p1.o.headers) === '{"Content-Type":"text/plain"}' && p1.o.credentials === 'omit', JSON.stringify(p1.url));
    check('Try again sends the very same sealed pairing - the same key - in case the first did arrive', !!p0.o.body && p0.o.body === p1.o.body);
    const po = openPair(p1.o.body);
    // D is what the PC got; the phone itself no longer has it in any form
    const phoneD = po && typeof po.json.d === 'string' ? unb64(po.json.d) : null;
    check('the PC opens it: v 2, a D of 32 bytes, the label, ts', !!po && po.pid === 'pairpairpa' && po.json.v === 2 && !!phoneD && phoneD.length === 32 &&
        po.json.label === 'Android - Chrome 128' && po.json.ts === clock && Buffer.byteLength(po.text) <= 190, po && po.text);
    const rec = kept();
    check('kept in IndexedDB only after the POST went through: chatq / phone = {v: 3, s, t, key, at, h, code}, nothing in localStorage',
        !!rec && Object.keys(rec).join() === 'v,s,t,key,at,h,code' && rec.v === 3 && rec.s === SERVER && rec.t === 'chatq-newtopicnewtopicnewtopi' &&
        rec.h === 'DESKTOP-7' && rec.at === clock && !local.has('chatq-phone'), rec && Object.keys(rec).join());
    const recKey = rec && rec.key;
    const exportRefused = recKey ? await webcrypto.subtle.exportKey('raw', recKey).then(() => false, () => true) : false;
    check('the key kept is a CryptoKey that will not export: HMAC SHA-256, sign only',
        !!recKey && recKey.constructor.name === 'CryptoKey' && recKey.extractable === false && recKey.type === 'secret' && recKey.algorithm.name === 'HMAC' &&
        recKey.algorithm.hash.name === 'SHA-256' && recKey.usages.join() === 'sign' && exportRefused);
    if (recKey && phoneD) {
        const aid = randomAid();
        const fromKept = Buffer.from(new Uint8Array(await webcrypto.subtle.sign('HMAC', recKey, Buffer.from('chatq-alert:' + aid))));
        check('k from the kept key is k from the D the PC got', fromKept.equals(alertKeyOf(phoneD, aid)));
    }
    check('no raw D anywhere the phone or the tab keeps things', !!phoneD && noRawKey(phoneD));
    const code = phoneD ? codeOf(phoneD) : '';
    check('the code after the POST: big, "123 456", the code of the D the PC got, and kept with the key',
        pg.$('cardHead').textContent === 'On the PC, confirm this code' && !pg.$('cardBig').hidden && pg.$('cardBig').textContent === code.slice(0, 3) + ' ' + code.slice(3) &&
        !!rec && rec.code === code && pg.$('kicker').textContent === 'chatq on DESKTOP-7', pg.$('cardBig').textContent + ' / ' + code);
    check('paired once the PC confirms the code: said so, nothing to press, and the pairing link gone from the bar',
        pg.$('cardStatusText').textContent === 'Sent - paired once the PC confirms the code.' && pg.$('cardStatus').getAttribute('data-kind') === 'ok' &&
        /Confirm the one with this code/.test(pg.$('cardBody').textContent) && pg.$('cardWarn').hidden && pg.$('pair').hidden && pg.loc.hash === '');
    const sameAgain = await load(pf);
    check('the same pairing link again: already used, nothing to press (a second send would break the pairing), the code shown again',
        sameAgain.cardKind() === 'same' && sameAgain.$('pair').hidden && sameAgain.$('cardHead').textContent === 'This pairing alert is already used' &&
        sameAgain.$('cardBig').textContent === code.slice(0, 3) + ' ' + code.slice(3) && sameAgain.posts.length === 0);
    const home = await load('');
    await waitFor(() => home.posts.length === 1);
    const ho = phoneD ? home.openCompose(0, phoneD) : null;
    check('paired, and no link: the board - "chatq on <host>", and it asks the PC for itself, sealed with the kept key', home.board() && home.cardKind() === null &&
        /chatq on DESKTOP-7/.test(home.$('bHost').textContent) && !!ho && ho.json.act === 'board' && home.posts[0].url === SERVER + '/chatq-newtopicnewtopicnewtopi' &&
        home.$('bNote').hidden, home.$('bHost').textContent + ' / ' + (ho && ho.text));
    // an alert link now opens the form, the key derived from what was kept
    if (phoneD) {
        const a = await load(frag({ e: 'done', n: '3', c: 'paired now' }));
        a.$('text').value = 'hello';
        a.$('text').fire('input');
        a.$('send').fire('click');
        await waitFor(() => a.posts.length === 1 && a.$('status').getAttribute('data-kind') === 'ok');
        const ao = a.posts[0] ? openMessage(a.posts[0].o.body, alertKeyOf(phoneD, 'abcdefgh23')) : null;
        check('after pairing, an alert\'s reply is sealed with the kept key, to the paired topic',
            !!ao && ao.json.text === 'hello' && a.posts[0].url === SERVER + '/chatq-newtopicnewtopicnewtopi');
    }

    // --- a new pairing link on a paired phone ----------------------------------
    const otherFrag = pairFrag({ t: 'chatq-othertopicothertopicothe', a: 'otherpairp', h: 'LAPTOP' });
    const other = await load(otherFrag);
    const ow = other.$('cardWarn').textContent;
    check('the replace card: only if you just pressed Pair phone, where replies would go (host and topic start), the pairing it ends',
        other.cardKind() === 'replace' && !other.$('cardWarn').hidden && /^Only continue if you just pressed Pair phone on your PC\./.test(ow) &&
        ow.indexOf('ntfy.sh, topic chatq-othert\u2026') >= 0 && /the pairing with chatq on DESKTOP-7 ends/.test(ow) &&
        !other.$('pair').hidden && other.$('pair').textContent === 'Replace pairing' && other.$('cardHead').textContent === 'Pair this phone with chatq on LAPTOP', ow);
    other.$('pair').fire('click');
    check('Replace pairing: the first tap only asks', other.posts.length === 0 && other.$('pair').textContent === 'Tap again to replace' &&
        other.$('pair').getAttribute('data-armed') === '1' && !other.$('pair').disabled);
    clock += 120;
    other.$('pair').fire('click');
    await new Promise((r) => realSetTimeout(r, 20));
    check('Replace pairing: a second tap 120 ms later does nothing, still asking', other.posts.length === 0 && other.$('pair').getAttribute('data-armed') === '1');
    clock += 500;
    other.$('pair').fire('click');
    await waitFor(() => other.posts.length === 1 && other.cardKind() === 'paired');
    const oo = other.posts[0] ? openPair(other.posts[0].o.body) : null;
    const otherD = oo ? unb64(oo.json.d) : null;
    const rec2 = kept();
    check('a second tap past 500 ms replaces it: to the new topic, a new D, the record in IndexedDB the new one',
        !!otherD && other.posts[0].url === SERVER + '/chatq-othertopicothertopicothe' && !otherD.equals(phoneD || Buffer.alloc(0)) && !!rec2 &&
        rec2.t === 'chatq-othertopicothertopicothe' && rec2.h === 'LAPTOP' && rec2.code === codeOf(otherD) && rec2.key.extractable === false &&
        other.$('cardBig').textContent === codeOf(otherD).slice(0, 3) + ' ' + codeOf(otherD).slice(3) && noRawKey(otherD) && !local.has('chatq-phone'));

    // --- no IndexedDB: the v2 way, said -----------------------------------------
    dbs.clear();
    local.clear();
    for (const [what, opt] of [['no IndexedDB at all', { noIdb: true }], ['an IndexedDB that throws on open', { idb: { throwOpen: true } }],
        ['one that refuses to open', { idb: { refuseOpen: true } }], ['one that will not take the write', { idb: { failPut: true } }]]) {
        dbs.clear();
        local.clear();
        const fb = await load(pf, opt);
        fb.$('pair').fire('click');
        await waitFor(() => fb.posts.length === 1 && fb.cardKind() === 'paired');
        const fo = fb.posts[0] ? openPair(fb.posts[0].o.body) : null;
        const fd = fo ? unb64(fo.json.d) : null;
        const v2 = P.parsePhone(local.get('chatq-phone'));
        check(what + ': paired, the key in localStorage as v2 did, and the page says it is readable',
            !!fd && !!v2 && Buffer.from(v2.d).equals(fd) && kept() === undefined && fb.$('cardWarn').textContent === P.READABLE &&
            /keeps the key readable to this site's pages/.test(fb.$('cardWarn').textContent) &&
            fb.$('cardBig').textContent === codeOf(fd).slice(0, 3) + ' ' + codeOf(fd).slice(3), fb.$('cardWarn').textContent);
        if (what === 'no IndexedDB at all' && fd) {
            const fr = await load(frag({ e: 'done', a: 'fallbackaa' }), opt);
            fr.$('text').value = 'from the fallback';
            fr.$('text').fire('input');
            fr.$('send').fire('click');
            await waitFor(() => fr.posts.length === 1 && fr.$('status').getAttribute('data-kind') === 'ok');
            const fro = fr.posts[0] ? openMessage(fr.posts[0].o.body, alertKeyOf(fd, 'fallbackaa')) : null;
            check('no IndexedDB: a reply sealed with the key from localStorage, and the record left where it is',
                !!fro && fro.json.text === 'from the fallback' && local.has('chatq-phone'));
            store.clear();
            const fh = await load('', opt);
            check('no IndexedDB: the board says the key is readable', fh.board() && fh.$('bNote').textContent.indexOf(P.READABLE) >= 0);
        }
    }
    dbs.clear();
    local.clear();
    const refused = await load(pf, { refuseLocal: true, noIdb: true });
    refused.$('pair').fire('click');
    await waitFor(() => refused.cardKind() === 'storage');
    check('a browser that will keep the key nowhere: said so before anything is sent', refused.cardKind() === 'storage' && refused.posts.length === 0);

    // --- a v2 phone: moved into IndexedDB once --------------------------------------
    dbs.clear();
    local.clear();
    local.set('chatq-phone', phoneRec(D));
    const stay = await load('', { noIdb: true });
    await waitFor(() => stay.posts.length === 1);
    const so = stay.openCompose(0, D);
    check('a v2 record where there is no IndexedDB: used where it is - the board asks with it - and said to be readable',
        stay.board() && local.has('chatq-phone') && stay.$('bNote').textContent.indexOf(P.READABLE) >= 0 && !!so && so.json.act === 'board');
    const failMove = await load('', { idb: { failPut: true } });
    check('a v2 record IndexedDB will not take: kept in localStorage, still used', failMove.board() && local.has('chatq-phone') && kept() === undefined);
    // an older v3 pairing in IndexedDB loses to the v2 record: that one is newer
    {
        const oldKey = await webcrypto.subtle.importKey('raw', nodeCrypto.randomBytes(32), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        dbs.set('chatq', { version: 1, stores: new Map([['phone', new Map([['phone', { v: 3, s: SERVER, t: 'chatq-olderolderolderolderolde', key: oldKey, at: 1, h: 'OLD', code: '000000' }]])]]) });
    }
    store.clear();
    const smuggle = frag({ k: b64url(nodeCrypto.randomBytes(32)), s: 'https://evil.example', t: 'evil-topic' });
    pg = await load(smuggle);
    const mig = kept();
    check('a v2 record in localStorage: moved into IndexedDB as a key that will not export, over an older pairing there, and removed from localStorage',
        !local.has('chatq-phone') && !!mig && mig.v === 3 && mig.t === TOPIC && mig.h === 'DESKTOP-7' && mig.at === 1789990000000 &&
        mig.key.extractable === false && mig.code === codeOf(D) && noRawKey(D), mig && JSON.stringify(Object.assign({}, mig, { key: undefined })));
    if (mig) {
        const aid = randomAid();
        check('the moved key gives the k the raw D gave',
            Buffer.from(new Uint8Array(await webcrypto.subtle.sign('HMAC', mig.key, Buffer.from('chatq-alert:' + aid)))).equals(alertKeyOf(D, aid)));
    }
    const $ = pg.$;
    check('the form: shown, no card', !$('app').hidden && $('card').hidden);
    check('the alert kept for this tab - its own fields only, no k, s or t - and taken out of the bar',
        store.get('chatq-reply') === P.alertFragment(P.parseFragment(frag({})).f) && pg.loc.hash === '', store.get('chatq-reply'));
    check('"#12 Fix the build", the event, and the provider', $('title').textContent === '#12 Fix the build' &&
        $('ev').textContent === 'needs input' && $('ev').getAttribute('data-ev') === 'needs input' && $('meta').textContent === 'claude');
    check('the box has the focus, Send is off while it is empty',
        pg.doc.activeElement === $('text') && $('send').disabled && $('send').textContent === 'Send' && !$('compose').hidden);
    check('the small buttons, in order', pg.more().map((b) => b.textContent).join('|') === 'Allow edits & continue|Continue|Skip|Status');
    $('text').value = '  yes ' + HANGUL + '\n';
    $('text').fire('input');
    check('typing turns Send on and counts the bytes', !$('send').disabled && $('count').textContent === P.counter('yes ' + HANGUL).label &&
        $('count').getAttribute('data-state') === 'ok');
    $('send').fire('click');
    check('Send: busy at once, every button off', $('send').disabled && $('send').textContent === 'Sending\u2026' && pg.more().every((b) => b.disabled));
    await waitFor(() => pg.posts.length === 1 && $('status').getAttribute('data-kind') === 'ok');
    const q1 = pg.posts[0] || { o: {} };
    const o1 = pg.open(0);
    check('Send: one POST to the PAIRED server/topic - not the link\'s - text/plain alone, no cookie, no referrer',
        pg.posts.length === 1 && q1.url === SERVER + '/' + TOPIC && q1.o.method === 'POST' &&
        JSON.stringify(q1.o.headers) === '{"Content-Type":"text/plain"}' && q1.o.credentials === 'omit' && q1.o.referrerPolicy === 'no-referrer',
        JSON.stringify(q1.url));
    check('Send: the watcher opens it with the key derived from the phone\'s - the text trimmed, the alert\'s aid',
        !!o1 && o1.json.act === 'prompt' && o1.json.text === 'yes ' + HANGUL && o1.aid === 'abcdefgh23', o1 && o1.text);
    check('sent: said so, the text kept but greyed, and Send again offered', $('statusText').textContent === P.sentText({ act: 'prompt' }) &&
        $('text').cls.has('sent') && $('send').textContent === 'Send again' && !$('send').disabled && $('log').kids.length === 1);
    check('and the draft for this alert cleared', !store.has('chatq-draft:abcdefgh23'));
    $('send').fire('click');
    await waitFor(() => pg.posts.length === 2 && !$('send').disabled);
    const o2 = pg.open(1);
    check('Send again: a new message, a new nonce', !!o2 && o2.json.text === 'yes ' + HANGUL && o2.json.nonce !== o1.json.nonce && $('log').kids.length === 2);
    $('text').value = 'something else';
    $('text').fire('input');
    check('an edited text is no longer greyed, and the button says Send, not Send again', !$('text').cls.has('sent') && $('send').textContent === 'Send');

    pg.answer = { ok: false, status: 503 };
    pg.btn('status').fire('click');
    await waitFor(() => pg.posts.length === 3 && $('status').getAttribute('data-kind') === 'bad');
    check('an error: said, and Try again offered', $('statusText').textContent === 'ntfy.sh answered 503.' && !$('again').hidden &&
        !pg.btn('status').disabled && pg.btn('status').textContent === 'Status');
    pg.answer = { ok: true, status: 200 };
    $('again').fire('click');
    await waitFor(() => pg.posts.length === 4 && $('status').getAttribute('data-kind') === 'ok');
    const o3 = pg.open(2);
    check('Try again posts the very same message, so the watcher\'s replay guard drops a copy that did get through',
        pg.posts.length === 4 && pg.posts[3].o.body === pg.posts[2].o.body && !!o3 && o3.json.act === 'status' && o3.json.text === '' &&
        $('statusText').textContent === 'Sent "Status". The PC answers with a push.' && $('again').hidden);
    pg.answer = { throw: new TypeError('Failed to fetch') };
    pg.btn('retry').fire('click');
    await waitFor(() => pg.posts.length === 5 && $('status').getAttribute('data-kind') === 'bad');
    check('no network: said, in plain words', $('statusText').textContent === 'Could not reach ntfy.sh - check the connection.');
    pg.btn('retry').fire('click');
    await waitFor(() => pg.posts.length === 6 && $('status').getAttribute('data-kind') === 'bad');
    check('pressing Continue again after it failed re-posts the same message too', pg.posts[5].o.body === pg.posts[4].o.body);

    // Send after a failed send: the big button, the same sealed message
    $('text').value = 'ship it';
    $('text').fire('input');
    $('send').fire('click');
    await waitFor(() => pg.posts.length === 7 && $('status').getAttribute('data-kind') === 'bad');
    check('a failed prompt: Send turns into Try again while the text is unchanged', $('send').textContent === 'Try again' && !$('send').disabled);
    const draft = JSON.parse(store.get('chatq-draft:abcdefgh23') || 'null');
    check('the draft keeps the text and the sealed message, not known to have arrived', !!draft && draft.text === 'ship it' &&
        draft.sealed && draft.sealed.message === pg.posts[6].o.body);
    // the tab reloads: the box comes back, and so does Try again
    const re = await load('');
    check('a reload: the text back in the box, Send says Try again, and why', re.$('text').value === 'ship it' && re.$('send').textContent === 'Try again' &&
        !re.$('again').hidden && /very same message/.test(re.$('statusText').textContent));
    re.$('send').fire('click');
    await waitFor(() => re.posts.length === 1 && re.$('status').getAttribute('data-kind') === 'ok');
    check('Send after a failure re-posts the same sealed message - no new nonce to get past the replay guard',
        re.posts.length === 1 && re.posts[0].o.body === pg.posts[6].o.body && !store.has('chatq-draft:abcdefgh23'));
    re.answer = { ok: false, status: 500 };
    re.$('text').value = 'ship it now';
    re.$('text').fire('input');
    re.$('send').fire('click');
    await waitFor(() => re.posts.length === 2 && re.$('status').getAttribute('data-kind') === 'bad');
    re.$('text').value = 'ship it, now';
    re.$('text').fire('input');
    check('editing the text drops the failed message: Send, Try again hidden', re.$('send').textContent === 'Send' && re.$('again').hidden);
    re.answer = { ok: true, status: 200 };
    re.$('send').fire('click');
    await waitFor(() => re.posts.length === 3 && re.$('status').getAttribute('data-kind') === 'ok');
    const ro = re.open(2);
    check('and the new text goes as a new message', !!ro && ro.json.text === 'ship it, now' && re.posts[2].o.body !== re.posts[1].o.body);

    // drafts, one per alert
    store.clear();
    const da = await load(frag({ a: 'draftaaaaa', c: 'A' }));
    da.$('text').value = 'for A';
    da.$('text').fire('input');
    const dbp = await load(frag({ a: 'draftbbbbb', c: 'B' }));
    check('a draft is per alert: another alert\'s box starts empty', dbp.$('text').value === '');
    dbp.$('text').value = 'for B';
    dbp.$('text').fire('input');
    const da2 = await load(frag({ a: 'draftaaaaa', c: 'A' }));
    check('and coming back to the first brings its text back', da2.$('text').value === 'for A' && !da2.$('text').cls.has('sent'));
    check('no key and no topic anywhere in the tab\'s storage', [...store.values()].every((v) => v.indexOf(b64url(D)) < 0 && v.indexOf(TOPIC) < 0));

    // Skip: two taps, the second a deliberate one
    pg = await load(frag({}));
    pg.btn('skip').fire('click');
    check('Skip: the first tap only asks', pg.posts.length === 0 && pg.btn('skip').textContent === 'Tap again to skip' && pg.btn('skip').getAttribute('data-armed') === '1');
    clock += 120;
    pg.btn('skip').fire('click');
    await new Promise((r) => realSetTimeout(r, 20));
    check('Skip: a second tap 120 ms later (a double tap, a bounce) does nothing, still asking', pg.posts.length === 0 && pg.btn('skip').getAttribute('data-armed') === '1');
    clock += 500;
    pg.btn('skip').fire('click');
    await waitFor(() => pg.posts.length === 1 && !pg.btn('skip').disabled);
    const o4 = pg.open(0);
    check('Skip: a second tap past 500 ms sends it', !!o4 && o4.json.act === 'skip' && pg.btn('skip').textContent === 'Skip' && pg.btn('skip').getAttribute('data-armed') === null);

    // a new link while a POST is out
    pg = await load(frag({ c: 'first' }));
    pg.answer = { hold: true };
    pg.$('text').value = 'mid-flight';
    pg.$('text').fire('input');
    pg.$('send').fire('click');
    await waitFor(() => pg.posts.length === 1 && !!pg.release);
    pg.go(frag({ a: 'secondaaaa', c: 'second', e: 'done' }));
    await new Promise((r) => realSetTimeout(r, 20));
    check('a new link while a POST is out: the send is left alone - still busy, the same alert, the text still there',
        pg.$('send').disabled && pg.$('send').textContent === 'Sending\u2026' && pg.$('title').textContent === '#12 first' && pg.$('text').value === 'mid-flight');
    pg.release({ ok: true, status: 200 });
    await waitFor(() => pg.$('title').textContent === '#12 second');
    const o5 = pg.open(0);
    check('once it settles: it went as the first alert\'s, and then the new link opens',
        !!o5 && o5.aid === 'abcdefgh23' && o5.json.text === 'mid-flight' && pg.$('title').textContent === '#12 second' &&
        pg.$('ev').textContent === 'done' && pg.$('text').value === '' && !store.has('chatq-draft:abcdefgh23'));
    pg.go(frag({ a: 'thirdaaaaa', c: 'third' }));
    check('a new link with nothing out: opens at once', await waitFor(() => pg.$('title').textContent === '#12 third'));
    // two links close together: the later one wins, whichever read of the
    // phone's storage comes back first
    pg.go(frag({ a: 'fourthaaaa', c: 'fourth' }));
    pg.go(frag({ a: 'fifthaaaaa', c: 'fifth' }));
    await waitFor(() => pg.$('title').textContent === '#12 fifth');
    await new Promise((r) => realSetTimeout(r, 30));
    check('two new links at once: the later one shows', pg.$('title').textContent === '#12 fifth');

    // the other kinds of alert
    const cut = await load(frag({}).slice(0, 12));
    check('a link cut short: said so, nothing offered', cut.$('app').hidden && cut.cardKind() === 'bad' && cut.$('cardHead').textContent === 'This link is incomplete' && cut.$('pair').hidden);
    const v1 = await load('#v=1&s=https%3A%2F%2Fntfy.sh&t=chatq-x&a=abcdefgh23&k=' + b64url(nodeCrypto.randomBytes(32)) + '&e=done');
    check('a v1 link (a key in it): from before pairing, what to run, and out of the bar, never kept',
        v1.cardKind() === 'old' && v1.$('cardCode').textContent === 'chatnotify -Pair' && v1.loc.hash === '' && ![...store.values()].some((v) => /k=/.test(v)));
    const test = await load(frag({ e: 'test', n: '', c: '', p: '', j: '', x: '1' }));
    check('a test alert: no box, one big Send a test reply', test.$('compose').hidden && test.more().length === 0 && test.$('more').hidden &&
        test.$('send').textContent === 'Send a test reply' && !test.$('send').disabled && test.$('title').textContent === 'chatq test');
    test.$('send').fire('click');
    await waitFor(() => test.posts.length === 1 && test.$('status').getAttribute('data-kind') === 'ok');
    const o6 = test.open(0);
    check('and it sends a ping', !!o6 && o6.json.act === 'ping' && o6.json.text === '' && test.$('statusText').textContent === 'Test reply sent. The PC answers with a push.');
    const jl = await load(frag({ e: 'reply', n: '', c: '', p: '', j: '', x: '1' }));
    check('an alert about no chat (x=1): no prompt box, Status big, a test reply small',
        jl.$('compose').hidden && jl.$('send').textContent === 'Status' && jl.more().map((b) => b.getAttribute('data-act')).join() === 'ping' && !jl.$('about').hidden);
    jl.$('send').fire('click');
    await waitFor(() => jl.posts.length === 1 && jl.$('status').getAttribute('data-kind') === 'ok');
    const o7 = jl.open(0);
    check('and Status sends a status', !!o7 && o7.json.act === 'status');
    const started = await load(frag({ e: 'started', j: 'running' }));
    check('a started alert: Stop and Status, the box says when it runs, the job state shown',
        started.more().map((b) => b.getAttribute('data-act')).join() === 'stop,status' && /this run finishes/.test(started.$('hint').textContent) &&
        started.$('meta').textContent === 'claude \u00b7 job running');
    const liveNi = await load(frag({ e: 'needs input', j: 'live' }));
    check('a chat run in VS Code (j=live), needing input: the box, Send big, Status alone small, the answered-at-the-PC hint and "a chat you run"',
        !liveNi.$('compose').hidden && liveNi.$('send').textContent === 'Send' && liveNi.more().map((b) => b.getAttribute('data-act')).join() === 'status' &&
        /once its prompt is answered at the PC/.test(liveNi.$('hint').textContent) && !/answer it/i.test(liveNi.$('text').placeholder) &&
        liveNi.$('meta').textContent === 'claude \u00b7 a chat you run',
        liveNi.more().map((b) => b.getAttribute('data-act')).join() + ' | ' + liveNi.$('hint').textContent + ' | ' + liveNi.$('meta').textContent);
    const liveDone = await load(frag({ e: 'done', j: 'live' }));
    check('j=live done: the hint says it goes when the chat is idle', /goes into this chat when it is idle/.test(liveDone.$('hint').textContent), liveDone.$('hint').textContent);
    const long = await load(frag({ e: 'done', a: 'longlonglo' }));
    long.$('text').value = HANGUL[0].repeat(1000);
    long.$('text').fire('input');
    check('too long: the counter says by how much and Send stays off', long.$('count').getAttribute('data-state') === 'over' && long.$('send').disabled);
    long.$('send').fire('click');
    await new Promise((r) => realSetTimeout(r, 30));
    check('and a press sends nothing', long.posts.length === 0);

    // text= from outside the page (a Tasker reply): into the box, never sent
    store.clear();
    const pre = await load(frag({ e: 'done', a: 'prefillaaa', c: 'Tasker', text: 'from tasker ' + HANGUL }));
    await new Promise((r) => realSetTimeout(r, 30));
    const preDraft = JSON.parse(store.get('chatq-draft:prefillaaa') || 'null');
    check('text= fills the box, says so, counts it and turns Send on - and sends nothing',
        pre.$('text').value === 'from tasker ' + HANGUL && !pre.$('prefill').hidden && pre.$('prefill').textContent === P.PREFILL_NOTE &&
        pre.$('count').textContent === P.counter('from tasker ' + HANGUL).label && !pre.$('send').disabled && pre.posts.length === 0 &&
        pre.doc.activeElement === pre.$('text'), pre.$('text').value + ' | ' + pre.$('prefill').textContent);
    check('text= leaves the bar at once, the tab keeps the alert without it, and the draft holds it',
        pre.loc.hash === '' && !/text/.test(store.get('chatq-reply') || '') && !!preDraft && preDraft.text === 'from tasker ' + HANGUL, store.get('chatq-reply'));
    const preRe = await load('');
    check('a reload: the text still in the box, from the draft, no note, nothing sent',
        preRe.$('text').value === 'from tasker ' + HANGUL && preRe.$('prefill').hidden && preRe.posts.length === 0);
    preRe.$('text').value = 'typed here';
    preRe.$('text').fire('input');
    const preOver = await load(frag({ e: 'done', a: 'prefillaaa', c: 'Tasker', text: 'second reply' }));
    check('a second text= for the same alert replaces what was typed, and the note says so',
        preOver.$('text').value === 'second reply' && /It replaced what was typed here before\.$/.test(preOver.$('prefill').textContent) && preOver.posts.length === 0,
        preOver.$('prefill').textContent);
    preOver.$('send').fire('click');
    await waitFor(() => preOver.posts.length === 1 && preOver.$('status').getAttribute('data-kind') === 'ok');
    const preSent = preOver.open(0);
    check('and it goes only on the tap on Send, as a prompt', !!preSent && preSent.json.act === 'prompt' && preSent.json.text === 'second reply');
    const preTest = await load(frag({ e: 'test', n: '', c: '', p: '', j: '', x: '1', a: 'prefilltst', text: 'ignored' }));
    check('text= on a test alert: no box, the text dropped, the note says so, nothing sent',
        preTest.$('compose').hidden && !preTest.$('prefill').hidden && /takes no text/.test(preTest.$('prefill').textContent) && preTest.posts.length === 0 &&
        !store.has('chatq-draft:prefilltst'));
    const preBad = await load(frag({ e: 'done', a: 'prefillbad' }) + '&text=%E0%A4');
    check('text= with a broken escape: the alert opens, the box empty, no note', !preBad.$('app').hidden && preBad.$('text').value === '' && preBad.$('prefill').hidden);
    const preUsage = await load(frag({ e: 'usage', n: '', c: '', p: '', j: '', x: '1', w: '1', a: 'usagewakea' }));
    check('a usage alert with w=1: Send now big, Status small, no box', preUsage.$('compose').hidden && preUsage.$('send').textContent === 'Send now' &&
        preUsage.more().map((b) => b.getAttribute('data-act')).join() === 'status');
    preUsage.$('send').fire('click');
    await waitFor(() => preUsage.posts.length === 1 && preUsage.$('status').getAttribute('data-kind') === 'ok');
    const preWake = preUsage.open(0);
    check('and Send now sends act wake', !!preWake && preWake.json.act === 'wake' && preWake.json.text === '');
    dbs.clear();
    local.set('chatq-phone', '{"v":2,"s":"http://ntfy.sh"}');
    const broken = await load(frag({}));
    check('a kept v2 record that is not whole: treated as not paired', broken.cardKind() === 'unpaired');
    local.clear();
    const openKey = await webcrypto.subtle.importKey('raw', D, { name: 'HMAC', hash: 'SHA-256' }, true, ['sign']);
    dbs.set('chatq', { version: 1, stores: new Map([['phone', new Map([['phone', { v: 3, s: SERVER, t: TOPIC, key: openKey, at: 1, h: 'X', code: '123456' }]])]]) });
    const exportable = await load(frag({}));
    check('a kept v3 record whose key would export: treated as not paired', exportable.cardKind() === 'unpaired');

    // --- a permission request ------------------------------------------------------
    // the phone paired with D again; its card sealed for D by Node, as the PC seals it
    dbs.clear();
    local.clear();
    store.clear();
    local.set('chatq-phone', phoneRec(D));
    const pcard = { v: 1, t: 'Bash', w: 'git push origin main', d: 'Push the release', f: 'parser', c: 'Parser rewrite ' + HANGUL, n: 12, h: 'hhhhhhhhhhhhhhhhhhhhhh', u: clock + 12 * 60000 };
    const pfrag = (x, c) => frag(Object.assign({ a: 'permitaaaa', e: 'permission', j: 'running', r: sealCard(D, (x && x.a) || 'permitaaaa', c || pcard) }, x));
    const pp = await load(pfrag({}));
    check('a permission request: "Allow this once?", the chat, the call from the card, the tool and folder, Claude\'s words, the time left and the fine print',
        !pp.$('app').hidden && !pp.$('permit').hidden && pp.$('ev').textContent === 'permission' && pp.$('title').textContent === 'Allow this once?' &&
        pp.$('meta').textContent === '#12 Parser rewrite ' + HANGUL && pp.$('permitWhat').textContent === 'git push origin main' &&
        pp.$('permitWhere').textContent === 'Bash \u00b7 in parser' && pp.$('permitDetail').textContent === 'Claude: Push the release' &&
        /^answer by \d\d:\d\d - 12 min left$/.test(pp.$('permitLeft').textContent) && pp.$('permitBody').hidden &&
        pp.$('permitFine').textContent === 'Allow runs this one call. It changes nothing else the run may do.', pp.$('title').textContent + ' | ' + pp.$('meta').textContent);
    check('Allow once is the big button, on with the box empty; Deny and Status small; the box for a note',
        pp.$('send').textContent === 'Allow once' && !pp.$('send').disabled && pp.more().map((b) => b.textContent).join('|') === 'Deny|Status' &&
        !pp.$('compose').hidden && pp.$('text').placeholder === 'A note for Claude, with Deny (optional)');
    pp.$('send').fire('click');
    check('Allow: the first tap only asks', pp.posts.length === 0 && pp.$('send').textContent === 'Tap again to allow' && pp.$('send').getAttribute('data-armed') === '1');
    pp.$('text').value = 'x';
    pp.$('text').fire('input');
    pp.$('text').value = '';
    pp.$('text').fire('input');
    check('Allow: typing meanwhile does not take the question back', pp.$('send').textContent === 'Tap again to allow');
    clock += 120;
    pp.$('send').fire('click');
    await new Promise((r) => realSetTimeout(r, 20));
    check('Allow: a second tap 120 ms later does nothing', pp.posts.length === 0 && pp.$('send').getAttribute('data-armed') === '1');
    clock += 500;
    pp.$('send').fire('click');
    await waitFor(() => pp.posts.length === 1 && pp.$('status').getAttribute('data-kind') === 'ok');
    const po1 = pp.open(0);
    check('Allow: a second tap past 500 ms sends a permit naming the card\'s h, no text, to the paired topic',
        !!po1 && po1.json.act === 'permit' && po1.json.h === pcard.h && po1.json.text === '' && po1.aid === 'permitaaaa' && pp.posts[0].url === SERVER + '/' + TOPIC &&
        pp.$('statusText').textContent === 'Sent - the PC reads it within about 5 s.', po1 && po1.text);
    const pd = await load(pfrag({}));
    pd.$('text').value = 'not on main ' + HANGUL;
    pd.$('text').fire('input');
    pd.btn('refuse').fire('click');
    await waitFor(() => pd.posts.length === 1 && pd.$('status').getAttribute('data-kind') === 'ok');
    const po2 = pd.open(0);
    check('Deny: one tap, the note along, no h', !!po2 && po2.json.act === 'refuse' && po2.json.text === 'not on main ' + HANGUL && !('h' in po2.json), po2 && po2.text);
    const pn = await load(pfrag({ a: 'permitbbbb' }));
    check('a note is kept per alert: another request\'s box starts empty', pn.$('text').value === '');
    const pback = await load(pfrag({}));
    check('and the first one\'s note is back', pback.$('text').value === 'not on main ' + HANGUL);
    const plate = await load(pfrag({ a: 'permitcccc' }, Object.assign({}, pcard, { u: clock - 60000 })));
    check('past its deadline: "Too late", when the run went on, Status alone - no Allow, no box',
        plate.$('title').textContent === 'Too late' && /^At \d\d:\d\d the run went on without it\.$/.test(plate.$('permitBody').textContent) &&
        plate.$('send').textContent === 'Status' && plate.more().length === 0 && plate.$('compose').hidden && plate.$('permitWhat').hidden);
    const noCard = await load(frag({ a: 'permitdddd', e: 'permission', j: 'running' }));
    const otherKey = await load(pfrag({ a: 'permiteeee' }).replace(/r=[^&]*/, 'r=' + encodeURIComponent(sealCard(nodeCrypto.randomBytes(32), 'permiteeee', pcard))));
    const noAllow = (pg) => [pg.$('send')].concat(pg.more()).every((b) => b.getAttribute('data-act') !== 'permit');
    check('no card, or one sealed for another key: "Nothing to approve here", Deny and Status, and no Allow anywhere',
        [noCard, otherKey].every((pg) => pg.$('title').textContent === 'Nothing to approve here' && /sealed for another key/.test(pg.$('permitBody').textContent) &&
            pg.$('send').getAttribute('data-act') === 'refuse' && pg.more().map((b) => b.getAttribute('data-act')).join() === 'status' && noAllow(pg) && pg.$('permitWhat').hidden),
        noCard.$('title').textContent + ' / ' + otherKey.$('title').textContent);
}
