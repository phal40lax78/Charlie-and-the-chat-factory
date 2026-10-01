// The watch panel's pure half: a queued run's stream (data/logs/<id>.jsonl)
// turned into rows, each row as HTML, and the page the rows go into. No
// vscode here - extension.js opens the panel, tails the log and feeds it -
// so every part can be driven from tests/extension-check.js as it is.
//
// The stream is claude -p's stream-json, or codex exec --json's events, as
// Get-ChatqLogEntries (src/commands.ps1) reads them for the console; this
// shows more of it, since the panel stands in for the chat's own tab while
// the run goes on.

// a line longer than this is never parsed: a tool result of megabytes - a
// file read whole, a build's output - would hold the window's thread
const LARGE = 256 * 1024;
// a tool result, shown: its first lines, and at most this many characters
const RESULT_LINES = 3;
const RESULT_CHARS = 300;
// the deepest indent a subagent's rows get; deeper ones stay there
const MAX_DEPTH = 3;
// the rows kept, by the parser and on the page: a run of hours with
// subagents makes tens of thousands, each kept whole, and a page sent all of
// them again (a reload of the webview) would freeze. The earlier ones are
// in Log.
const MAX_ROWS = 5000;

function firstLine(s) { return String(s || '').split(/\r?\n/)[0]; }
function lineCount(s) { return s ? String(s).split('\n').length : 0; }

// What a tool row names beside the tool: the command's first line, else the
// file, the pattern, or the description (an Agent's, a Task's). Pure.
function toolArg(input) {
    const i = input && typeof input === 'object' ? input : {};
    for (const k of ['command', 'file_path', 'pattern', 'description']) {
        if (typeof i[k] === 'string' && i[k]) return firstLine(i[k]);
    }
    return '';
}

// An edit's size, as the Claude tab shows it: lines put in and taken out.
// Write puts its whole content in. null for any other tool. Pure.
function editSize(name, input) {
    const i = input && typeof input === 'object' ? input : {};
    if (name === 'Edit') return { plus: lineCount(i.new_string), minus: lineCount(i.old_string) };
    if (name === 'MultiEdit' && Array.isArray(i.edits)) {
        return i.edits.reduce((a, e) => ({ plus: a.plus + lineCount(e && e.new_string), minus: a.minus + lineCount(e && e.old_string) }), { plus: 0, minus: 0 });
    }
    if (name === 'Write') return { plus: lineCount(i.content), minus: 0 };
    return null;
}

// A tool result's text: a string, or the text blocks of an array; an image
// reads as one. Pure.
function resultText(content) {
    if (typeof content === 'string') return content;
    if (!Array.isArray(content)) return '';
    return content.map(b => (b && b.type === 'text' ? String(b.text || '') : b && b.type === 'image' ? '(image)' : '')).filter(Boolean).join('\n');
}

// The first lines of a result, and how many more there are. Pure.
function clip(text) {
    const all = String(text || '').replace(/\r\n/g, '\n').replace(/\n+$/, '');
    const lines = all ? all.split('\n') : [];
    let shown = lines.slice(0, RESULT_LINES).join('\n');
    if (shown.length > RESULT_CHARS) shown = shown.slice(0, RESULT_CHARS) + '...';
    return { text: shown, more: Math.max(0, lines.length - RESULT_LINES) };
}

// A line too large to parse: the tool it answers, where its id can be seen
// near either end without reading the rest
function sniffToolId(line) {
    const re = /"tool_use_id"\s*:\s*"([^"]{1,200})"/;
    const m = re.exec(line.slice(0, 4096)) || re.exec(line.slice(-4096));
    return m ? m[1] : null;
}

