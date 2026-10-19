//! A run's stream state, as [Update-ChatqClaudeState](src/queue.ps1) and
//! [Update-ChatqCodexState](src/queue.ps1) build it line by line into
//! [New-ChatqRunState](src/queue.ps1)'s shape (SPEC 1.2, 2.9). Vector:
//! native/vectors/stream-state.json.
//!
//! Both functions read a line with their PowerShell's ConvertFrom-Json and
//! look into the result with PowerShell's own operators, so each piece is
//! ported here as the PowerShell a [Flavour] names does it:
//!
//! - the JSON reader: the crate's one ConvertFrom-Json grammar, json.rs's
//!   (Windows PowerShell 5.1's JavaScriptSerializer for [Flavour::Desktop],
//!   pwsh 7's Newtonsoft.Json for [Flavour::Core]). The two accept
//!   different lines and build different values from the same one: 5.1
//!   reads `1.50` as a decimal that keeps its scale, `010` as ten and `+5`
//!   at all; pwsh 7 reads `010` as octal, `0x10`, comments, trailing
//!   commas, and unwraps a one-item top-level list (done here);
//! - member access with member enumeration over lists, `-eq` against a
//!   word, `switch`, `[string]`, `-join`, and the truth of a value;
//! - `-match` with .NET's regex classes, through `stand_in`.
//!
//! Not ported, and kept out of the vector: 5.1's `"\/Date(...)\/"` and pwsh
//! 7's ISO-date strings become DateTime there and stay strings here (one
//! out of a DateTime's range throws in both, as there); Newtonsoft's `new`
//! constructors (refused here); culture-ignorable
//! characters other than soft hyphen and NUL in the culture compares
//! (`starts_with`, `word_eq`, 5.1's `ToolIds` keys), and the culture's
//! other equivalences in those keys (`é` and `e` + U+0301, `ß` and `ss`,
//! the Kelvin sign and `k`); case and category tables of a Unicode version
//! other than the regex crate's.

use crate::json::{self, PsVal};
use crate::time::Flavour;
use regex::Regex;
use serde_json::{Map, Number, Value};
use std::sync::LazyLock;

/// `$script:ChatqLimitRx` (src/queue.ps1): a synthetic turn's text that
/// says a usage limit was hit. tests/rx_sync.rs holds it to queue.ps1.
pub const LIMIT_RX: &str = "(?i)hit your (session |usage |weekly |opus |sonnet )?limit|usage limit reached|limit (will )?reset";

/// `$script:ChatqOverloadRx` (src/queue.ps1): a synthetic turn's text that
/// says the API was overloaded. tests/rx_sync.rs holds it to queue.ps1.
pub const OVERLOAD_RX: &str = r"(?i)API Error:\s*5\d\d|\boverloaded(_error)?\b";

/// `$Line.Length -gt 1048576`: a longer line, in UTF-16 units, is skipped.
const CAP: usize = 1_048_576;

