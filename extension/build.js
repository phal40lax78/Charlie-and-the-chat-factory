// Builds what the package carries besides the extension itself: payload/ -
// the loader and exactly the parts its list names, and the native panel's
// exe where CHATQ_OVERLAY_EXE names one (stageBin) - and the CHANGELOG and
// LICENSE the Marketplace listing shows, copied from the repo. vsce runs it
// before every package and publish (vscode:prepublish); so can you:
//
//     node extension/build.js
//
// It fails, and nothing gets packed, when the extension's version is not the
// script's, a script is not pure ASCII, the listing's README or CHANGELOG
// holds an SVG image, which the Marketplace refuses, or the exe named is
// not this version's.
const fs = require('fs');
const path = require('path');
const setup = require('./setup');

const here = __dirname;
const root = path.dirname(here);
const fail = (m) => { console.error('build: ' + m); process.exit(1); };

// the part names in the loader's own list, in its order
function partsOf(loaderText) {
    const line = /^\$chatParts = (.+)$/m.exec(loaderText);
    return line ? [...line[1].matchAll(/'([^']+)'/g)].map(m => m[1]) : [];
}

// an image in Markdown or HTML whose address ends in .svg. Pure.
function svgImages(md) {
    const found = [];
    for (const m of String(md).matchAll(/!\[[^\]]*\]\(([^)\s]+)[^)]*\)|<img[^>]+src=["']([^"']+)["']/gi)) {
        const url = m[1] || m[2];
        if (/\.svg(\?|#|$)/i.test(url)) found.push(url);
    }
    return found;
}

function isAscii(buf) { for (const b of buf) if (b > 127) return false; return true; }

const TARGET = 'x86_64-pc-windows-msvc';
const NOTICES = 'THIRD-PARTY-NOTICES.html';

// An x64 Windows exe: MZ, then the PE header where e_lfanew points, its
// machine AMD64. Pure.
function isWinX64Exe(buf) {
    if (!buf || buf.length < 64 || buf[0] !== 0x4d || buf[1] !== 0x5a) return false;
    const pe = buf.readUInt32LE(0x3c);
    return pe + 6 <= buf.length && buf.readUInt32LE(pe) === 0x00004550 && buf.readUInt16LE(pe + 4) === 0x8664;
}

// what `chatq-overlay --version` prints, trimmed
function exeVersion(exe) {
    return String(require('child_process').execFileSync(exe, ['--version'],
        { timeout: 15000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })).trim();
}

// The native panel (native/overlay), staged where the tool looks for it:
// payload/bin/<version>/x86_64-pc-windows-msvc/chatq-overlay.exe, from the
// file CHATQ_OVERLAY_EXE names, with the THIRD-PARTY-NOTICES.html cargo-about
// wrote beside it (.github/workflows/test.yml). An exe is staged only when
// it is an x64 Windows exe whose --version is this version; anything else
// fails the build. With CHATQ_REQUIRE_BIN=1 - CI's package and publish - a
// missing exe or notices fail it too; without, a local build warns and
// packs no exe, and the panel there is the WPF one. Throws what fails;
// returns the folder staged, or null.
// Deferred: DEFERRED.md "Platform-specific VSIXes"
function stageBin(payload, version, env, o) {
    o = o || {};
    const warn = o.warn || ((m) => console.warn('build: warning: ' + m));
    const run = o.run || exeVersion;
    const required = env.CHATQ_REQUIRE_BIN === '1';
    const miss = (m) => {
        if (required) throw new Error(m + ' (CHATQ_REQUIRE_BIN=1)');
        warn(m + ' - packing no native panel; the WPF one stands in');
        return null;
    };
    const exe = env.CHATQ_OVERLAY_EXE;
    if (!exe) return miss('CHATQ_OVERLAY_EXE names no chatq-overlay.exe');
    if (!fs.existsSync(exe)) return miss(exe + ' is not there');
    if (!isWinX64Exe(fs.readFileSync(exe))) throw new Error(exe + ' is not an x64 Windows exe');
    let said;
    try { said = run(exe); } catch (e) { throw new Error(exe + ' --version failed: ' + e.message); }
    if (said !== 'chatq-overlay ' + version) throw new Error(exe + ' --version says "' + said + '", not chatq-overlay ' + version);
    const notices = path.join(path.dirname(exe), NOTICES);
    const hasNotices = fs.existsSync(notices);
    if (!hasNotices) {
        if (required) throw new Error('no ' + NOTICES + ' beside ' + exe + ' (CHATQ_REQUIRE_BIN=1) - cargo about generate writes it');
        warn('no ' + NOTICES + ' beside ' + exe + ' - packing the exe without its licence notices; cargo about generate writes them');
    }
    const to = path.join(payload, 'bin', version, TARGET);
    fs.mkdirSync(to, { recursive: true });
    fs.copyFileSync(exe, path.join(to, 'chatq-overlay.exe'));
    if (hasNotices) fs.copyFileSync(notices, path.join(to, NOTICES));
    return to;
}

function build() {
    const loaderPath = path.join(root, setup.LOADER);
    const loaderBuf = fs.readFileSync(loaderPath);
    const loader = loaderBuf.toString('latin1');
    const version = setup._readVersion(loader);
    const pkg = JSON.parse(fs.readFileSync(path.join(here, 'package.json'), 'utf8'));
    if (!version) fail('no $script:ChatVersion in ' + setup.LOADER);
    if (pkg.version !== version) fail('package.json is ' + pkg.version + ' but ' + setup.LOADER + ' is ' + version + ' - bump both together');
    const parts = partsOf(loader);
    if (!parts.length) fail('no $chatParts list in ' + setup.LOADER);

    const payload = path.join(here, 'payload');
    fs.rmSync(payload, { recursive: true, force: true });
    fs.mkdirSync(path.join(payload, 'src'), { recursive: true });
    const copy = (from, to) => {
        const buf = fs.readFileSync(from);
        if (/\.ps1$/i.test(from) && !isAscii(buf)) fail(path.relative(root, from) + ' is not pure ASCII');
        fs.writeFileSync(to, buf);
    };
    copy(loaderPath, path.join(payload, setup.LOADER));
    // a part into payload/src, or the build fails saying missing
    const copyPart = (name, missing) => {
        const from = path.join(root, 'src', name + '.ps1');
        if (!fs.existsSync(from)) fail(missing);
        copy(from, path.join(payload, 'src', name + '.ps1'));
    };
    for (const p of parts) copyPart(p, 'the loader lists src/' + p + '.ps1, which is not there');
    // files beside the parts that the loader does not load: the question
    // hook's launcher, which Claude Code starts on its own (src/ask.ps1),
    // and the helper step chatqd starts (native/SPEC.md 3.6)
    for (const extra of ['ask-hook', 'native-step']) copyPart(extra, 'src/' + extra + '.ps1 is not there');
    let bin = null;
    try { bin = stageBin(payload, version, process.env); } catch (e) { fail(e.message); }
    copy(path.join(root, 'CHANGELOG.md'), path.join(here, 'CHANGELOG.md'));
    copy(path.join(root, 'LICENSE'), path.join(here, 'LICENSE'));
    for (const md of ['README.md', 'CHANGELOG.md']) {
        const svg = svgImages(fs.readFileSync(path.join(here, md), 'utf8'));
        if (svg.length) fail(md + ' shows SVG images, which the Marketplace refuses: ' + svg.join(', '));
    }
    console.log('build: ' + version + ', the loader and ' + parts.length + ' parts in payload/' + (bin ? ', and chatq-overlay.exe in ' + path.relative(here, bin) : ''));
    return { version, parts, bin };
}

if (require.main === module) build();
module.exports = { build, _partsOf: partsOf, _svgImages: svgImages, _isAscii: isAscii, _isWinX64Exe: isWinX64Exe, _stageBin: stageBin };
