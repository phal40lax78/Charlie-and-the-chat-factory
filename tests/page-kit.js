// What tests/reply-page-check.js and tests/board-page-check.js both hold
// docs/reply.html with: a marked block lifted out of the page's text, and
// the fakes the whole page runs on - an element, an IndexedDB. Not a check
// of its own: those two require it.

// The block between /* chatq-NAME-begin */ and /* chatq-NAME-end */, or
// null unless each marker is there once, the end after the begin
const markedBlock = (html, name) => {
    const b = '/* chatq-' + name + '-begin */', e = '/* chatq-' + name + '-end */';
    const i = html.indexOf(b), j = html.indexOf(e);
    if (i < 0 || j < i || html.indexOf(b, i + 1) >= 0 || html.indexOf(e, j + 1) >= 0) return null;
    return html.slice(i + b.length, j);
};

// the code only: what its strings and comments say (a "setup window") is not a use
const codeOnly = (js) => String(js).replace(/'(?:[^'\\\n]|\\.)*'/g, "''").replace(/\/\/.*$/gm, '');

// One element of the fake DOM, as much of one as the page touches; focus()
// and blur() move doc.activeElement
const fakeElement = (doc) => (id, tag) => {
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

module.exports = { markedBlock, codeOnly, fakeElement, fakeIndexedDb };
