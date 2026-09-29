// Makes tests/fixtures/ask-vector.json: an answer to a question the chat
// waits on (docs/phone-ask-spec.md, section 5.4), sealed both ways the phone
// sends one, with fixed inputs, by Node's own crypto - neither the page's
// WebCrypto code nor the watcher's PowerShell, so a mistake the two share
// cannot hide. tests/reply-page-check.js and tests/board-page-check.js hold
// docs/reply.html to it; the watcher's tests hold its readers to it.
//
//   alertMessage    act answer on an alert's page: "chatq1." sealed under
//                   k = HMAC(D, "chatq-alert:" + aid), the reply's layout
//                   with rid, qh, a and o last
//   composeMessage  act answer from the board's chat view: "chatq3c."
//                   sealed under k_phone = HMAC(D, "chatq-phone:" + cid)
//
//     node tests/fixtures/make-ask-vector.js
//
// Run it again only when the wire format changes; the file is checked in.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const hmac = (key, msg) => crypto.createHmac('sha256', key).update(typeof msg === 'string' ? Buffer.from(msg, 'utf8') : msg).digest();
const seal = (k, head0, payload, iv) => {
    const c = crypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), iv);
    const ct = Buffer.concat([c.update(Buffer.from(payload, 'utf8')), c.final()]);
    const head = head0 + '.' + b64url(iv) + '.' + b64url(ct);
    return head + '.' + b64url(hmac(hmac(k, 'mac'), head));
};
// anything past ASCII written as a JSON escape: the file stays ASCII, so
// Windows PowerShell 5.1 reads it the same whatever its code page
const ascii = (o) => JSON.stringify(o, null, 2).replace(/[^\x00-\x7f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '\n';

const master = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const iv = Buffer.from(Array.from({ length: 16 }, (_, i) => 0x10 + i));
const aid = 'abcdefghij', cid = 'klmnopqrst';
const nonce = 'AAAAAAAAAAAAAAAAAAAAAA', ts = 1790000000000;
const rid = 'mnopqrstuv', qh = 'QUJDREVGR0hJSktMTU5PUA';
const h = 'k3m2qa', id = '1a2b3c4d';
// U+D55C U+AE00, made by fromCharCode only to keep this file ASCII: they go
// into the payloads as raw UTF-8, not as JSON escapes
const hangul = String.fromCharCode(0xD55C, 0xAE00);
// the first question's first option; the second's second and third, and
// its Other text
const a = [[0], [1, 2]];
const o = ['', 'free text ' + hangul];

// written out by hand, not by JSON.stringify: key order is the wire format
const alertPayload = '{"v":1,"act":"answer","text":"","nonce":"' + nonce + '","ts":' + ts + ',"rid":"' + rid + '","qh":"' + qh + '",' +
    '"a":[[0],[1,2]],"o":["","free text ' + hangul + '"]}';
const composePayload = '{"v":3,"act":"answer","h":"' + h + '","id":"' + id + '","rid":"' + rid + '","qh":"' + qh + '",' +
    '"a":[[0],[1,2]],"o":["","free text ' + hangul + '"],"nonce":"' + nonce + '","ts":' + ts + '}';

const kAlert = hmac(master, 'chatq-alert:' + aid);
const kPhone = hmac(master, 'chatq-phone:' + cid);
const alertMessage = seal(kAlert, 'chatq1.' + aid, alertPayload, iv);
const composeMessage = seal(kPhone, 'chatq3c.' + cid, composePayload, iv);
fs.writeFileSync(path.join(__dirname, 'ask-vector.json'), ascii({
    master: b64url(master), aid, cid, iv: b64url(iv), nonce, ts, rid, qh, h, id, a, o,
    alertPayload, kAlert: b64url(kAlert), alertMessage, composePayload, kPhone: b64url(kPhone), composeMessage
}));
console.log(alertMessage);
console.log(composeMessage);