// The parser behind watchItems, kept by the panel for the run's whole life:
// each line pushed turns into rows, or changes one - a tool's result, its
// heartbeat - and dirty() hands over what changed since it was last asked,
// so only that goes to the page. now: when the line was seen, in ms; a
// tool's own clock starts there. Only the last maxRows rows are kept (o,
// else MAX_ROWS): a row's i is its place in the whole run all the same, and
// dropped says how many went before the first kept. The last TodoWrite's
// list is kept apart from the rows (todos), so the pinned todo outlives the
// row it came in.
function newParser(o) {
    const max = o && o.maxRows > 0 ? o.maxRows : MAX_ROWS;
    const items = [];
    const tools = new Map();
    let changed = new Set(), next = 0, dropped = 0, todos = null;
    const add = (it) => {
        it.i = next++;
        items.push(it);
        changed.add(it.i);
        while (items.length > max) {
            const gone = items.shift();
            dropped++;
            changed.delete(gone.i);
            if (gone.kind === 'tool' && gone.id && tools.get(gone.id) === gone) tools.delete(gone.id);
        }
        return it;
    };
    const touch = (it) => { changed.add(it.i); };
    // every tool still open closed: the turn is over, or a new attempt began
    const closeOpen = () => { for (const t of tools.values()) if (!t.done) { t.done = true; touch(t); } };
    const depthOf = (parent) => {
        if (!parent) return 0;
        const p = tools.get(parent);
        return Math.min(MAX_DEPTH, p ? p.depth + 1 : 1);
    };
    const toolDone = (id, error) => {
        const t = tools.get(id);
        if (!t) return null;
        if (!t.done || (error && !t.error)) { t.done = true; t.error = t.error || !!error; touch(t); }
        return t;
    };
    function push(line, now) {
        const at = Number.isFinite(now) ? now : Date.now();
        const l = String(line || '');
        if (!l.trim()) return;
        if (l.length > LARGE) {
            if (/^\s*\{\s*"type"\s*:\s*"user"/.test(l)) {
                const id = sniffToolId(l);
                const t = id ? toolDone(id, false) : null;
                add({ kind: 'toolResult', id, text: '(large result)', more: 0, error: false, large: true, depth: t ? t.depth : 0 });
            } else {
                add({ kind: 'note', text: '(a line too large to show)' });
            }
            return;
        }
        let o;
        try { o = JSON.parse(l); } catch (e) { return; }
        if (!o || typeof o !== 'object') return;
        switch (o.type) {
            case 'system':
                // a new attempt: a retry appends to the same log, and one cut
                // off - cancelled, its watcher gone - wrote no result, so its
                // tools would read as running beside the new ones
                if (o.subtype === 'init') {
                    closeOpen();
                    add({ kind: 'init', model: String(o.model || ''), mode: String(o.permissionMode || ''), version: String(o.claude_code_version || '') });
                }
                else if (o.subtype === 'permission_denied') add({ kind: 'denied', tool: String(o.tool_name || '') });
                return;
            case 'assistant': {
                const depth = depthOf(o.parent_tool_use_id);
                const content = o.message && Array.isArray(o.message.content) ? o.message.content : [];
                for (const c of content) {
                    if (!c) continue;
                    // thinking, redacted or not, is the model's own and skipped
                    if (c.type === 'text' && typeof c.text === 'string' && c.text.trim()) add({ kind: 'text', text: c.text, depth });
                    else if (c.type === 'tool_use') {
                        const t = add({
                            kind: 'tool', id: String(c.id || ''), name: String(c.name || ''), arg: toolArg(c.input), depth,
                            edit: editSize(c.name, c.input), todos: c.name === 'TodoWrite' && c.input && Array.isArray(c.input.todos) ? c.input.todos : null,
                            since: at, progress: null, done: false, error: false
                        });
                        if (t.id) tools.set(t.id, t);
                        if (t.todos) todos = t.todos;
                    }
                }
                return;
            }
            case 'user': {
                // the prompt, and anything else the run was given, is not the
                // run's doing: only the results of its own tools are shown
                const content = o.message && Array.isArray(o.message.content) ? o.message.content : [];
                for (const c of content) {
                    if (!c || c.type !== 'tool_result') continue;
                    const t = toolDone(c.tool_use_id, c.is_error === true);
                    const r = clip(resultText(c.content));
                    add({ kind: 'toolResult', id: c.tool_use_id || null, text: r.text, more: r.more, error: c.is_error === true, large: false, depth: t ? t.depth : depthOf(o.parent_tool_use_id) });
                }
                return;
            }
            case 'tool_progress': {
                // a heartbeat only refines the tool's own clock: one path of
                // the CLI sends none at all (CLAUDE_CODE_REMOTE, CONTAINER_ID)
                const t = tools.get(o.tool_use_id);
                const s = Number(o.elapsed_time_seconds);
                if (!t || !Number.isFinite(s)) return;
                t.progress = s;
                t.since = Math.min(t.since, at - s * 1000);
                touch(t);
                return;
            }
            case 'rate_limit_event': {
                const r = o.rate_limit_info || {};
                if (r.status === 'rejected') add({ kind: 'limit', resetsAt: Number(r.resetsAt) || null, type: String(r.rateLimitType || '') });
                return;
            }
            case 'result':
                // the turn is over: any tool still open is not running any more
                closeOpen();
                add({ kind: 'result', subtype: String(o.subtype || ''), turns: Number(o.num_turns) || 0, durationMs: Number(o.duration_ms) || 0, error: o.is_error === true });
                return;
            // Codex, as Get-ChatqLogEntries reads it; its new attempt, as
            // Claude's init
            case 'thread.started':
            case 'turn.started':
                closeOpen();
                return;
            case 'item.started':
                if (o.item && o.item.type === 'command_execution') {
                    const t = add({ kind: 'tool', id: String(o.item.id || ''), name: 'shell', arg: firstLine(o.item.command), depth: 0, edit: null, todos: null, since: at, progress: null, done: false, error: false });
                    if (t.id) tools.set(t.id, t);
                }
                return;
            case 'item.completed': {
                const it = o.item || {};
                if (it.type === 'agent_message' && it.text) add({ kind: 'text', text: String(it.text), depth: 0 });
                else if (it.type === 'command_execution') {
                    const bad = Number.isInteger(it.exit_code) && it.exit_code !== 0;
                    if (!toolDone(it.id, bad)) add({ kind: 'tool', id: String(it.id || ''), name: 'shell', arg: firstLine(it.command), depth: 0, edit: null, todos: null, since: at, progress: null, done: true, error: bad });
                }
                return;
            }
            case 'turn.failed':
                add({ kind: 'error', text: String((o.error && o.error.message) || 'the turn failed') });
                return;
            case 'error':
                add({ kind: 'error', text: String(o.message || 'error') });
                return;
        }
    }
    return {
        items, push,
        get dropped() { return dropped; },
        // the last TodoWrite's list, however long ago its row was dropped
        get todos() { return todos; },
        // a row changed and dropped since is not handed over
        dirty() {
            const first = items.length ? items[0].i : next;
            const d = [...changed].sort((a, b) => a - b);
            changed = new Set();
            return d.filter(i => i >= first).map(i => items[i - first]);
        }
    };
}

// Every row a run's lines make, in order. Pure: the rows the panel shows,
// for the tests. now: when the lines were seen, in ms.
function watchItems(lines, now) {
    const p = newParser();
    for (const l of lines || []) p.push(l, now);
    return p.items;
}

// The latest TodoWrite, pinned above the rows: what is being done, and how
// far along the list that is - "Now: run the tests (3/7)". '' for none.
// from: a parser, whose own last list counts - a run past MAX_ROWS has
// dropped the row it came in - or rows, looked through. Pure.
function pinnedTodo(from) {
    let todos = null;
    if (Array.isArray(from)) { for (const it of from) if (it && it.kind === 'tool' && it.todos) todos = it.todos; }
    else if (from && Array.isArray(from.todos)) todos = from.todos;
    if (!todos || !todos.length) return '';
    const n = todos.length;
    const at = todos.findIndex(t => t && t.status === 'in_progress');
    if (at >= 0) return 'Now: ' + String(todos[at].activeForm || todos[at].content || '') + ' (' + (at + 1) + '/' + n + ')';
    const done = todos.filter(t => t && t.status === 'completed').length;
    return 'Todo: ' + done + '/' + n + ' done';
}

// The text as text, in HTML and in an attribute. Pure.
function esc(s) {
    return String(s === undefined || s === null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// A length of time as the panel says it: 45 s, 6m 12s, 1h 04m. Pure.
function fmtDur(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    if (s < 60) return s + ' s';
    const m = Math.floor(s / 60);
    if (m < 60) return m + 'm ' + String(s % 60).padStart(2, '0') + 's';
    return Math.floor(m / 60) + 'h ' + String(m % 60).padStart(2, '0') + 'm';
}

// A time of day, HH:MM on this machine's clock, from an ISO stamp or epoch
// ms; '' for none. Pure but for the time zone.
function hhmm(t) {
    const d = typeof t === 'number' ? new Date(t) : new Date(Date.parse(String(t || '')));
    if (isNaN(d.getTime())) return '';
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

// One row as HTML: data-i is its place, so a row that changes replaces
// itself on the page. An open tool row carries data-since, which the page's
// own clock reads each second. Pure.
function itemHtml(it) {
    const d = ' d' + Math.min(MAX_DEPTH, it.depth || 0);
    const at = ' data-i="' + it.i + '"';
    switch (it.kind) {
        case 'init':
            return '<div class="row init"' + at + '>' + esc([it.model, it.mode, it.version ? 'Claude Code ' + it.version : ''].filter(Boolean).join(' \u00b7 ')) + '</div>';
        case 'text':
            return '<div class="row text' + d + '"' + at + '>' + esc(it.text) + '</div>';
        case 'tool': {
            const edit = it.edit ? ' <span class="plus">+' + it.edit.plus + '</span>' + (it.edit.minus ? ' <span class="minus">-' + it.edit.minus + '</span>' : '') : '';
            const open = it.done ? '' : ' data-since="' + Math.floor(it.since) + '"';
            return '<div class="row tool' + d + (it.error ? ' err' : '') + '"' + at + open + '><span class="name">' + esc(it.name) + '</span>' +
                (it.arg ? ' <span class="arg">' + esc(it.arg) + '</span>' : '') + edit + '<span class="clock"></span></div>';
        }
        case 'toolResult':
            return '<div class="row res' + d + (it.error ? ' err' : '') + '"' + at + '>' + esc(it.text || (it.large ? '' : '(no output)')) +
                (it.more ? '<span class="more"> +' + it.more + ' lines</span>' : '') + '</div>';
        case 'denied':
            return '<div class="row warn"' + at + '>denied: ' + esc(it.tool) + '</div>';
        case 'limit':
            return '<div class="row warn"' + at + '>usage limit reached' + (it.resetsAt ? ' - resets at ' + esc(hhmm(it.resetsAt * 1000)) : '') + '</div>';
        case 'result':
            return '<div class="row result' + (it.error ? ' err' : '') + '"' + at + '>' + esc([it.subtype, it.turns ? it.turns + ' turns' : '', it.durationMs ? fmtDur(it.durationMs) : ''].filter(Boolean).join(' \u00b7 ')) + '</div>';
        case 'error':
            return '<div class="row err"' + at + '>' + esc(it.text) + '</div>';
        default:
            return '<div class="row note"' + at + '>' + esc(it.text) + '</div>';
    }
}

// The job's state, as the header says it. job: data/queue/<id>.json as the
// watcher writes it. Pure.
function stateText(job) {
    if (!job) return 'not found - removed, or not queued yet';
    const r = job.result || {};
    const last = Array.isArray(job.history) && job.history.length ? job.history[job.history.length - 1] : null;
    switch (job.state) {
        case 'running': return 'running';
        case 'done': return 'done';
        case 'needs-input': return 'needs your input' + (r.reason ? ' - ' + r.reason : '');
        case 'failed': return 'failed' + (r.reason ? ' - ' + r.reason : '');
        case 'skipped': return 'skipped' + (r.reason ? ' - ' + r.reason : '');
        case 'queued': {
            // a job that ran and came back: the limit, a 529, the network
            if (!job.startedAt) return 'queued';
            const why = last && last.why ? String(last.why) : '';
            const m = /continues at (\d\d:\d\d)/.exec(why);
            if (/^limited/.test(why) || (r.kind === 'limited')) return 'stopped at the limit - back in the queue' + (m ? ', continues at ' + m[1] : '');
            return 'back in the queue' + (why ? ' - ' + why : '');
        }
        default: return String(job.state || '');
    }
}

// The header: "#15 - <title> - running 12m", the time since the last
// output, a question the phone is waiting on, the prompt's first lines, and
// the buttons - Cancel while it runs, Log, and Open chat once it ended or
// went back to the queue after a try (the limit mid-run: the tab its
// handover closed is put back by nothing else until the next run), never
// for a Codex chat, which no Claude tab shows. "Ultracode" and "effort max"
// beside the state where the run carries them (the job's ultracode and
// effort, or o.ultracode and o.effort from run-state) - settings of the
// chat's that live only in its process, which claude -p starts without
// unless told. Only a level Claude Code knows is shown, and neither while
// queued: a job back in the queue after a limit keeps what its last run
// carried, and its next start reads the chat afresh. o: { prompt, lastAt,
// cut, ultracode, effort }. Pure.
const LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'];
function headerHtml(job, o) {
    const x = o || {};
    const j = job || {};
    const running = j.state === 'running';
    const ran = j.state !== 'queued';
    const since = Date.parse(j.startedAt || '');
    const state = esc(stateText(job)) + (running && since ? ' <span class="tick" data-since="' + since + '"></span>' : '');
    const ultra = ran && (j.ultracode === true || x.ultracode === true) ? ' \u00b7 <span class="ultra">Ultracode</span>' : '';
    const level = !ran ? '' : LEVELS.includes(j.effort) ? j.effort : LEVELS.includes(x.effort) ? x.effort : '';
    const effort = level ? ' \u00b7 <span class="effort">effort ' + level + '</span>' : '';
    const lines = ['<div class="title">#' + esc(j.seq === undefined ? '?' : j.seq) + ' \u00b7 ' + esc(j.title || '') + ' \u00b7 <span class="state ' +
        (running ? 'on' : j.state === 'done' ? 'ok' : j.state === 'queued' ? 'wait' : 'bad') + '">' + state + '</span>' + ultra + effort + '</div>'];
    if (running && x.lastAt) lines.push('<div class="sub">last output <span class="ago" data-at="' + Math.floor(x.lastAt) + '"></span></div>');
    const pw = j.permitWaiting;
    if (running && pw && pw.tool) lines.push('<div class="permit">waits for your answer on the phone: ' + esc(pw.tool) + (pw.until ? ', until ' + esc(hhmm(pw.until)) : '') + '</div>');
    if (x.prompt) lines.push('<div class="prompt">' + esc(x.prompt) + '</div>');
    if (x.cut) lines.push('<div class="sub">the log\'s last 2 MB - Log opens all of it</div>');
    const b = [];
    if (running) b.push('<button data-act="cancel">Cancel</button>');
    b.push('<button data-act="log">Log</button>');
    const tried = j.state !== 'queued' || !!j.startedAt || Number(j.attempts) > 0;
    if (job && !running && tried && j.provider !== 'codex' && j.sessionId) b.push('<button data-act="open">Open chat</button>');
    lines.push('<div class="buttons">' + b.join('') + '</div>');
    return lines.join('');
}

// The page, with a policy that runs only its own script and style - nonce,
// a fresh one each page - and loads nothing at all. Colours are VS Code's
// own --vscode-* variables, so it follows the theme. It follows the bottom
// while you are at the bottom, and stops once you scroll up. jobId goes into
// its state, so a window reload brings the panel back (the serializer in
// extension.js). Pure.
function pageHtml(nonce, jobId) {
    const n = esc(nonce);
    const id = JSON.stringify(String(jobId)).replace(/</g, '\\u003c');
    return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'nonce-' + n + '\'; script-src \'nonce-' + n + '\';">' +
        '<meta name="viewport" content="width=device-width, initial-scale=1"><style nonce="' + n + '">' + PAGE_CSS + '</style></head><body>' +
        '<header id="head"></header><div id="pin"></div><div id="earlier"></div><main id="rows"></main>' +
        '<script nonce="' + n + '">' + pageScript(id) + '</script></body></html>';
}

const PAGE_CSS = [
    'body{font-family:var(--vscode-font-family);font-size:var(--vscode-font-size);color:var(--vscode-foreground);background:var(--vscode-editor-background);margin:0;padding:0 14px 14px}',
    'header{position:sticky;top:0;background:var(--vscode-editor-background);padding:10px 0 8px;border-bottom:1px solid var(--vscode-panel-border);z-index:1}',
    '.title{font-weight:600}.sub{color:var(--vscode-descriptionForeground);font-size:.9em}',
    '.state.on{color:var(--vscode-charts-blue)}.state.ok{color:var(--vscode-charts-green)}.state.wait{color:var(--vscode-charts-yellow)}.state.bad{color:var(--vscode-errorForeground)}',
    '.ultra,.effort{color:var(--vscode-charts-purple)}',
    '.permit{color:var(--vscode-editorWarning-foreground);font-weight:600;margin-top:4px}',
    '.prompt{white-space:pre-wrap;color:var(--vscode-descriptionForeground);margin-top:6px;max-height:4.5em;overflow:hidden}',
    '.buttons{margin-top:8px}button{background:var(--vscode-button-secondaryBackground);color:var(--vscode-button-secondaryForeground);border:none;padding:3px 10px;margin-right:6px;cursor:pointer}',
    'button:hover{background:var(--vscode-button-secondaryHoverBackground)}',
    '#pin{color:var(--vscode-charts-purple);margin:8px 0 0}#pin:empty{display:none}',
    '#earlier{color:var(--vscode-descriptionForeground);font-size:.9em;margin:8px 0 0}#earlier:empty{display:none}',
    '.row{padding:2px 0}.text{white-space:pre-wrap;margin:8px 0}',
    '.tool{font-family:var(--vscode-editor-font-family);color:var(--vscode-textLink-foreground)}.tool .arg{color:var(--vscode-foreground)}',
    '.res{font-family:var(--vscode-editor-font-family);white-space:pre-wrap;color:var(--vscode-descriptionForeground);padding-left:1.2em}',
    '.more,.clock{color:var(--vscode-descriptionForeground)}.clock:not(:empty)::before{content:" \\00b7 "}',
    '.plus{color:var(--vscode-charts-green)}.minus{color:var(--vscode-charts-red)}',
    '.err,.tool.err .name{color:var(--vscode-errorForeground)}.warn{color:var(--vscode-editorWarning-foreground)}',
    '.init,.note,.result{color:var(--vscode-descriptionForeground);font-size:.9em}.result{margin-top:8px}',
    '.d1{margin-left:1.5em}.d2{margin-left:3em}.d3{margin-left:4.5em}'
].join('');

// The page's own script: rows put in or replaced by their i, the clocks
// ticked each second, the buttons' clicks handed to the extension. A row is
// found by a map of i to its element, never by a look through the page: a
// full batch - the page loaded again - is thousands of rows. That batch is
// built apart and put in at once. A row changed after it was dropped is
// left out, and only the last MAX_ROWS are kept.
function pageScript(idJson) {
    return '(function(){' +
        'var api=acquireVsCodeApi();api.setState({jobId:' + idJson + '});' +
        'var fmt=' + fmtDur.toString() + ';' +
        'var head=document.getElementById("head"),pin=document.getElementById("pin"),earlier=document.getElementById("earlier"),rows=document.getElementById("rows");' +
        'var follow=true,running=false,byI=new Map(),last=-1,MAX=' + MAX_ROWS + ';' +
        'function put(r,into){var t=document.createElement("template");t.innerHTML=r.html;var el=t.content.firstElementChild;if(!el)return;' +
        'var old=byI.get(r.i);if(old){old.replaceWith(el);byI.set(r.i,el);return;}' +
        'if(r.i<=last)return;into.appendChild(el);byI.set(r.i,el);last=r.i;}' +
        'function atBottom(){return window.innerHeight+window.scrollY>=document.body.scrollHeight-8;}' +
        'window.addEventListener("scroll",function(){follow=atBottom();});' +
        'function tick(){var now=Date.now();' +
        'document.querySelectorAll("[data-since] .clock, .tick").forEach(function(c){var r=c.classList.contains("tick")?c:c.parentElement;' +
        'c.textContent=running?(c.classList.contains("tick")?"":"running ")+fmt(now-Number(r.getAttribute("data-since"))):"";});' +
        'document.querySelectorAll(".ago").forEach(function(a){var m=Math.floor((now-Number(a.getAttribute("data-at")))/60000);a.textContent=m<1?"just now":m+" min ago";});}' +
        'window.addEventListener("message",function(e){var m=e.data||{};' +
        'if(typeof m.head==="string")head.innerHTML=m.head;' +
        'if(typeof m.pin==="string")pin.textContent=m.pin;' +
        'if(typeof m.earlier==="string")earlier.textContent=m.earlier;' +
        'if(typeof m.running==="boolean")running=m.running;' +
        'if(m.reset){rows.textContent="";byI=new Map();last=-1;var f=document.createDocumentFragment();' +
        '(m.rows||[]).forEach(function(r){put(r,f);});rows.appendChild(f);}' +
        'else(m.rows||[]).forEach(function(r){put(r,rows);});' +
        'while(byI.size>MAX){var first=rows.firstElementChild;if(!first)break;byI.delete(Number(first.getAttribute("data-i")));first.remove();}' +
        'tick();if(follow)window.scrollTo(0,document.body.scrollHeight);});' +
        'document.addEventListener("click",function(e){var b=e.target.closest("[data-act]");if(b)api.postMessage({type:b.getAttribute("data-act")});});' +
        'setInterval(tick,1000);api.postMessage({type:"ready"});' +
        '})();';
}

// A log read in pieces: the bytes after the last newline are kept until the
// rest of their line comes, so a line is only taken whole. Bytes, not text:
// a piece may end inside a character. state: { rest: Buffer }. Pure but for
// state.rest. Returns the whole lines in chunk.
function takeLines(state, chunk) {
    const buf = state.rest && state.rest.length ? Buffer.concat([state.rest, chunk]) : chunk;
    const out = [];
    let from = 0;
    for (let i = buf.indexOf(10); i >= 0; i = buf.indexOf(10, from)) {
        out.push(buf.toString('utf8', from, i).replace(/\r$/, ''));
        from = i + 1;
    }
    state.rest = buf.subarray(from);
    return out;
}

module.exports = {
    LARGE, MAX_ROWS, newParser, watchItems, pinnedTodo, itemHtml, headerHtml, stateText, pageHtml, esc, fmtDur, hhmm, takeLines,
    _toolArg: toolArg, _editSize: editSize, _clip: clip
};