/// [New-ChatqRunState](src/queue.ps1)'s hashtable: what one run's stream
/// has said so far, each field named for its PS key. [St::to_json] is how
/// SPEC 3.8 carries it from chatqd to the post-run step.
#[derive(Clone, Debug, PartialEq)]
pub struct St {
    /// `Init`: the stream's init line came (Claude's system init, Codex's
    /// thread.started).
    pub init: bool,
    /// `Started`: the run's OnLine sets it; the update functions never do.
    pub started: bool,
    /// `Session`: the init line's `session_id`, whatever JSON it was.
    pub session: Value,
    /// `Model`: the init line's `model`.
    pub model: Value,
    /// `Mode`: the init line's `permissionMode`.
    pub mode: Value,
    /// `Version`: the init line's `claude_code_version`.
    pub version: Value,
    /// `Limit`: the rate_limit_event line whose `rate_limit_info.status`
    /// said rejected (PS holds that line's `rate_limit_info`).
    pub limit: Option<String>,
    /// `Rate`: the last rate_limit_event line, or None when its
    /// `rate_limit_info` was null or missing (PS holds the info).
    pub rate: Option<String>,
    /// `SyntheticLimit`: a `<synthetic>` turn's joined text that matched
    /// [LIMIT_RX].
    pub synthetic_limit: Option<String>,
    /// `Overloaded`: a `<synthetic>` turn's joined text that matched
    /// [OVERLOAD_RX] and not [LIMIT_RX].
    pub overloaded: Option<String>,
    /// `Retries`: system api_retry lines.
    pub retries: i64,
    /// `Assistant`: turns other than `<synthetic>` ones (Codex: agent
    /// messages).
    pub assistant: i64,
    /// `LastText`: Claude's last text item as read (any JSON value), or
    /// Codex's last agent message as `[string]`; `""` at first.
    pub last_text: Value,
    /// `Tools`: each tool_use's `[string]` name (Codex: each other item's
    /// type), in order.
    pub tools: Vec<String>,
    /// `Denied`: each permission_denied line's `[string]` tool_name.
    pub denied: Vec<String>,
    /// `Result`: the last result line (PS holds it parsed).
    pub result: Option<String>,
    /// `ToolIds`: tool_use id to name, in first-seen order; ids that differ
    /// only in case are one key (the first spelling), as in PS's `@{}`,
    /// whose 5.1 compare is the culture's, so there soft hyphen and NUL in
    /// an id do not count either.
    pub tool_ids: Vec<(String, String)>,
    /// `PermitServer`: the `[string]` status of the first mcp_servers entry
    /// named chatqpermit in the last init line that had one.
    pub permit_server: Option<String>,
    /// `Thread`: thread.started's `thread_id`, whatever JSON it was.
    pub thread: Value,
    /// `TurnStarted`: a turn.started line came.
    pub turn_started: bool,
    /// `TurnDone`: a turn.completed line came.
    pub turn_done: bool,
    /// `TurnFailed`: the last turn.failed line's `[string]` error.message.
    pub turn_failed: Option<String>,
    /// `Failed`: TurnFailed, or the first error line's `[string]` message
    /// while Failed was still empty.
    pub failed: Option<String>,
}

impl Default for St {
    fn default() -> St {
        St::new()
    }
}

impl St {
    /// [New-ChatqRunState](src/queue.ps1): nothing seen yet.
    pub fn new() -> St {
        St {
            init: false,
            started: false,
            session: Value::Null,
            model: Value::Null,
            mode: Value::Null,
            version: Value::Null,
            limit: None,
            rate: None,
            synthetic_limit: None,
            overloaded: None,
            retries: 0,
            assistant: 0,
            last_text: Value::String(String::new()),
            tools: Vec::new(),
            denied: Vec::new(),
            result: None,
            tool_ids: Vec::new(),
            permit_server: None,
            thread: Value::Null,
            turn_started: false,
            turn_done: false,
            turn_failed: None,
            failed: None,
        }
    }

    /// [Update-ChatqClaudeState](src/queue.ps1): one line of
    /// `claude -p --output-format stream-json`, as the PowerShell `fl`
    /// names reads it. A line the pre-filter drops or the JSON reader
    /// refuses changes nothing.
    pub fn update_claude(&mut self, line: &str, fl: Flavour) {
        if over_cap(line) {
            return;
        }
        let is_assistant = starts_with(line, "{\"type\":\"assistant\"", fl);
        if !is_assistant
            && !line.contains("\"type\":\"result\"")
            && !line.contains("\"type\":\"rate_limit_event\"")
            && !starts_with(line, "{\"type\":\"system\"", fl)
        {
            return;
        }
        let Some(o) = parse(line, fl) else {
            return;
        };
        for item in switch_items(get(&o, "type")) {
            let ty = json::ps_string(&item, fl);
            if word_eq(&ty, "system") {
                self.claude_system(&o, fl);
            }
            if word_eq(&ty, "rate_limit_event") {
                let info = get(&o, "rate_limit_info");
                self.rate = (info != PsVal::Null).then(|| line.to_string());
                if eq_true(&get(&info, "status"), "rejected") {
                    self.limit = Some(line.to_string());
                }
            }
            // a <synthetic> turn returns from the whole function
            if word_eq(&ty, "assistant") && self.claude_assistant(&o, fl) {
                return;
            }
            if word_eq(&ty, "result") {
                self.result = Some(line.to_string());
            }
        }
    }

