// Makes tests/fixtures/down-vector.json and compose-vector.json: the two
// messages of the PC -> phone channel (docs/phone-board-spec.md, section 2),
// sealed with fixed inputs by Node's own crypto and zlib - neither the page's
// WebCrypto code nor the watcher's PowerShell, so a mistake the two share
// cannot hide. tests/board-page-check.js holds docs/reply.html to both, and
// tests/sections/phone-board.ps1 holds src/phone-down.ps1 to both.
//
//   down-vector.json     a whole answer, PC -> phone: "chatq3d." sealed under
//                        k_down = HMAC(D, "chatq-down:" + did), its JSON
//                        raw-deflated before the AES; the down topic of D
//   compose-vector.json  a send, phone -> PC: "chatq3c." sealed under
//                        k_phone = HMAC(D, "chatq-phone:" + cid)
//
//     node tests/fixtures/make-down-vector.js
//
// Run it again only when the wire format changes; the files are checked in.
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');
const { b64url, hmac, seal, ascii } = require(path.join(__dirname, 'vector-kit.js'));

const master = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const iv = Buffer.from(Array.from({ length: 16 }, (_, i) => 0x10 + i));
// U+D55C U+AE00, made by fromCharCode only to keep this file ASCII: they go
// into the payloads as raw UTF-8, not as JSON escapes
const hangul = String.fromCharCode(0xD55C, 0xAE00);

// the down topic: 24 letters of [a-z2-7], each a byte of HMAC(D,
// "chatq-down-topic") mod 32 - unbiased, 256 being a multiple of 32
const abc = 'abcdefghijklmnopqrstuvwxyz234567';
const th = hmac(master, 'chatq-down-topic');
const downTopic = 'chatq-' + Array.from(th.subarray(0, 24), (b) => abc[b % 32]).join('');

const did = 'abcdefghij';
const payload = '{"v":3,"kind":"reply","ref":"abcdefghij","ts":1790000000000,"event":"done","title":"Parser rewrite","at":"2026-09-26T10:00:00.000Z","cut":0,' +
    '"parts":[{"t":"text","s":"yes, commit it ' + hangul + '"},{"t":"tool","s":"Bash git status"}]}';
const deflated = zlib.deflateRawSync(Buffer.from(payload, 'utf8'));
const kDown = hmac(master, 'chatq-down:' + did);
const downMessage = seal(kDown, 'chatq3d.' + did, deflated, iv);
fs.writeFileSync(path.join(__dirname, 'down-vector.json'), ascii({
    master: b64url(master), did, iv: b64url(iv), payload, deflated: b64url(deflated), k: b64url(kDown), message: downMessage, downTopic
}));

const cid = 'klmnopqrst';
const cpayload = '{"v":3,"act":"send","h":"k3m2qa","id":"1a2b3c4d","text":"yes, commit it ' + hangul + '","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}';
const kPhone = hmac(master, 'chatq-phone:' + cid);
const composeMessage = seal(kPhone, 'chatq3c.' + cid, Buffer.from(cpayload, 'utf8'), iv);
fs.writeFileSync(path.join(__dirname, 'compose-vector.json'), ascii({
    master: b64url(master), cid, iv: b64url(iv), payload: cpayload, k: b64url(kPhone), message: composeMessage
}));
console.log(downTopic);
console.log(downMessage);
console.log(composeMessage);
