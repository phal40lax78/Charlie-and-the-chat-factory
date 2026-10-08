// Builds what the package carries besides the extension itself: payload/ -
// the loader and exactly the parts its list names - and the CHANGELOG and
// LICENSE the Marketplace listing shows, copied from the repo. vsce runs it
// before every package and publish (vscode:prepublish); so can you:
//
//     node extension/build.js
//
// It fails, and nothing gets packed, when the extension's version is not the
// script's, a script is not pure ASCII, or the listing's README or CHANGELOG
// holds an SVG image, which the Marketplace refuses.
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
    // hook's launcher, which Claude Code starts on its own (src/ask.ps1)
    for (const extra of ['ask-hook']) copyPart(extra, 'src/' + extra + '.ps1 is not there');
    copy(path.join(root, 'CHANGELOG.md'), path.join(here, 'CHANGELOG.md'));
    copy(path.join(root, 'LICENSE'), path.join(here, 'LICENSE'));
    for (const md of ['README.md', 'CHANGELOG.md']) {
        const svg = svgImages(fs.readFileSync(path.join(here, md), 'utf8'));
        if (svg.length) fail(md + ' shows SVG images, which the Marketplace refuses: ' + svg.join(', '));
    }
    console.log('build: ' + version + ', the loader and ' + parts.length + ' parts in payload/');
    return { version, parts };
}

if (require.main === module) build();
module.exports = { build, _partsOf: partsOf, _svgImages: svgImages, _isAscii: isAscii };