    /// [Update-ChatqCodexState](src/queue.ps1): one line of
    /// `codex exec --json`, as the PowerShell `fl` names reads it. A line
    /// the JSON reader refuses changes nothing.
    pub fn update_codex(&mut self, line: &str, fl: Flavour) {
        if over_cap(line) {
            return;
        }
        let Some(o) = parse(line, fl) else {
            return;
        };
        for item in switch_items(get(&o, "type")) {
            let ty = json::ps_string(&item, fl);
            if word_eq(&ty, "thread.started") {
                self.init = true;
                self.thread = to_value(&get(&o, "thread_id"));
            }
            if word_eq(&ty, "turn.started") {
                self.turn_started = true;
            }
            if word_eq(&ty, "turn.completed") {
                self.turn_done = true;
            }
            if word_eq(&ty, "turn.failed") {
                let m = json::ps_string(&get(&get(&o, "error"), "message"), fl);
                self.turn_failed = Some(m.clone());
                self.failed = Some(m);
            }
            if word_eq(&ty, "error") && self.failed.as_deref().unwrap_or("").is_empty() {
                self.failed = Some(json::ps_string(&get(&o, "message"), fl));
            }
            if word_eq(&ty, "item.completed") {
                let it = get(&o, "item");
                let kind = get(&it, "type");
                let text = get(&it, "text");
                if eq_true(&kind, "agent_message") && is_true(&text) {
                    self.assistant += 1;
                    self.last_text = Value::String(json::ps_string(&text, fl));
                } else if is_true(&kind) {
                    self.tools.push(json::ps_string(&kind, fl));
                }
            }
        }
    }

    /// St as SPEC 3.8 carries it: New-ChatqRunState's 23 keys in its order,
    /// each by its PS name. Booleans, counts, strings and lists are JSON
    /// values; Session, Model, Mode, Version, Thread and Claude's LastText
    /// are the JSON they were read as (a decimal's trailing zeros and an
    /// integer past 2^64 do not survive); ToolIds is an object, its keys in
    /// ordinal order; Result, Rate and Limit are the raw line each was set
    /// from, which the post-run step reads back with ConvertFrom-Json
    /// (taking `.rate_limit_info` for Rate and Limit), or null.
    pub fn to_json(&self) -> Value {
        let opt = |s: &Option<String>| s.clone().map_or(Value::Null, Value::String);
        let list = |v: &[String]| Value::Array(v.iter().cloned().map(Value::String).collect());
        let mut ids: Vec<&(String, String)> = self.tool_ids.iter().collect();
        ids.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
        let ids: Map<String, Value> = ids
            .into_iter()
            .map(|(k, v)| (k.clone(), Value::String(v.clone())))
            .collect();
        let mut m = Map::new();
        m.insert("Init".into(), Value::Bool(self.init));
        m.insert("Started".into(), Value::Bool(self.started));
        m.insert("Session".into(), self.session.clone());
        m.insert("Model".into(), self.model.clone());
        m.insert("Mode".into(), self.mode.clone());
        m.insert("Version".into(), self.version.clone());
        m.insert("Limit".into(), opt(&self.limit));
        m.insert("Rate".into(), opt(&self.rate));
        m.insert("SyntheticLimit".into(), opt(&self.synthetic_limit));
        m.insert("Overloaded".into(), opt(&self.overloaded));
        m.insert("Retries".into(), Value::from(self.retries));
        m.insert("Assistant".into(), Value::from(self.assistant));
        m.insert("LastText".into(), self.last_text.clone());
        m.insert("Tools".into(), list(&self.tools));
        m.insert("Denied".into(), list(&self.denied));
        m.insert("Result".into(), opt(&self.result));
        m.insert("ToolIds".into(), Value::Object(ids));
        m.insert("PermitServer".into(), opt(&self.permit_server));
        m.insert("Thread".into(), self.thread.clone());
        m.insert("TurnStarted".into(), Value::Bool(self.turn_started));
        m.insert("TurnDone".into(), Value::Bool(self.turn_done));
        m.insert("TurnFailed".into(), opt(&self.turn_failed));
        m.insert("Failed".into(), opt(&self.failed));
        Value::Object(m)
    }

