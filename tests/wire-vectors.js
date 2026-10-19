// What docs/reply.html itself makes of the wire vector's inputs, for
// tests/vectors/wire.ps1 (native/SPEC.md 2.8): its crypto and board blocks
// lifted out as tests/board-page-check.js lifts them, run under Node's
// webcrypto, with every key, iv, nonce and time given - nothing random. The
// generator holds PowerShell's answers to these, so a message the page seals
// is one the watcher opens, and chatqd is held to the same file.
//
//     node tests/wire-vectors.js <file holding a JSON list of requests>
//
// A file, not the command line, which a long list would outgrow. Each request
// is {op, ...}; the answer is a JSON list, one result each, in order, written
// as ASCII (anything else as a \u escape) so that Windows PowerShell 5.1 reads
// it the same whatever its code page:
//   reply    {key, aid, act, text, iv, nonce, ts, h?}  ChatqCrypto.seal
//   answer   {key, aid, x, iv, nonce, ts}              ChatqCrypto.sealAnswer
//   payload  {key, aid, payload, iv}                   ChatqCrypto.sealPayload, chatq1
//   compose  {key, act, x, cid, iv, nonce, ts}         ChatqBoard.compose
//   composed {key, cid, payload, iv}                   ChatqBoard.sealCompose
//   keys     {d, label, id}                            k, then ChatqCrypto.deriveKeys
//   code     {d}                                       ChatqCrypto.confirmCode
//   b64      {hex}                                     ChatqCrypto.b64url
//   unb64    {text}                                    ChatqCrypto.unb64url
// key is the phone's key D as base64url, d and iv are hex; a sealed result is
// {message, payload}, bytes come back as hex, and null stays null.
const fs = require('fs');
const path = require('path');
const nodeCrypto = require('crypto');
const { markedBlock } = require(path.join(__dirname, 'page-kit.js'));
const webcrypto = globalThis.crypto || nodeCrypto.webcrypto;

const html = fs.readFileSync(path.join(__dirname, '..', 'docs', 'reply.html'), 'utf8');
const blocks = ['crypto', 'logic', 'board'].map((n) => {
    const b = markedBlock(html, n);
    if (b === null) throw new Error('docs/reply.html: no chatq-' + n + ' block');
    return b;
});
const page = new Function('crypto', 'TextEncoder', 'btoa', 'atob', 'URL',
    blocks.join('\n') + '\nreturn { C: ChatqCrypto, B: ChatqBoard };')(webcrypto, TextEncoder, btoa, atob, URL);
const C = page.C, B = page.B;

const fromHex = (h) => Uint8Array.from(Buffer.from(String(h), 'hex'));
const toHex = (b) => (b === null || b === undefined ? null : Buffer.from(b).toString('hex'));
const keyOf = (k) => {
    const d = C.unb64url(k);
    if (!d) throw new Error('not a base64url key: ' + k);
    return d;
};
const ascii = (o) => JSON.stringify(o).replace(/[^\x00-\x7f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));

const one = async (r) => {
    switch (r.op) {
        case 'reply': {
            const d = keyOf(r.key);
            const s = await C.seal(await C.alertKey(d, r.aid), r.aid, r.act, r.text, { iv: fromHex(r.iv), nonce: r.nonce, ts: r.ts }, r.h);
            return { message: s.message, payload: s.payload };
        }
        case 'answer': {
            const d = keyOf(r.key);
            const s = await C.sealAnswer(await C.alertKey(d, r.aid), r.aid, r.x, { iv: fromHex(r.iv), nonce: r.nonce, ts: r.ts });
            return { message: s.message, payload: s.payload };
        }
        case 'payload': {
            const d = keyOf(r.key);
            return { message: await C.sealPayload(await C.alertKey(d, r.aid), r.aid, r.payload, fromHex(r.iv)), payload: r.payload };
        }
        case 'compose': {
            const s = await B.compose(keyOf(r.key), r.act, r.x, { cid: r.cid, iv: fromHex(r.iv), nonce: r.nonce, ts: r.ts });
            return { message: s.message, payload: s.payload };
        }
        case 'composed':
            return { message: await B.sealCompose(keyOf(r.key), r.cid, r.payload, fromHex(r.iv)), payload: r.payload };
        case 'keys': {
            const k = await C.hmac(fromHex(r.d), C.utf8(r.label + r.id));
            const ks = await C.deriveKeys(k);
            return { k: toHex(k), enc: toHex(ks.enc), mac: toHex(ks.mac) };
        }
        case 'code':
            return await C.confirmCode(fromHex(r.d));
        case 'b64':
            return C.b64url(fromHex(r.hex));
        case 'unb64':
            return toHex(C.unb64url(r.text));
        default:
            throw new Error('no such request: ' + r.op);
    }
};

(async () => {
    const reqs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    const out = [];
    for (const r of reqs) out.push(await one(r));
    process.stdout.write(ascii(out) + '\n');
})().catch((e) => {
    process.stderr.write(String(e && e.stack || e) + '\n');
    process.exit(1);
});
