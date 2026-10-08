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
const fs = require('fs');
const path = require('path');
const { b64url, hmac, seal, ascii } = require(path.join(__dirname, 'vector-kit.js'));

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