    /// The `'system'` clause.
    fn claude_system(&mut self, o: &PsVal, fl: Flavour) {
        let sub = get(o, "subtype");
        if eq_true(&sub, "init") {
            self.init = true;
            self.session = to_value(&get(o, "session_id"));
            self.model = to_value(&get(o, "model"));
            self.mode = to_value(&get(o, "permissionMode"));
            self.version = to_value(&get(o, "claude_code_version"));
            // @($o.mcp_servers | Where-Object { $_ -and $_.name -eq 'chatqpermit' })
            let permit = pipe(get(o, "mcp_servers"))
                .into_iter()
                .find(|s| is_true(s) && eq_true(&get(s, "name"), "chatqpermit"));
            if let Some(p) = permit {
                self.permit_server = Some(json::ps_string(&get(&p, "status"), fl));
            }
        } else if eq_true(&sub, "permission_denied") && is_true(&get(o, "tool_name")) {
            self.denied.push(json::ps_string(&get(o, "tool_name"), fl));
        } else if eq_true(&sub, "api_retry") {
            self.retries += 1;
        }
    }

    /// The `'assistant'` clause; true when it hit the `<synthetic>` branch's
    /// `return`.
    fn claude_assistant(&mut self, o: &PsVal, fl: Flavour) -> bool {
        let msg = get(o, "message");
        let content = pipe(get(&msg, "content"));
        // @($o.message.content | Where-Object { $_.type -eq 'text' -and $_.text } | ForEach-Object { $_.text })
        let texts: Vec<PsVal> = content
            .iter()
            .filter(|c| eq_true(&get(c, "type"), "text") && is_true(&get(c, "text")))
            .flat_map(|c| pipe(get(c, "text")))
            .collect();
        if eq_true(&get(&msg, "model"), "<synthetic>") {
            // `$texts -join ' '`, as [string] of the list joins it
            let t = json::ps_string(&PsVal::Arr(texts), fl);
            if net_match(&LIMIT, &t) {
                self.synthetic_limit = Some(t);
            } else if net_match(&OVERLOAD, &t) {
                self.overloaded = Some(t);
            }
            return true;
        }
        self.assistant += 1;
        // if ($texts) { $St.LastText = $texts[-1] }
        if is_true_list(&texts)
            && let Some(last) = texts.last()
        {
            self.last_text = to_value(last);
        }
        for u in content
            .iter()
            .filter(|c| eq_true(&get(c, "type"), "tool_use"))
        {
            self.tools.push(json::ps_string(&get(u, "name"), fl));
        }
        for u in content
            .iter()
            .filter(|c| eq_true(&get(c, "type"), "tool_use") && is_true(&get(c, "id")))
        {
            let id = json::ps_string(&get(u, "id"), fl);
            let name = json::ps_string(&get(u, "name"), fl);
            match self.tool_ids.iter_mut().find(|(k, _)| same_id(k, &id, fl)) {
                Some(e) => e.1 = name,
                None => self.tool_ids.push((id, name)),
            }
        }
        false
    }
}

fn over_cap(line: &str) -> bool {
    // UTF-8 never has fewer bytes than UTF-16 has units
    line.len() > CAP && line.encode_utf16().count() > CAP
}

/// Characters a culture compare under en-US skips: soft hyphen always, NUL
/// too (`nul`) everywhere but 5.1's StartsWith.
/// Deferred: DEFERRED.md "PowerShell's culture compares, approximated"
fn ignorable(c: char, nul: bool) -> bool {
    c == '\u{AD}' || (nul && c == '\0')
}

/// `$Line.StartsWith(prefix)` for an ASCII prefix: culture-aware under
/// en-US, so ignorable characters in the line do not count.
fn starts_with(line: &str, prefix: &str, fl: Flavour) -> bool {
    let nul = fl == Flavour::Core;
    let mut it = line.chars().filter(|&c| !ignorable(c, nul));
    prefix.chars().all(|p| it.next() == Some(p))
}

/// A string `-eq` an ASCII word: culture-aware and case-blind under en-US,
/// so soft hyphen and NUL do not count in either PowerShell.
fn word_eq(s: &str, word: &str) -> bool {
    let mut it = s.chars().filter(|&c| !ignorable(c, true));
    word.chars()
        .all(|w| it.next().is_some_and(|c| c.eq_ignore_ascii_case(&w)))
        && it.next().is_none()
}

