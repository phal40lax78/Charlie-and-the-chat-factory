// Makes tests/fixtures/reply-vector.json: one phone reply sealed with fixed
// inputs, computed by Node's own crypto module (createHmac, createCipheriv).
// It is the reference both sides are held to - docs/reply.html's WebCrypto
// code (tests/reply-page-check.js) and the watcher's PowerShell code
// (tests/sections/phone.ps1) must each reproduce the message exactly, and
// neither of them is used here, so a mistake shared by the two cannot hide.
// Since pairing, "master" is the phone's key D (reply.key on the PC, and a
// CryptoKey that will not export in the phone's IndexedDB); nothing else
// about it changed.
//
//     node tests/fixtures/make-reply-vector.js
//
// Run it again only when the wire format changes; the file is checked in.
const fs = require('fs');
const path = require('path');
const { b64url, hmac, seal, ascii } = require(path.join(__dirname, 'vector-kit.js'));

const master = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const aid = 'abcdefghij';
const iv = Buffer.from(Array.from({ length: 16 }, (_, i) => 0x10 + i));
// fed verbatim, never re-serialized. The two Hangul syllables U+D55C U+AE00
// are made by fromCharCode only to keep this file ASCII: they go into the
// payload as raw UTF-8 (6 bytes), not as JSON escapes
const hangul = String.fromCharCode(0xD55C, 0xAE00);
const payload = '{"v":1,"act":"prompt","text":"yes, commit it ' + hangul + '","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}';

const k = hmac(master, 'chatq-alert:' + aid);
const message = seal(k, 'chatq1.' + aid, payload, iv);

const out = { master: b64url(master), aid, iv: b64url(iv), payload, message, k: b64url(k) };
fs.writeFileSync(path.join(__dirname, 'reply-vector.json'), ascii(out));
console.log(message);
