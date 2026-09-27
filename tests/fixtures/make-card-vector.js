// Makes tests/fixtures/card-vector.json: a permission request's card and
// the phone's sealed answer to it, with fixed inputs, computed by Node's own
// crypto module. The reference both sides are held to, as reply-vector.json
// is: the watcher seals the card (Protect-ChatqPermitCard, tests/sections/
// permit.ps1) and the page opens it (openCard, tests/reply-page-check.js);
// the page seals the permit with h (buildPayload) and the bridge opens it.
// Neither side's code is used here, so a mistake the two share cannot hide.
//
//   digest = b64url(SHA-256("chatq-permit\n" + rid + "\n" + tool + "\n" + inputRaw)[0..15])
//   kc     = HMAC-SHA256(D, "chatq-card:" + aid)
//   card   = "chatq1c." + aid + "." + b64url(iv) + "." + b64url(AES-256-CBC(HMAC(kc,"enc"), iv, json))
//            + "." + b64url(HMAC-SHA256(HMAC(kc,"mac"), head))
//
//     node tests/fixtures/make-card-vector.js
//
// Run it again only when the wire format changes; the file is checked in.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const hmac = (key, msg) => crypto.createHmac('sha256', key).update(Buffer.from(msg, 'utf8')).digest();
const seal = (k, prefix, aid, iv, text) => {
    const cipher = crypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), iv);
    const ct = Buffer.concat([cipher.update(Buffer.from(text, 'utf8')), cipher.final()]);
    const head = prefix + '.' + aid + '.' + b64url(iv) + '.' + b64url(ct);
    return head + '.' + b64url(hmac(hmac(k, 'mac'), head));
};

const master = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const aid = 'abcdefghij';
const cardIv = Buffer.from(Array.from({ length: 16 }, (_, i) => 0x20 + i));
const replyIv = Buffer.from(Array.from({ length: 16 }, (_, i) => 0x10 + i));
// U+D55C U+AE00, made by fromCharCode only to keep this file ASCII
const hangul = String.fromCharCode(0xD55C, 0xAE00);

// the request as the bridge holds it: its input exactly as claude sent it
const rid = 'k2m3n4p5q6';
const tool = 'Bash';
const inputRaw = '{"command":"git push origin main # ' + hangul + '","description":"Push the release"}';
const digest = b64url(crypto.createHash('sha256').update(Buffer.from('chatq-permit\n' + rid + '\n' + tool + '\n' + inputRaw, 'utf8')).digest().subarray(0, 16));

// the card, verbatim - key order and spelling are the wire format
const card = '{"v":1,"t":"Bash","w":"git push origin main # ' + hangul + '","d":"Push the release","f":"parser","c":"Parser rewrite ' + hangul +
    '","n":12,"h":"' + digest + '","u":1790000600000}';
const kc = hmac(master, 'chatq-card:' + aid);
const sealedCard = seal(kc, 'chatq1c', aid, cardIv, card);

// the phone's answer: a permit whose payload ends with h, sealed as every
// reply is, under the alert's own key
const permitPayload = '{"v":1,"act":"permit","text":"","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000,"h":"' + digest + '"}';
const permitMessage = seal(hmac(master, 'chatq-alert:' + aid), 'chatq1', aid, replyIv, permitPayload);

const out = {
    master: b64url(master), aid, rid, tool, inputRaw, digest,
    iv: b64url(cardIv), card, kc: b64url(kc), sealed: sealedCard,
    replyIv: b64url(replyIv), permitPayload, permitMessage
};
// anything past ASCII written as a JSON escape, so the file stays ASCII
const text = JSON.stringify(out, null, 2).replace(/[^\x00-\x7f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '\n';
fs.writeFileSync(path.join(__dirname, 'card-vector.json'), text);
console.log(sealedCard);