/// `$v -eq 'word'` in an `if`: a list keeps the items that are equal, and is
/// true when it kept any (each kept item is true); a bool is equal to any
/// word when it is true; numbers and objects never are.
fn eq_true(v: &PsVal, word: &str) -> bool {
    match v {
        PsVal::Arr(a) => a
            .iter()
            .any(|x| !matches!(x, PsVal::Arr(_)) && scalar_eq(x, word)),
        x => scalar_eq(x, word),
    }
}

fn scalar_eq(v: &PsVal, word: &str) -> bool {
    match v {
        PsVal::Bool(b) => *b,
        PsVal::Str(s) => word_eq(s, word),
        _ => false,
    }
}

/// `switch ($v)`: a list's items one level down, anything else (null
/// included) once.
fn switch_items(v: PsVal) -> Vec<PsVal> {
    match v {
        PsVal::Arr(a) => a,
        x => vec![x],
    }
}

/// What `$v | ...` sends down a pipeline, and what a ForEach-Object block
/// that outputs `$v` emits: a list's items one level down, anything else
/// (null included) as one item.
fn pipe(v: PsVal) -> Vec<PsVal> {
    switch_items(v)
}

/// `$v.name`: a property by its case-blind name; on a list, member
/// enumeration (each item's value, a list value spread one level, nested
/// lists walked, other items skipped) giving null, the one value, or a list.
fn get(v: &PsVal, name: &str) -> PsVal {
    match v {
        PsVal::Obj(m) => prop(m, name).cloned().unwrap_or(PsVal::Null),
        PsVal::Arr(a) => {
            let mut out = Vec::new();
            enumerate(a, name, &mut out);
            match out.len() {
                0 => PsVal::Null,
                1 => out.swap_remove(0),
                _ => PsVal::Arr(out),
            }
        }
        _ => PsVal::Null,
    }
}

fn prop<'a>(m: &'a [(String, PsVal)], name: &str) -> Option<&'a PsVal> {
    m.iter()
        .find(|(k, _)| json::member_eq(k, name))
        .map(|(_, v)| v)
}

fn enumerate(a: &[PsVal], name: &str, out: &mut Vec<PsVal>) {
    for x in a {
        match x {
            PsVal::Arr(inner) => enumerate(inner, name, out),
            PsVal::Obj(m) => match prop(m, name) {
                Some(PsVal::Arr(v)) => out.extend(v.iter().cloned()),
                Some(v) => out.push(v.clone()),
                None => out.push(PsVal::Null),
            },
            _ => {}
        }
    }
}

/// PowerShell's truth of a value (LanguagePrimitives.IsTrue).
fn is_true(v: &PsVal) -> bool {
    match v {
        PsVal::Null => false,
        PsVal::Bool(b) => *b,
        PsVal::Int(n) => *n != 0,
        PsVal::Dec { mant, .. } => *mant != 0,
        PsVal::Big(s) => s != "0",
        PsVal::Dbl(d) => *d != 0.0,
        PsVal::Str(s) => !s.is_empty(),
        PsVal::Arr(a) => is_true_list(a),
        PsVal::Obj(_) => true,
    }
}

/// A list is false empty, true with two items or more, and with one item
/// is that item's truth, except that a one-item list holding a list is true
/// when the inner list has any item.
fn is_true_list(a: &[PsVal]) -> bool {
    match a {
        [] => false,
        [PsVal::Arr(inner)] => !inner.is_empty(),
        [x] => is_true(x),
        _ => true,
    }
}

/// A value as St's JSON carries it; numbers as tests/vectors/common.ps1's
/// Format-NvNumber writes them (integral ones below 2^53 as integers).
fn to_value(v: &PsVal) -> Value {
    match v {
        PsVal::Null => Value::Null,
        PsVal::Bool(b) => Value::Bool(*b),
        PsVal::Int(n) => Value::from(*n),
        PsVal::Dec { neg, mant, scale } => {
            let sign = if *neg { "-" } else { "" };
            num(format!("{sign}{mant}e-{scale}").parse().unwrap_or(f64::NAN))
        }
        PsVal::Big(s) => serde_json::from_str(s).unwrap_or(Value::Null),
        PsVal::Dbl(d) => num(*d),
        PsVal::Str(s) => Value::String(s.clone()),
        PsVal::Arr(a) => Value::Array(a.iter().map(to_value).collect()),
        PsVal::Obj(m) => Value::Object(m.iter().map(|(k, x)| (k.clone(), to_value(x))).collect()),
    }
}

