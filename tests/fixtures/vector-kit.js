// What the fixture makers share: base64url, HMAC-SHA256, the seal every
// chatq message is made with, and the JSON they write. Node's own crypto
// only - never the page's code nor the watcher's.
const crypto = require('crypto');

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const hmac = (key, msg) => crypto.createHmac('sha256', key).update(typeof msg === 'string' ? Buffer.from(msg, 'utf8') : msg).digest();
// head0 + "." + b64url(iv) + "." + b64url(AES-256-CBC(HMAC(k, "enc"), iv, plain))
// + "." + b64url(HMAC-SHA256(HMAC(k, "mac"), head)); plain a string (as
// UTF-8) or bytes
const seal = (k, head0, plain, iv) => {
    const c = crypto.createCipheriv('aes-256-cbc', hmac(k, 'enc'), iv);
    const ct = Buffer.concat([c.update(typeof plain === 'string' ? Buffer.from(plain, 'utf8') : plain), c.final()]);
    const head = head0 + '.' + b64url(iv) + '.' + b64url(ct);
    return head + '.' + b64url(hmac(hmac(k, 'mac'), head));
};
// anything past ASCII written as a JSON escape: the file stays ASCII, so
// Windows PowerShell 5.1 reads it the same whatever its code page
const ascii = (o) => JSON.stringify(o, null, 2).replace(/[^\x00-\x7f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '\n';

module.exports = { b64url, hmac, seal, ascii };