fn num(d: f64) -> Value {
    if d.fract() == 0.0 && d.abs() < 9_007_199_254_740_992.0 {
        Value::from(d as i64)
    } else {
        Number::from_f64(d).map_or(Value::Null, Value::Number)
    }
}

/// `$Line | ConvertFrom-Json` in the PowerShell `fl` names
/// ([json::ps_read](crate::json)): None when it throws. pwsh 7 sends a
/// top-level list's items down the pipeline, so `$o` is null for an empty
/// one and the item itself for a one-item one.
fn parse(line: &str, fl: Flavour) -> Option<PsVal> {
    let s: Vec<char> = line.chars().collect();
    match json::on_deep_stack(|capped| json::ps_read(&s, fl, None, capped)).ok()? {
        PsVal::Arr(mut a) if fl == Flavour::Core && a.len() < 2 => {
            Some(a.pop().unwrap_or(PsVal::Null))
        }
        v => Some(v),
    }
}

/// Keys equal as 5.1's culture `@{}` compares them, approximated: one
/// simple upper case per character ([json::simple_upper]), but `µ`, `ı` and
/// `ſ` stay themselves. Probed under 5.1: `ᾀ`/`ᾈ`, `ᾳ`/`ᾼ`, `ς`/`Σ` and
/// `ǅ`/`Ǆ` are one key, where its `OrdinalIgnoreCase` parts the last two,
/// and `µ`/`Μ` are two.
/// Deferred: DEFERRED.md "PowerShell's culture compares, approximated"
fn culture_fold_eq(a: &str, b: &str) -> bool {
    let fold = |c: char| {
        if matches!(c, 'µ' | 'ı' | 'ſ') {
            return c;
        }
        json::simple_upper(c)
    };
    a.chars().count() == b.chars().count()
        && a.chars().zip(b.chars()).all(|(x, y)| fold(x) == fold(y))
}

/// Two ids as one key of New-ChatqRunState's `ToolIds = @{}`: case-blind,
/// by the culture in 5.1 (soft hyphen and NUL do not count) and as
/// `OrdinalIgnoreCase` in pwsh 7 ([json::fold_eq], probed to agree with
/// its `@{}` on every pair above).
fn same_id(a: &str, b: &str, fl: Flavour) -> bool {
    match fl {
        Flavour::Desktop => {
            let keep = |s: &str| -> String { s.chars().filter(|&c| !ignorable(c, true)).collect() };
            culture_fold_eq(&keep(a), &keep(b))
        }
        Flavour::Core => json::fold_eq(a, b, Flavour::Core),
    }
}

static DIGIT: LazyLock<Regex> = LazyLock::new(|| class(r"\p{Nd}"));
static WORD: LazyLock<Regex> = LazyLock::new(|| class(r"[\p{L}\p{Mn}\p{Pc}\x{200C}\x{200D}]"));
static LIMIT: LazyLock<Regex> = LazyLock::new(|| Regex::new(LIMIT_RX).expect("LIMIT_RX"));
static OVERLOAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(OVERLOAD_RX).expect("OVERLOAD_RX"));

fn class(set: &str) -> Regex {
    Regex::new(&format!("^{set}$")).expect("a character class")
}

fn is_in(re: &Regex, c: char) -> bool {
    re.is_match(c.encode_utf8(&mut [0; 4]))
}

/// `$t -match` one of the two patterns, as .NET's regex runs it under
/// en-US.
fn net_match(re: &Regex, t: &str) -> bool {
    re.is_match(&stand_in(t))
}

/// `t` in ASCII, each character standing for the classes .NET gives it, so
/// the regex crate matches where .NET would: `\s` and `\d` are Unicode's
/// whitespace and decimal digits, `\b`'s word characters are letters,
/// non-spacing marks, connector punctuation, digits and ZWNJ/ZWJ, each
/// UTF-16 unit on its own (an astral character is two non-word units), and
/// `(?i)` takes `İ` for `i` and the Kelvin sign for `k`. Neither pattern has
/// `.`, a backreference or a lookaround, so whether one matches does not
/// depend on what an ASCII stand-in is beyond its classes.
fn stand_in(t: &str) -> String {
    t.chars()
        .map(|c| match c {
            c if c.is_ascii() => c,
            '\u{130}' => 'i',
            '\u{212A}' => 'k',
            c if c.is_whitespace() => '\t',
            c if (c as u32) > 0xFFFF => '#',
            c if is_in(&DIGIT, c) => '0',
            c if is_in(&WORD, c) => 'q',
            _ => '#',
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const D: Flavour = Flavour::Desktop;
    const C: Flavour = Flavour::Core;

    fn str_of(line: &str, fl: Flavour) -> Option<String> {
        parse(line, fl).map(|v| json::ps_string(&v, fl))
    }

    #[test]
    fn the_stand_in_keeps_the_patterns_own_characters() {
        for p in [LIMIT_RX, OVERLOAD_RX] {
            assert!(!p.contains(['q', '#']), "{p}");
        }
        assert_eq!(stand_in("é١\u{2003}İ\u{212A}😀\u{AD}"), "q0\tik##");
    }

    #[test]
    fn the_patterns_match_as_dotnet_does() {
        assert!(net_match(&OVERLOAD, "API Error:\u{A0}529"));
        assert!(net_match(&OVERLOAD, "API Error: 5٢٩"));
        assert!(!net_match(&OVERLOAD, "API Error: ٥٢٩"));
        assert!(!net_match(&OVERLOAD, "API Error:\u{200B}529"));
        assert!(net_match(&OVERLOAD, "\u{903}overloaded"));
        assert!(!net_match(&OVERLOAD, "é overloadedé"));
        assert!(net_match(&LIMIT, "you hit your wee\u{212A}ly limit"));
        assert!(!net_match(&LIMIT, "you hit your \u{17F}ession limit"));
    }

    #[test]
    fn doubles_take_fifteen_digits() {
        let cases = [
            (0.1 + 0.2, "0.3"),
            (1e15, "1E+15"),
            (1e-5, "1E-05"),
            (1e-4, "0.0001"),
            (123456789012345.0, "123456789012345"),
            (1.5e300, "1.5E+300"),
            (-2.5e-10, "-2.5E-10"),
            (100.0, "100"),
        ];
        for (d, want) in cases {
            assert_eq!(json::g15(d, D), want, "{d}");
        }
        assert_eq!(json::g15(f64::NEG_INFINITY, C), "-Infinity");
    }

    #[test]
    fn decimals_keep_their_scale() {
        assert_eq!(str_of("1.50", D).as_deref(), Some("1.50"));
        assert_eq!(str_of("-.5", D).as_deref(), Some("-0.5"));
        assert_eq!(str_of("5-", D).as_deref(), Some("-5"));
        assert_eq!(
            str_of("12345678901234567890", D).as_deref(),
            Some("12345678901234567890")
        );
        assert_eq!(
            str_of("79228162514264337593543950336", D).as_deref(),
            Some("7.92281625142643E+28")
        );
        let zero = PsVal::Dec {
            neg: true,
            mant: 0,
            scale: 1,
        };
        assert_eq!(json::ps_string(&zero, D), "0.0");
    }

    #[test]
    fn each_edition_reads_its_own_numbers() {
        assert_eq!(str_of("010", D).as_deref(), Some("10"));
        assert_eq!(str_of("010", C).as_deref(), Some("8"));
        assert_eq!(str_of("0x10", D), None);
        assert_eq!(str_of("0xFFFFFFFFFFFFFFFF", C).as_deref(), Some("-1"));
        assert_eq!(str_of("1E400", D), None);
        assert_eq!(str_of("1E400", C).as_deref(), Some("Infinity"));
        assert_eq!(str_of("+5", C), None);
        assert_eq!(
            str_of("79228162514264337593543950336", C).as_deref(),
            Some("79228162514264337593543950336")
        );
    }

    #[test]
    fn pwsh_7_sends_a_short_top_level_list_down_the_pipeline() {
        assert_eq!(str_of("\"\\u 041\"", D).as_deref(), Some("A"));
        assert_eq!(
            parse("[[1,2]]", C),
            Some(PsVal::Arr(vec![PsVal::Int(1), PsVal::Int(2)]))
        );
        assert_eq!(parse("[]", C), Some(PsVal::Null));
        assert_eq!(parse("[]", D), Some(PsVal::Arr(Vec::new())));
        // pwsh 7's BigInteger 0 is as false as 5.1's Int32 0
        assert!(!is_true(&parse("-00000000000000000000", C).unwrap()));
        assert!(!is_true(&parse("-00000000000000000000", D).unwrap()));
    }

    #[test]
    fn deep_lines_read_on_a_small_stack() {
        // as deep as each ConvertFrom-Json reads, and one past, in a 1 MB
        // thread: the reader recurses, and reruns on a stack of its own
        let lists = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let objects = |n: usize| format!("{}1{}", "{\"a\":".repeat(n), "}".repeat(n));
        std::thread::Builder::new()
            .stack_size(1 << 20)
            .spawn(move || {
                assert!(parse(&lists(1024), C).is_some());
                assert!(parse(&objects(1024), C).is_some());
                assert!(parse(&lists(1025), C).is_none());
                assert!(parse(&lists(102), D).is_some());
                assert!(parse(&lists(103), D).is_none());
                assert!(parse(&objects(101), D).is_some());
            })
            .expect("a thread")
            .join()
            .expect("no stack overflow");
    }

    #[test]
    fn ids_are_one_key_as_each_editions_hashtable_compares() {
        for fl in [D, C] {
            assert!(same_id("toolu_AB", "TOOLU_ab", fl));
            assert!(same_id("\u{3C3}", "\u{3C2}", fl));
            assert!(!same_id("i", "\u{131}", fl) && !same_id("s", "\u{17F}", fl));
            assert!(same_id("\u{1F80}", "\u{1F88}", fl) && same_id("\u{1C5}", "\u{1C4}", fl));
        }
        // probed: 5.1's @{} keeps the micro sign apart from Mu, pwsh 7's does
        // not; no vector can hold the pair, as pwsh 7 reads the file
        assert!(!same_id("\u{B5}", "\u{39C}", D) && same_id("\u{B5}", "\u{39C}", C));
        assert!(same_id("a\u{AD}b", "AB", D) && !same_id("a\u{AD}b", "ab", C));
        assert!(same_id("a\u{0}b", "ab", D) && !same_id("a\u{0}b", "ab", C));
    }

    #[test]
    fn culture_compares_skip_soft_hyphens() {
        assert!(starts_with(
            "\u{AD}{\"type\":\"system\"",
            "{\"type\":\"system\"",
            D
        ));
        assert!(!starts_with(
            "{\"type\"\u{0}:\"system\"",
            "{\"type\":\"system\"",
            D
        ));
        assert!(starts_with(
            "{\"type\"\u{0}:\"system\"",
            "{\"type\":\"system\"",
            C
        ));
        assert!(word_eq("Sys\u{AD}tem\u{0}", "system"));
        assert!(!word_eq("system ", "system"));
    }

    #[test]
    fn members_enumerate_through_lists() {
        let v = parse("[{\"a\":[1,2]},{\"b\":3},[{\"a\":4}],5]", D).unwrap();
        assert_eq!(
            get(&v, "A"),
            PsVal::Arr(vec![
                PsVal::Int(1),
                PsVal::Int(2),
                PsVal::Null,
                PsVal::Int(4)
            ])
        );
        let o = parse(
            "{\"a\":1,\"b\":[1,2],\"c\":null,\"e\":{\"f\":\"g\"},\"eo\":{}}",
            C,
        )
        .unwrap();
        assert_eq!(
            json::ps_string(&o, C),
            "@{a=1; b=System.Object[]; c=; e=; eo=}"
        );
    }

    #[test]
    fn st_carries_its_fields_in_order() {
        let mut st = St::new();
        st.update_claude(
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"b\",\"name\":\"N\"},{\"type\":\"tool_use\",\"id\":\"A\",\"name\":\"M\"},{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"L\"}]}}",
            D,
        );
        let j = st.to_json();
        let keys: Vec<&str> = j.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys.len(), 23);
        assert_eq!(keys[..3], ["Init", "Started", "Session"]);
        assert_eq!(j["ToolIds"], serde_json::json!({"A": "L", "b": "N"}));
        assert_eq!(j["Assistant"], 1);
    }
}
