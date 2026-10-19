//! JSON as PowerShell reads it (SPEC 2.2): tolerant of what PS tolerates,
//! and looked into with PowerShell's rules - property names case-blind,
//! truthiness and `-eq` as the scripts' `if` tests see them.
//!
//! [parse_tolerant_in] reads a file as [Read-ChatqJson](src/queue.ps1)'s
//! `Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json` does under either
//! PowerShell, and says whether it needed a repair. It goes through one
//! grammar per edition (`ps_read`: 5.1's JavaScriptSerializer, pwsh 7's
//! Newtonsoft), which stream.rs reads the output lines of
//! [Update-ChatqClaudeState](src/queue.ps1) with too, so a file and a line
//! are read alike. [to_pretty], chatqd's writer, is serde_json's plain one,
//! the same for either edition. Vector: native/vectors/json-compat.json.

use crate::time::{self, Flavour, Made};
use crate::utf8;
use chrono::FixedOffset;
use regex::Regex;
use serde_json::{Map, Number, Value};
use std::borrow::Cow;
use std::sync::LazyLock;

/// A file as [Read-ChatqJson](src/queue.ps1) reads it, and whether it
/// needed a repair: a byte that did not decode (or was dropped at the end),
/// or a lone surrogate escape. chatqd never rewrites such a file itself; a
/// write to it goes through a `job-write` step (SPEC 2.2), and one that is
/// `lossy` is no different.
#[derive(Debug, Clone, PartialEq)]
pub struct Tolerant {
    /// The value, or None where `Read-ChatqJson` gives `$null`: no file
    /// text, a parse error, or a name ConvertFrom-Json refuses. A file of
    /// comments alone is pwsh 7's `$null` read without a throw: JSON null.
    pub value: Option<Value>,
    /// What `Read-ChatqJson` read is not the file as written: a byte did not
    /// decode, or was dropped at the end, or a lone surrogate escape was read
    /// as U+FFFD. A U+FFFD the file itself holds is no repair.
    pub repaired: bool,
    /// The value holds a number JSON cannot: a `NaN`, `Infinity` or
    /// `-Infinity` (5.1 reads the words, pwsh 7 also `1e400`) is held as its
    /// `[string]` text, which `if`, `[string]` and `[int]` treat as PS
    /// treats the double. Written back, it would be a string.
    pub lossy: bool,
}

/// `Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json`, as
/// [Read-ChatqJson](src/queue.ps1) runs it under the PowerShell `fl`:
/// - the bytes decoded as that .NET decodes them ([utf8::read_text]): a
///   byte-order mark followed, an invalid sequence U+FFFD;
/// - text that is empty or white space alone: `$null`, with no throw;
/// - the grammar that edition's ConvertFrom-Json reads. 5.1's
///   JavaScriptSerializer takes single quotes, bare names (`{quiet-hours:
///   1}`), `NaN`, raw control characters in a string and a spaced `\u`
///   escape, and no comment or trailing comma. pwsh 7's Newtonsoft takes
///   `//` and `/* */` comments (not between a name and its colon, nor a
///   bare `//` or an open `/*` at the end), trailing commas, empty list
///   slots, `undefined`, `NaN`, `Infinity`, octal and hex, and bare names of
///   letters, digits, `_` and `$`;
/// - a `\uD800`-`\uDFFF` escape that is not half of a pair read as U+FFFD,
///   as both ConvertFrom-Json do;
/// - an empty name, two names that differ only by case
///   (`OrdinalIgnoreCase`, as each .NET folds), or one of PSObject's own
///   (`psobject`, `psbase`, ...) refused, at any depth: `$null`, as both
///   throw; 5.1 drops a scalar `__type`;
/// - a name given twice keeps its last value: in its first place on 5.1,
///   moved to the end on pwsh 7;
/// - nesting past what that PowerShell reads refused: 102 values deep on
///   5.1, which counts a number or string too, 1024 containers on pwsh 7.
///
/// Strings stay strings ([ps_dates_in] says which ones a PowerShell turns
/// into a `[datetime]`; one out of a DateTime's range makes the read
/// throw) and the top level is not unrolled ([ps_return]). Numbers are
/// held by value: a 5.1 decimal's trailing zeros are lost, and a non-finite
/// one is text ([Tolerant::lossy]).
pub fn parse_tolerant_in(bytes: &[u8], fl: Flavour) -> Tolerant {
    read(bytes, fl, None).0
}

/// Every string of the file that ConvertFrom-Json under `fl` makes a
/// `[datetime]` of, as (JSON pointer into [parse_tolerant_in]'s value, the
/// date's `.ToString('o')` with `local` as the machine's zone):
/// - 5.1 (JavaScriptSerializer): only a value written
///   `"\/Date(<ms>[letter|+hhmm|-hhmm])\/"` - escaped so, as 5.1's
///   ConvertTo-Json writes it - is one, Kind Utc;
/// - pwsh 7 (Newtonsoft): `/Date(<ms>)/` however escaped (Kind Utc, or
///   Local with an offset), and ISO `yyyy-MM-ddTHH:mm:ss[.f{1,7}][Z|±hh[:]mm]`
///   (Utc, Local made from the offset, or Unspecified), as its parser reads
///   them, quirks included.
///
/// Empty where the file does not parse.
pub fn ps_dates_in(bytes: &[u8], fl: Flavour, local: FixedOffset) -> Vec<(String, String)> {
    read(bytes, fl, Some(local)).1
}

/// What [Read-ChatqJson](src/queue.ps1)'s `return (... | ConvertFrom-Json)`
/// hands its caller for a top-level array: PowerShell unrolls it. 5.1's
/// ConvertFrom-Json writes the array as one object and `return` unrolls it
/// once; pwsh 7's unrolls it itself and `return` unrolls a single element
/// again. Either way no element is `$null`, one is that element, more stay
/// an array. Anything else is returned as it is.
pub fn ps_return(v: Option<Value>, fl: Flavour) -> Option<Value> {
    match v {
        Some(Value::Array(a)) => {
            if fl == Flavour::Core && a.len() == 1 {
                match a.into_iter().next() {
                    Some(Value::Array(inner)) => unroll(inner),
                    one => one,
                }
            } else {
                unroll(a)
            }
        }
        v => v,
    }
}

fn unroll(mut a: Vec<Value>) -> Option<Value> {
    match a.len() {
        0 => None,
        1 => a.pop(),
        _ => Some(Value::Array(a)),
    }
}

/// chatqd's writer for the files it writes (SPEC 2.2): `serde_json`, keys in
/// their order, pretty-printed (two-space indents, LF, no final newline).
/// Byte equality with [Save-ChatqJson](src/queue.ps1)'s `ConvertTo-Json
/// -Depth 8` is not the aim; that both PowerShells read back the same value
/// is, and json-compat.json's reverse cases pin it.
pub fn to_pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// Every `\uD800`-`\uDFFF` escape that is not half of a pair becomes `\uFFFD`.
pub fn fix_lone_surrogates(text: &str) -> Cow<'_, str> {
    if !text.contains("\\u") {
        return Cow::Borrowed(text);
    }
    let b = text.as_bytes();
    let hex = |at: usize| -> Option<u16> {
        if at + 6 <= b.len() && b[at] == b'\\' && b[at + 1] == b'u' {
            u16::from_str_radix(std::str::from_utf8(&b[at + 2..at + 6]).ok()?, 16).ok()
        } else {
            None
        }
    };
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut i = 0;
    let mut changed = false;
    while i < b.len() {
        if b[i] != b'\\' {
            i += 1;
            continue;
        }
        match hex(i) {
            Some(0xD800..=0xDBFF) if matches!(hex(i + 6), Some(0xDC00..=0xDFFF)) => i += 12,
            Some(0xD800..=0xDFFF) => {
                out.push_str(&text[last..i]);
                out.push_str("\\uFFFD");
                i += 6;
                last = i;
                changed = true;
            }
            // any other escape, \\ included, is two characters to step over
            _ => i += 2,
        }
    }
    if !changed {
        return Cow::Borrowed(text);
    }
    out.push_str(&text[last..]);
    Cow::Owned(out)
}

fn read(
    bytes: &[u8],
    fl: Flavour,
    local: Option<FixedOffset>,
) -> (Tolerant, Vec<(String, String)>) {
    let (text, replaced) = utf8::read_text(bytes, fl);
    let lone = matches!(fix_lone_surrogates(&text), Cow::Owned(_));
    let repaired = replaced || lone;
    let none = Tolerant {
        value: None,
        repaired,
        lossy: false,
    };
    if text.chars().all(char::is_whitespace) {
        return (none, Vec::new());
    }
    let s: Vec<char> = text.chars().collect();
    let read = on_deep_stack(|capped| {
        let mut dates = local.map(|zone| Dates {
            zone,
            path: String::new(),
            found: Vec::new(),
        });
        let v = ps_read(&s, fl, dates.as_mut(), capped)?;
        let (value, lossy) = to_value(v);
        Ok((value, lossy, dates.map(|d| d.found).unwrap_or_default()))
    });
    match read {
        Ok((value, lossy, found)) => (
            Tolerant {
                value: Some(value),
                repaired,
                lossy,
            },
            found,
        ),
        Err(_) => (none, Vec::new()),
    }
}

/// A read value as serde_json holds it, and whether it is [Tolerant::lossy]:
/// a decimal or big integer by its digits (the nearest double past a u64),
/// a non-finite double as the text PowerShell's `[string]` gives it, and a
/// pwsh 7 BigInteger past a double's range as its digits, which `if` and
/// `[string]` treat as PS treats the number.
/// Deferred: DEFERRED.md "Numbers as a JSON read holds them"
fn to_value(v: PsVal) -> (Value, bool) {
    let mut lossy = false;
    let value = lower(v, &mut lossy);
    (value, lossy)
}

fn lower(v: PsVal, lossy: &mut bool) -> Value {
    let mut digits = |t: &str| match serde_json::from_str::<Number>(t) {
        Ok(n) => Value::Number(n),
        Err(_) => {
            *lossy = true;
            Value::String(t.to_owned())
        }
    };
    match v {
        PsVal::Null => Value::Null,
        PsVal::Bool(b) => Value::Bool(b),
        PsVal::Int(n) => Value::Number(Number::from(n)),
        PsVal::Dec { neg, mant, scale } => {
            let sign = if neg { "-" } else { "" };
            if scale == 0 {
                digits(&format!("{sign}{mant}"))
            } else {
                digits(&format!("{sign}{mant}e-{scale}"))
            }
        }
        PsVal::Big(t) => digits(&t),
        PsVal::Dbl(d) => match Number::from_f64(d) {
            Some(n) => Value::Number(n),
            None => {
                *lossy = true;
                let word = if d.is_nan() {
                    "NaN"
                } else if d > 0.0 {
                    "Infinity"
                } else {
                    "-Infinity"
                };
                Value::String(word.to_owned())
            }
        },
        PsVal::Str(s) => Value::String(s),
        PsVal::Arr(a) => Value::Array(a.into_iter().map(|x| lower(x, lossy)).collect()),
        PsVal::Obj(m) => Value::Object(
            m.into_iter()
                .map(|(k, x)| (k, lower(x, lossy)))
                .collect::<Map<String, Value>>(),
        ),
    }
}

/// Where the dates found so far are, while [ps_dates_in] looks for them.
pub(crate) struct Dates {
    zone: FixedOffset,
    /// the JSON pointer of the value being read
    path: String,
    found: Vec<(String, String)>,
}

/// A character as `OrdinalIgnoreCase` compares it: by its simple
/// upper case, but never one that is ASCII - both .NETs keep `ı` and `ſ`
/// apart from `I` and `S`. 5.1 compares with Windows' own table, which is
/// narrower: UTF-16 units, so nothing past U+FFFF; only a letter its upper
/// case maps back to (not `µ`, `ς` or `ǅ`); and none of Cherokee's small
/// letters or Georgian's Mkhedruli, which have upper cases only since
/// Unicode 8 and 11. A pair one PowerShell folds and the other does not
/// cannot be a vector (pwsh 7's reader of the file folds it): those were
/// probed under both, and `names_fold_as_each_dotnet_folds` holds them.
/// Deferred: DEFERRED.md "Unicode tables scanned on one PC"
fn fold_char(c: char, fl: Flavour) -> char {
    if c.is_ascii() {
        return c.to_ascii_uppercase();
    }
    let up = simple_upper(c);
    if up.is_ascii() {
        return c;
    }
    if fl == Flavour::Desktop {
        let mut back = up.to_lowercase();
        let pair = back.next() == Some(c) && back.next().is_none();
        let newer = matches!(c,
            '\u{10D0}'..='\u{10FA}' | '\u{10FD}'..='\u{10FF}' | '\u{13F8}'..='\u{13FD}' | '\u{AB70}'..='\u{ABBF}');
        if u32::from(c) > 0xFFFF || !pair || newer {
            return c;
        }
    }
    up
}

/// Unicode's simple upper-case mapping, as the .NETs' tables hold it:
/// `to_uppercase` where that is one character; where it is more (a full
/// mapping), the letter itself, but for the Greek letters with a iota
/// below, whose simple mapping is the same letter with a iota beside.
pub(crate) fn simple_upper(c: char) -> char {
    let mut up = c.to_uppercase();
    if let (Some(u), None) = (up.next(), up.next()) {
        return u;
    }
    let n = u32::from(c);
    let to = match n {
        0x1F80..=0x1F87 | 0x1F90..=0x1F97 | 0x1FA0..=0x1FA7 => n + 8,
        0x1FB3 | 0x1FC3 | 0x1FF3 => n + 9,
        _ => n,
    };
    char::from_u32(to).unwrap_or(c)
}

/// A value as ConvertFrom-Json hands it to PowerShell: 5.1 makes Int32,
/// Int64, Decimal and Double numbers, pwsh 7 Int64, BigInteger and Double.
/// Objects keep their property order.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum PsVal {
    Null,
    Bool(bool),
    Int(i64),
    /// A .NET decimal: `mant` (at most 96 bits) / 10^`scale`, scale 0..=28.
    Dec {
        neg: bool,
        mant: u128,
        scale: u32,
    },
    /// A BigInteger, as its digits.
    Big(String),
    Dbl(f64),
    Str(String),
    Arr(Vec<PsVal>),
    Obj(Vec<(String, PsVal)>),
}

/// Why [ps_read] gave no value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Fail {
    /// ConvertFrom-Json throws on the text.
    Throws,
    /// A capped read went deeper than it reads on the stack it was given.
    Deep,
}

/// ConvertFrom-Json of `s` under `fl`, as [Read-ChatqJson](src/queue.ps1)
/// and [Update-ChatqClaudeState](src/queue.ps1) run it, before any
/// unrolling: the crate's one grammar for it. 5.1's
/// JavaScriptSerializer ([Flavour::Desktop]) or pwsh 7's Newtonsoft.Json
/// ([Flavour::Core]), each into PowerShell's PSObject build, which refuses
/// an empty name, two names [fold_eq] takes for one, and PSObject's own
/// member names. Every string value is offered to that edition's date
/// reader: one out of a DateTime's range throws, and with `dates` the ones
/// it makes are recorded. `capped` gives up with [Fail::Deep] past
/// [INLINE_DEPTH] levels, for a caller on a small stack.
pub(crate) fn ps_read(
    s: &[char],
    fl: Flavour,
    dates: Option<&mut Dates>,
    capped: bool,
) -> Result<PsVal, Fail> {
    let marks = Marks(dates);
    match fl {
        Flavour::Desktop => Desk {
            s,
            i: 0,
            marks,
            capped,
        }
        .read(),
        Flavour::Core => Newt {
            s,
            i: 0,
            depth: 0,
            marks,
            capped,
        }
        .read(),
    }
}

/// How deep a capped [ps_read] goes before it gives up: real files and
/// stream lines are a few levels deep.
const INLINE_DEPTH: usize = 32;

/// `run` - a read through [ps_read] - capped on this thread; where that
/// went too deep ([Fail::Deep]), the whole read again, uncapped, on a
/// thread of 8 MB, which holds the 1024 levels pwsh 7 reads. The reader
/// recurses, and a caller's own stack may be small: this keeps the
/// ConvertFrom-Json of [Read-ChatqJson](src/queue.ps1) and of
/// [Update-ChatqClaudeState](src/queue.ps1) from overflowing it. A panic
/// on that thread goes on here.
pub(crate) fn on_deep_stack<T: Send>(
    run: impl Fn(bool) -> Result<T, Fail> + Sync,
) -> Result<T, Fail> {
    match run(true) {
        Err(Fail::Deep) => std::thread::scope(|sc| {
            let worker = std::thread::Builder::new()
                .stack_size(8 << 20)
                .spawn_scoped(sc, || run(false));
            match worker {
                Ok(h) => h.join().unwrap_or_else(|p| std::panic::resume_unwind(p)),
                // no thread to read it on: unread, as a throw leaves it
                Err(_) => Err(Fail::Deep),
            }
        }),
        done => done,
    }
}

/// Where the reader is, while dates are looked for ([Dates]).
struct Marks<'a>(Option<&'a mut Dates>);

impl Marks<'_> {
    /// The JSON pointer one step down: the mark to [leave](Marks::leave) at.
    fn enter(&mut self, seg: impl FnOnce() -> String) -> usize {
        let Some(d) = self.0.as_deref_mut() else {
            return 0;
        };
        let mark = d.path.len();
        d.path.push('/');
        d.path
            .push_str(&seg().replace('~', "~0").replace('/', "~1"));
        mark
    }

    fn leave(&mut self, mark: usize) {
        if let Some(d) = self.0.as_deref_mut() {
            d.path.truncate(mark);
        }
    }

    /// A name given again: the dates under its first value went with it.
    fn forget(&mut self, k: &str) {
        let Some(d) = self.0.as_deref_mut() else {
            return;
        };
        let at = format!("{}/{}", d.path, k.replace('~', "~0").replace('/', "~1"));
        let under = format!("{at}/");
        d.found.retain(|(p, _)| *p != at && !p.starts_with(&under));
    }

    /// What the date reader made of the string value here.
    fn date(&mut self, made: Made) -> Result<(), Fail> {
        match made {
            Made::Throws => return Err(Fail::Throws),
            Made::Date(dt) => {
                if let Some(d) = self.0.as_deref_mut() {
                    d.found.push((d.path.clone(), dt.o(d.zone)));
                }
            }
            Made::Text => {}
        }
        Ok(())
    }
}

/// .NET's char.IsLetterOrDigit (letters and decimal digits) on one UTF-16
/// unit: an astral character's halves are neither.
fn letter_or_digit(c: char) -> bool {
    static LETTER_OR_DIGIT: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[\p{L}\p{Nd}]$").expect("a character class"));
    if c.is_ascii() {
        c.is_ascii_alphanumeric()
    } else {
        (c as u32) <= 0xFFFF && LETTER_OR_DIGIT.is_match(c.encode_utf8(&mut [0; 4]))
    }
}

/// PSObject keeps one property per case-blind name: a read object with two
/// such keys fails ConvertFrom-Json.
fn case_twins(m: &[(String, PsVal)], fl: Flavour) -> bool {
    m.iter()
        .enumerate()
        .any(|(i, (k, _))| m[..i].iter().any(|(j, _)| fold_eq(j, k, fl)))
}

/// PSObject's own member names, which no read key may take: an object with
/// one fails ConvertFrom-Json in both PowerShells. ASCII case folding is
/// `OrdinalIgnoreCase` here, as no non-ASCII character folds to ASCII.
fn reserved(m: &[(String, PsVal)]) -> bool {
    m.iter().any(|(k, _)| {
        [
            "psobject",
            "psbase",
            "psadapted",
            "psextended",
            "pstypenames",
        ]
        .iter()
        .any(|r| k.eq_ignore_ascii_case(r))
    })
}

/// Windows PowerShell 5.1's ConvertFrom-Json: JavaScriptSerializer
/// (RecursionLimit 102) and then PowerShell's PSObject build.
struct Desk<'a> {
    s: &'a [char],
    i: usize,
    marks: Marks<'a>,
    capped: bool,
}

impl Desk<'_> {
    fn read(mut self) -> Result<PsVal, Fail> {
        let v = self.value(0)?;
        if self.next_non_ws().is_some() {
            return Err(Fail::Throws);
        }
        Ok(v)
    }

    /// GetNextNonEmptyChar: past char.IsWhiteSpace (NUL is not).
    fn next_non_ws(&mut self) -> Option<char> {
        while let Some(&c) = self.s.get(self.i) {
            self.i += 1;
            if !c.is_whitespace() {
                return Some(c);
            }
        }
        None
    }

    /// DeserializeInternal: every value one deeper, the root at 1.
    fn value(&mut self, depth: usize) -> Result<PsVal, Fail> {
        let depth = depth + 1;
        if depth > 102 {
            return Err(Fail::Throws);
        }
        if self.capped && depth > INLINE_DEPTH {
            return Err(Fail::Deep);
        }
        let Some(c) = self.next_non_ws() else {
            return Ok(PsVal::Null);
        };
        self.i -= 1;
        match c {
            '{' => self.dict(depth),
            '[' => self.list(depth),
            '"' | '\'' => {
                let from = self.i;
                let s = self.string()?;
                // only "\/Date(...)\/" can be one: the raw token decides
                let raw = &self.s[from..self.i];
                if raw.starts_with(&['"', '\\', '/']) {
                    let raw: String = raw.iter().collect();
                    self.marks
                        .date(time::json_date(&s, Some(&raw), Flavour::Desktop))?;
                }
                Ok(PsVal::Str(s))
            }
            _ => desk_primitive(&self.token()),
        }
    }

    fn dict(&mut self, depth: usize) -> Result<PsVal, Fail> {
        self.i += 1;
        let mut m: Vec<(String, PsVal)> = Vec::new();
        let mut first = true;
        let mut c;
        loop {
            c = self.next_non_ws();
            let Some(ch) = c else { break };
            self.i -= 1;
            if ch == ':' {
                return Err(Fail::Throws);
            }
            let mut name = None;
            if ch != '}' {
                let n = self.member_name()?;
                if n.is_empty() || self.next_non_ws() != Some(':') {
                    return Err(Fail::Throws);
                }
                name = Some(n);
            }
            if first {
                first = false;
                if name.is_none() {
                    c = self.next_non_ws();
                    break;
                }
            }
            let at = m.iter().position(|(k, _)| Some(k) == name.as_ref());
            if let (Some(_), Some(n)) = (at, &name) {
                self.marks.forget(n);
            }
            let mark = self.marks.enter(|| name.clone().unwrap_or_default());
            let v = self.value(depth)?;
            self.marks.leave(mark);
            let name = name.ok_or(Fail::Throws)?;
            // dictionary[name] = value: a repeated key keeps its place
            match at {
                Some(at) => m[at].1 = v,
                None => m.push((name, v)),
            }
            c = self.next_non_ws();
            if c == Some('}') {
                break;
            }
            if c != Some(',') {
                return Err(Fail::Throws);
            }
        }
        if c != Some('}') {
            return Err(Fail::Throws);
        }
        // __type names a .NET type: a scalar one is dropped, null kept, a
        // list or object refused
        if let Some(at) = m.iter().position(|(k, _)| k == "__type") {
            match m[at].1 {
                PsVal::Null => {}
                PsVal::Arr(_) | PsVal::Obj(_) => return Err(Fail::Throws),
                _ => {
                    m.remove(at);
                    self.marks.forget("__type");
                }
            }
        }
        if case_twins(&m, Flavour::Desktop) || reserved(&m) {
            return Err(Fail::Throws);
        }
        Ok(PsVal::Obj(m))
    }

    fn member_name(&mut self) -> Result<String, Fail> {
        let Some(c) = self.next_non_ws() else {
            return Ok(String::new());
        };
        self.i -= 1;
        if c == '"' || c == '\'' {
            self.string()
        } else {
            Ok(self.token())
        }
    }

    fn list(&mut self, depth: usize) -> Result<PsVal, Fail> {
        self.i += 1;
        let mut out = Vec::new();
        let mut more = false;
        let mut c;
        loop {
            c = self.next_non_ws();
            if matches!(c, None | Some(']')) {
                break;
            }
            self.i -= 1;
            let mark = self.marks.enter(|| out.len().to_string());
            out.push(self.value(depth)?);
            self.marks.leave(mark);
            more = false;
            c = self.next_non_ws();
            if c == Some(']') {
                break;
            }
            more = true;
            if c != Some(',') {
                return Err(Fail::Throws);
            }
        }
        if more || c != Some(']') {
            return Err(Fail::Throws);
        }
        Ok(PsVal::Arr(out))
    }

    /// DeserializeString: `\uXXXX` is the next four UTF-16 units through
    /// int.Parse(HexNumber); lone surrogates become U+FFFD.
    fn string(&mut self) -> Result<String, Fail> {
        let quote = self.s[self.i];
        self.i += 1;
        let mut buf: Vec<u16> = Vec::new();
        let mut esc = false;
        while let Some(&c) = self.s.get(self.i) {
            self.i += 1;
            if c == '\\' {
                if esc {
                    buf.push(0x5C);
                }
                esc = !esc;
                continue;
            }
            if esc {
                esc = false;
                let u = match c {
                    '"' | '\'' | '/' => c as u16,
                    'b' => 8,
                    'f' => 12,
                    'n' => 10,
                    'r' => 13,
                    't' => 9,
                    'u' => {
                        let four = self.s.get(self.i..self.i + 4).ok_or(Fail::Throws)?;
                        self.i += 4;
                        net_hex(four).ok_or(Fail::Throws)?
                    }
                    _ => return Err(Fail::Throws),
                };
                buf.push(u);
            } else if c == quote {
                return Ok(String::from_utf16_lossy(&buf));
            } else {
                buf.extend_from_slice(c.encode_utf16(&mut [0; 2]));
            }
        }
        Err(Fail::Throws)
    }

    /// DeserializePrimitiveToken: letters and digits (BMP), `. - _ +`.
    fn token(&mut self) -> String {
        let start = self.i;
        while let Some(&c) = self.s.get(self.i) {
            if !(letter_or_digit(c) || matches!(c, '.' | '-' | '_' | '+')) {
                break;
            }
            self.i += 1;
        }
        self.s[start..self.i].iter().collect()
    }
}

/// int.Parse(s, NumberStyles.HexNumber) of four characters: hex digits
/// with spaces either side and NULs after.
fn net_hex(t: &[char]) -> Option<u16> {
    let white = |c: char| c == ' ' || ('\t'..='\r').contains(&c);
    let mut i = 0;
    while i < t.len() && white(t[i]) {
        i += 1;
    }
    let start = i;
    let mut v: u32 = 0;
    while let Some(d) = t.get(i).and_then(|c| c.to_digit(16)) {
        v = v * 16 + d;
        i += 1;
    }
    if i == start {
        return None;
    }
    while i < t.len() && white(t[i]) {
        i += 1;
    }
    while i < t.len() && t[i] == '\0' {
        i += 1;
    }
    (i == t.len()).then_some(v as u16)
}

/// DeserializePrimitiveObject: null, true, false, then Int32, Int64 and
/// decimal when there is no exponent (the integers only with no point),
/// then double; anything else throws.
fn desk_primitive(t: &str) -> Result<PsVal, Fail> {
    match t {
        "null" => return Ok(PsVal::Null),
        "true" => return Ok(PsVal::Bool(true)),
        "false" => return Ok(PsVal::Bool(false)),
        _ => {}
    }
    if !t.contains(['e', 'E']) {
        if !t.contains('.')
            && let Some(n) = net_int(t)
        {
            return Ok(PsVal::Int(n));
        }
        if let Some(d) = net_decimal(t) {
            return Ok(d);
        }
    }
    net_double(t, Flavour::Desktop)
        .map(PsVal::Dbl)
        .ok_or(Fail::Throws)
}

/// Int64.TryParse(NumberStyles.Integer): a sign, then ASCII digits.
fn net_int(t: &str) -> Option<i64> {
    let digits = t.strip_prefix(['+', '-']).unwrap_or(t);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut v: i128 = 0;
    for b in digits.bytes() {
        v = v * 10 + i128::from(b - b'0');
        if v > 1 << 64 {
            return None;
        }
    }
    i64::try_from(if t.starts_with('-') { -v } else { v }).ok()
}

/// decimal.TryParse(NumberStyles.Number) as .NET Framework does it: a sign
/// before or after, one point, up to 50 significant digits kept with their
/// trailing zeros (so the scale), rounded into 96 bits.
fn net_decimal(t: &str) -> Option<PsVal> {
    let b = t.as_bytes();
    let mut i = 0;
    let mut neg = false;
    let mut signed = false;
    if let Some(&c @ (b'+' | b'-')) = b.first() {
        neg = c == b'-';
        signed = true;
        i = 1;
    }
    let mut digits: Vec<u8> = Vec::new();
    let mut exp10: i32 = 0;
    let (mut any, mut nonzero, mut point) = (false, false, false);
    while let Some(&c) = b.get(i) {
        if c.is_ascii_digit() {
            any = true;
            if c != b'0' || nonzero {
                if digits.len() < 50 {
                    digits.push(c);
                }
                if !point {
                    exp10 += 1;
                }
                nonzero = true;
            } else if point {
                exp10 -= 1;
            }
        } else if c == b'.' && !point {
            point = true;
        } else {
            break;
        }
        i += 1;
    }
    if !any {
        return None;
    }
    if let Some(&c @ (b'+' | b'-')) = b.get(i)
        && !signed
    {
        neg = c == b'-';
        i += 1;
    }
    if i != b.len() {
        return None;
    }
    if !nonzero && !point {
        neg = false;
    }
    let (mant, scale) = number_to_decimal(&digits, exp10)?;
    Some(PsVal::Dec { neg, mant, scale })
}

/// .NET Framework's NumberToDecimal: digits while they fit 96 bits and the
/// scale stays under 28, then round half to even on the next digit (looking
/// at most 20 zeros further); a value too big fails.
fn number_to_decimal(digits: &[u8], exp10: i32) -> Option<(u128, u32)> {
    const MAX: u128 = (1 << 96) - 1;
    const TENTH: u128 = 0x1999_9999_9999_9999_9999_9999;
    let at = |i: usize| digits.get(i).copied().unwrap_or(0);
    let mut d: u128 = 0;
    let mut e = exp10;
    if digits.is_empty() {
        e = e.min(0);
    } else {
        if e > 29 {
            return None;
        }
        let mut p = 0;
        while (e > 0 || (at(p) != 0 && e > -28)) && (d < TENTH || (d == TENTH && at(p) <= b'5')) {
            d *= 10;
            if at(p) != 0 {
                d += u128::from(at(p) - b'0');
                p += 1;
            }
            e -= 1;
        }
        let next = at(p);
        p += 1;
        if next >= b'5' {
            let mut round = true;
            let before = if p >= 2 { at(p - 2) } else { b'0' };
            if next == b'5' && (before - b'0').is_multiple_of(2) {
                let mut count = 20;
                while at(p) == b'0' && count != 0 {
                    p += 1;
                    count -= 1;
                }
                if at(p) == 0 || count == 0 {
                    round = false;
                }
            }
            if round {
                d += 1;
                if d > MAX {
                    d = TENTH + 1;
                    e += 1;
                }
            }
        }
    }
    if e > 0 {
        return None;
    }
    if e <= -29 {
        return Some((0, 28));
    }
    Some((d, (-e) as u32))
}

/// double.TryParse(NumberStyles.Float, invariant): a sign, digits, a point,
/// an exponent; `NaN`, `Infinity` and `-Infinity` exactly. .NET Framework
/// fails on overflow, .NET Core gives an infinity.
fn net_double(t: &str, fl: Flavour) -> Option<f64> {
    let b = t.as_bytes();
    let mut i = 0;
    let mut s = String::new();
    if let Some(&c @ (b'+' | b'-')) = b.first() {
        if c == b'-' {
            s.push('-');
        }
        i = 1;
    }
    let mut any = false;
    let mut digits = |s: &mut String, i: &mut usize| {
        while let Some(&c) = b.get(*i).filter(|c| c.is_ascii_digit()) {
            s.push(c as char);
            *i += 1;
            any = true;
        }
    };
    digits(&mut s, &mut i);
    if b.get(i) == Some(&b'.') {
        s.push('.');
        i += 1;
        digits(&mut s, &mut i);
    }
    if !any {
        return special(t);
    }
    if let Some(b'e' | b'E') = b.get(i) {
        let mut j = i + 1;
        let mut e = String::from("e");
        if let Some(&c @ (b'+' | b'-')) = b.get(j) {
            if c == b'-' {
                e.push('-');
            }
            j += 1;
        }
        let start = j;
        while let Some(&c) = b.get(j).filter(|c| c.is_ascii_digit()) {
            e.push(c as char);
            j += 1;
        }
        if j > start {
            s.push_str(&e);
            i = j;
        }
    }
    if i != b.len() {
        return special(t);
    }
    let v: f64 = s.parse().ok()?;
    if v.is_infinite() && fl == Flavour::Desktop {
        return None;
    }
    Some(v)
}

fn special(t: &str) -> Option<f64> {
    match t {
        "NaN" => Some(f64::NAN),
        "Infinity" => Some(f64::INFINITY),
        "-Infinity" => Some(f64::NEG_INFINITY),
        _ => None,
    }
}

/// pwsh 7's ConvertFrom-Json: Newtonsoft.Json's JsonTextReader (MaxDepth
/// 1024) into JObject/JArray, then PowerShell's PSObject build.
struct Newt<'a> {
    s: &'a [char],
    i: usize,
    depth: usize,
    marks: Marks<'a>,
    capped: bool,
}

impl Newt<'_> {
    fn read(mut self) -> Result<PsVal, Fail> {
        let c = loop {
            match self.s.get(self.i) {
                None => return Ok(PsVal::Null),
                Some(&c) if c == '\0' || c.is_whitespace() => self.i += 1,
                Some('/') => self.comment()?,
                Some(&c) => break c,
            }
        };
        let v = self.value(c)?;
        loop {
            match self.s.get(self.i) {
                None => return Ok(v),
                Some(&c) if c == '\0' || c.is_whitespace() => self.i += 1,
                Some('/') => self.comment()?,
                Some(_) => return Err(Fail::Throws),
            }
        }
    }

    /// Past NUL, whitespace and comments to where a value or a property
    /// goes; the end of the line there throws.
    fn skip(&mut self) -> Result<char, Fail> {
        loop {
            match self.s.get(self.i) {
                None => return Err(Fail::Throws),
                Some(&c) if c == '\0' || c.is_whitespace() => self.i += 1,
                Some('/') => self.comment()?,
                Some(&c) => return Ok(c),
            }
        }
    }

    /// ParsePostValue: past NUL, whitespace and comments to the `,` or the
    /// closer after a value, which it takes.
    fn post(&mut self) -> Result<char, Fail> {
        let c = self.skip()?;
        if matches!(c, ',' | '}' | ']' | ')') {
            self.i += 1;
            Ok(c)
        } else {
            Err(Fail::Throws)
        }
    }

    /// ParseValue at `c`, which is not `,` or a closer here. Newtonsoft's
    /// `new Name(args)` constructor throws here, where pwsh 7 reads `new
    /// Date(..)` as a date and drops a property holding any other.
    /// Deferred: DEFERRED.md "pwsh 7's JSON constructors"
    fn value(&mut self, c: char) -> Result<PsVal, Fail> {
        let next = self.s.get(self.i + 1).copied();
        match c {
            '"' | '\'' => {
                let s = self.string()?;
                self.marks.date(time::json_date(&s, None, Flavour::Core))?;
                Ok(PsVal::Str(s))
            }
            't' => self.lit("true", PsVal::Bool(true)),
            'f' => self.lit("false", PsVal::Bool(false)),
            'n' if next == Some('u') => self.lit("null", PsVal::Null),
            'N' => self.lit("NaN", PsVal::Dbl(f64::NAN)),
            'I' => self.lit("Infinity", PsVal::Dbl(f64::INFINITY)),
            '-' if next == Some('I') => self.lit("-Infinity", PsVal::Dbl(f64::NEG_INFINITY)),
            'u' => self.lit("undefined", PsVal::Null),
            '{' => self.object(),
            '[' => self.array(),
            '-' | '.' | '0'..='9' => self.number(),
            _ => Err(Fail::Throws),
        }
    }

    /// MatchValueWithTrailingSeparator: the word, then the end, NUL, a
    /// separator, or a comment.
    fn lit(&mut self, word: &str, v: PsVal) -> Result<PsVal, Fail> {
        for w in word.chars() {
            if self.s.get(self.i) != Some(&w) {
                return Err(Fail::Throws);
            }
            self.i += 1;
        }
        match self.s.get(self.i) {
            None | Some('\0' | '}' | ']' | ',') => Ok(v),
            Some('/') if matches!(self.s.get(self.i + 1), Some('*' | '/')) => Ok(v),
            Some(c) if c.is_whitespace() => Ok(v),
            _ => Err(Fail::Throws),
        }
    }

    fn enter(&mut self) -> Result<(), Fail> {
        self.i += 1;
        self.depth += 1;
        if self.depth > 1024 {
            return Err(Fail::Throws);
        }
        if self.capped && self.depth > INLINE_DEPTH {
            return Err(Fail::Deep);
        }
        Ok(())
    }

    fn object(&mut self) -> Result<PsVal, Fail> {
        self.enter()?;
        let mut m: Vec<(String, PsVal)> = Vec::new();
        loop {
            if self.skip()? == '}' {
                self.i += 1;
                break;
            }
            let name = self.name()?;
            while let Some(&c) = self.s.get(self.i) {
                if c != '\0' && !c.is_whitespace() {
                    break;
                }
                self.i += 1;
            }
            if self.s.get(self.i) != Some(&':') {
                return Err(Fail::Throws);
            }
            self.i += 1;
            if m.iter().any(|(k, _)| *k == name) {
                self.marks.forget(&name);
            }
            let mark = self.marks.enter(|| name.clone());
            let v = match self.skip()? {
                ',' => PsVal::Null,
                c => self.value(c)?,
            };
            self.marks.leave(mark);
            // JTokenWriter: a repeated key is removed and added again
            m.retain(|(k, _)| *k != name);
            m.push((name, v));
            match self.post()? {
                '}' => break,
                ',' => {}
                _ => return Err(Fail::Throws),
            }
        }
        self.depth -= 1;
        if m.iter().any(|(k, _)| k.is_empty()) || case_twins(&m, Flavour::Core) || reserved(&m) {
            return Err(Fail::Throws);
        }
        Ok(PsVal::Obj(m))
    }

    /// A property name: quoted, or letters, digits, `_` and `$` up to
    /// whitespace, NUL or `:`.
    fn name(&mut self) -> Result<String, Fail> {
        let c = self.s[self.i];
        if c == '"' || c == '\'' {
            return self.string();
        }
        let ident = |c: char| letter_or_digit(c) || c == '_' || c == '$';
        if !ident(c) {
            return Err(Fail::Throws);
        }
        let start = self.i;
        loop {
            match self.s.get(self.i) {
                None => return Err(Fail::Throws),
                Some(&c) if ident(c) => self.i += 1,
                Some(&c) if c == ':' || c == '\0' || c.is_whitespace() => break,
                Some(_) => return Err(Fail::Throws),
            }
        }
        Ok(self.s[start..self.i].iter().collect())
    }

    fn array(&mut self) -> Result<PsVal, Fail> {
        self.enter()?;
        let mut out = Vec::new();
        loop {
            match self.skip()? {
                ']' => {
                    self.i += 1;
                    break;
                }
                // an empty slot is undefined: null
                ',' => out.push(PsVal::Null),
                c => {
                    let mark = self.marks.enter(|| out.len().to_string());
                    out.push(self.value(c)?);
                    self.marks.leave(mark);
                }
            }
            match self.post()? {
                ']' => break,
                ',' => {}
                _ => return Err(Fail::Throws),
            }
        }
        self.depth -= 1;
        Ok(PsVal::Arr(out))
    }

    /// ReadStringIntoBuffer: `\uXXXX` exactly four hex digits; lone
    /// surrogates become U+FFFD.
    fn string(&mut self) -> Result<String, Fail> {
        let quote = self.s[self.i];
        self.i += 1;
        let mut buf: Vec<u16> = Vec::new();
        loop {
            let &c = self.s.get(self.i).ok_or(Fail::Throws)?;
            self.i += 1;
            if c == quote {
                return Ok(String::from_utf16_lossy(&buf));
            }
            if c != '\\' {
                buf.extend_from_slice(c.encode_utf16(&mut [0; 2]));
                continue;
            }
            let &e = self.s.get(self.i).ok_or(Fail::Throws)?;
            self.i += 1;
            let u = match e {
                'b' => 8,
                't' => 9,
                'n' => 10,
                'f' => 12,
                'r' => 13,
                '\\' | '"' | '\'' | '/' => e as u16,
                'u' => {
                    let four = self.s.get(self.i..self.i + 4).ok_or(Fail::Throws)?;
                    let mut v = 0;
                    for x in four {
                        v = v * 16 + x.to_digit(16).ok_or(Fail::Throws)?;
                    }
                    self.i += 4;
                    v as u16
                }
                _ => return Err(Fail::Throws),
            };
            buf.push(u);
        }
    }

    /// ReadNumberIntoBuffer and ParseReadNumber: one digit is an Int64;
    /// a leading 0 not before `.`/`e` is octal, or hex after `0x`; then
    /// Int64, BigInteger past it (up to 380 characters), else double.
    fn number(&mut self) -> Result<PsVal, Fail> {
        let start = self.i;
        while let Some(&c) = self.s.get(self.i) {
            match c {
                '-' | '.' | '+' | 'x' | 'X' | '0'..='9' | 'a'..='f' | 'A'..='F' => self.i += 1,
                '\0' | ',' | '}' | ']' | ')' | '/' => break,
                c if c.is_whitespace() => break,
                _ => return Err(Fail::Throws),
            }
        }
        let t: String = self.s[start..self.i].iter().collect();
        let b = t.as_bytes();
        if b.len() == 1 && b[0].is_ascii_digit() {
            return Ok(PsVal::Int(i64::from(b[0] - b'0')));
        }
        if b.len() > 1 && b[0] == b'0' && !matches!(b[1], b'.' | b'e' | b'E') {
            let v = match t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
                Some(hex) => radix_i64(hex, 16),
                None => radix_i64(&t, 8),
            };
            return v.map(PsVal::Int).ok_or(Fail::Throws);
        }
        let (neg, digits) = match t.strip_prefix('-') {
            Some(d) => (true, d),
            None => (false, t.as_str()),
        };
        if !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit()) {
            // Int64TryParse: more than 19 digits overflow whatever they are
            if digits.len() <= 19 {
                let v = digits
                    .bytes()
                    .fold(0i128, |v, c| v * 10 + i128::from(c - b'0'));
                if let Ok(n) = i64::try_from(if neg { -v } else { v }) {
                    return Ok(PsVal::Int(n));
                }
            }
            if t.len() > 380 {
                return Err(Fail::Throws);
            }
            let d = digits.trim_start_matches('0');
            return Ok(PsVal::Big(match (d.is_empty(), neg) {
                (true, _) => "0".into(),
                (false, true) => format!("-{d}"),
                (false, false) => d.into(),
            }));
        }
        net_double(&t, Flavour::Core)
            .map(PsVal::Dbl)
            .ok_or(Fail::Throws)
    }

    /// `/* ... */` or `// ...` up to CR or LF. ParseComment wants a
    /// character after the opener's second one: `//` ending the line throws.
    fn comment(&mut self) -> Result<(), Fail> {
        self.i += 1;
        if self.s.get(self.i + 1).is_none() {
            return Err(Fail::Throws);
        }
        match self.s.get(self.i) {
            Some('*') => {
                self.i += 1;
                loop {
                    let &c = self.s.get(self.i).ok_or(Fail::Throws)?;
                    self.i += 1;
                    if c == '*' && self.s.get(self.i) == Some(&'/') {
                        self.i += 1;
                        return Ok(());
                    }
                }
            }
            Some('/') => {
                while let Some(&c) = self.s.get(self.i) {
                    if c == '\r' || c == '\n' {
                        break;
                    }
                    self.i += 1;
                }
                Ok(())
            }
            _ => Err(Fail::Throws),
        }
    }
}

/// Convert.ToInt64(s, 8 or 16): digits of the base, at most 64 bits, read
/// as two's complement.
fn radix_i64(s: &str, radix: u32) -> Option<i64> {
    if s.is_empty() {
        return None;
    }
    let mut v: u64 = 0;
    for c in s.chars() {
        v = v
            .checked_mul(u64::from(radix))?
            .checked_add(u64::from(c.to_digit(radix)?))?;
    }
    Some(v as i64)
}

/// Two names as `OrdinalIgnoreCase` under `fl` takes them for one: the
/// case twins ConvertFrom-Json refuses in an object ([fold_char] says how each
/// .NET folds).
pub(crate) fn fold_eq(a: &str, b: &str, fl: Flavour) -> bool {
    a.chars()
        .map(|c| fold_char(c, fl))
        .eq(b.chars().map(|c| fold_char(c, fl)))
}

/// A stored property name `$o.wanted` finds, past an exact match:
/// `OrdinalIgnoreCase`, which for an ASCII `wanted` is exactly ASCII case
/// folding, as neither .NET folds a non-ASCII character to ASCII (probed
/// under both: `$o.'Μ'` finds a key `µ` on pwsh 7 alone, which no ASCII
/// name reaches). Every name chatq asks for is ASCII.
pub(crate) fn member_eq(stored: &str, wanted: &str) -> bool {
    stored.eq_ignore_ascii_case(wanted)
}

/// Two strings as `-eq` and a `@{}` key compare them: case-blind by the
/// culture. An approximation - `to_uppercase` past ASCII, which agrees with
/// the culture compare on the fi ligature and on `ß` and `SS` in 5.1 - and
/// not a property lookup ([get] is that).
/// Deferred: DEFERRED.md "PowerShell's culture compares, approximated"
pub fn ieq(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
        || (!(a.is_ascii() && b.is_ascii()) && a.to_uppercase() == b.to_uppercase())
}

/// `$obj.name` / [Get-ChatField](src/live-chats.ps1): the exact name first,
/// then any that differs only by ASCII case, which is what
/// `OrdinalIgnoreCase` finds for the ASCII names chatq asks for: neither
/// .NET folds `ß`, `ſ` or the fi ligature to ASCII. None on a value that is
/// no object.
/// Deferred: DEFERRED.md "A list where chatq writes an object"
pub fn get<'a>(v: Option<&'a Value>, name: &str) -> Option<&'a Value> {
    let m = v?.as_object()?;
    m.get(name)
        .or_else(|| m.iter().find(|(k, _)| member_eq(k, name)).map(|(_, v)| v))
}

/// PowerShell's truthiness, as `if ($x)` sees a value read from JSON. A list
/// of one is its item's truth, but for a list in a list, which is true when
/// the inner list has any item (`LanguagePrimitives.IsTrue` looks no deeper).
pub fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => match a.as_slice() {
            [] => false,
            [Value::Array(inner)] => !inner.is_empty(),
            [x] => truthy(Some(x)),
            _ => true,
        },
        Some(Value::Object(_)) => true,
    }
}

/// `$x -eq $true`: the right side is converted to the left side's type, so
/// the string "true" in any case and any number equal to 1 pass too. On an
/// array, `-eq` filters, and the `if` is true when anything matched.
pub fn eq_true(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => ieq(s, "true"),
        Some(Value::Number(n)) => n.as_f64() == Some(1.0),
        Some(Value::Array(a)) => a.iter().any(|x| eq_true(Some(x))),
        _ => false,
    }
}

/// `$x -eq 'word'` for the string fields the scripts test that way.
pub fn eq_str(v: Option<&Value>, word: &str) -> bool {
    match v {
        Some(Value::String(s)) => ieq(s, word),
        Some(Value::Array(a)) => a.iter().any(|x| eq_str(Some(x), word)),
        _ => false,
    }
}

/// `[string]$x` of a value [Read-ChatqJson](src/queue.ps1) read, by
/// `ps_string`: an object is `@{k=v; ...}`, a double has 15 digits (`1e3`
/// is `1000`), a list joins its items. 5.1's rules: the editions differ
/// only on a negative zero (5.1 `0`, pwsh 7 `-0`), which no caller meets,
/// and a 5.1 decimal's trailing zeros are already lost in the value.
/// Deferred: DEFERRED.md "Numbers as a JSON read holds them"
pub fn to_ps_string(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        v => ps_string(&from_value(v), Flavour::Desktop),
    }
}

/// A value read into serde_json as [ps_string] takes it: an integer past
/// a long is a BigInteger's digits, any other fraction a double.
fn from_value(v: Option<&Value>) -> PsVal {
    match v {
        None | Some(Value::Null) => PsVal::Null,
        Some(Value::Bool(b)) => PsVal::Bool(*b),
        Some(Value::Number(n)) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => PsVal::Int(i),
            (None, Some(u)) => PsVal::Big(u.to_string()),
            _ => PsVal::Dbl(n.as_f64().unwrap_or(f64::NAN)),
        },
        Some(Value::String(s)) => PsVal::Str(s.clone()),
        Some(Value::Array(a)) => PsVal::Arr(a.iter().map(|x| from_value(Some(x))).collect()),
        Some(Value::Object(m)) => PsVal::Obj(
            m.iter()
                .map(|(k, x)| (k.clone(), from_value(Some(x))))
                .collect(),
        ),
    }
}

/// `[string]$v` of what ConvertFrom-Json under `fl` read, as
/// [Update-ChatqClaudeState](src/queue.ps1) and the board's text casts
/// give it: null is "", a bool `True`/`False`, a decimal keeps its scale,
/// a double [g15]; a list joins its items with spaces (a nested list is
/// `System.Object[]`, a nested object ""), an object is `@{k=v; ...}`
/// (empty: "").
pub(crate) fn ps_string(v: &PsVal, fl: Flavour) -> String {
    match v {
        PsVal::Null => String::new(),
        PsVal::Bool(true) => "True".into(),
        PsVal::Bool(false) => "False".into(),
        PsVal::Int(n) => n.to_string(),
        PsVal::Dec { neg, mant, scale } => dec_str(*neg, *mant, *scale),
        PsVal::Big(s) => s.clone(),
        PsVal::Dbl(d) => g15(*d, fl),
        PsVal::Str(s) => s.clone(),
        PsVal::Arr(a) => a
            .iter()
            .map(|x| elem_str(x, fl))
            .collect::<Vec<_>>()
            .join(" "),
        PsVal::Obj(m) if m.is_empty() => String::new(),
        PsVal::Obj(m) => {
            let parts: Vec<String> = m
                .iter()
                .map(|(k, x)| format!("{k}={}", elem_str(x, fl)))
                .collect();
            format!("@{{{}}}", parts.join("; "))
        }
    }
}

/// An item inside a list or an object as `[string]` and `-join` render it:
/// a nested list is `System.Object[]`, a nested object "".
fn elem_str(v: &PsVal, fl: Flavour) -> String {
    match v {
        PsVal::Arr(_) => "System.Object[]".into(),
        PsVal::Obj(_) => String::new(),
        x => ps_string(x, fl),
    }
}

/// A decimal as .NET writes it: every digit of its scale, no exponent, and
/// no sign on a zero.
fn dec_str(neg: bool, mant: u128, scale: u32) -> String {
    let digits = mant.to_string();
    let scale = scale as usize;
    let body = if scale == 0 {
        digits
    } else if digits.len() > scale {
        let (i, f) = digits.split_at(digits.len() - scale);
        format!("{i}.{f}")
    } else {
        format!("0.{}{digits}", "0".repeat(scale - digits.len()))
    };
    if neg && mant != 0 {
        format!("-{body}")
    } else {
        body
    }
}

/// A double as PowerShell's `[string]` writes it in both editions: 15
/// significant digits, trailing zeros dropped, `E+XX` from 1E+15 up and
/// below 1E-04; `NaN`, `Infinity` and `-Infinity` as words.
pub(crate) fn g15(d: f64, fl: Flavour) -> String {
    if d.is_nan() {
        return "NaN".into();
    }
    if d.is_infinite() {
        return if d > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    if d == 0.0 {
        // .NET Core writes a negative zero's sign; .NET Framework does not
        let neg = d.is_sign_negative() && fl == Flavour::Core;
        return if neg { "-0" } else { "0" }.into();
    }
    let sci = format!("{:.14e}", d.abs());
    let (mant, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let digits: String = mant.chars().filter(char::is_ascii_digit).collect();
    let digits = digits.trim_end_matches('0');
    let mut out = String::new();
    if d < 0.0 {
        out.push('-');
    }
    if !(-5 < exp && exp < 15) {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        let sign = if exp < 0 { '-' } else { '+' };
        out.push_str(&format!("E{sign}{:02}", exp.abs()));
    } else if exp >= 0 {
        let whole = exp as usize + 1;
        if digits.len() <= whole {
            out.push_str(digits);
            out.push_str(&"0".repeat(whole - digits.len()));
        } else {
            out.push_str(&digits[..whole]);
            out.push('.');
            out.push_str(&digits[whole..]);
        }
    } else {
        out.push_str("0.");
        out.push_str(&"0".repeat((-exp - 1) as usize));
        out.push_str(digits);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse_tolerant(bytes: &[u8]) -> Option<Value> {
        parse_tolerant_in(bytes, Flavour::Core).value
    }

    #[test]
    fn lone_surrogates_become_replacement() {
        assert_eq!(fix_lone_surrogates(r#""a\uD83D""#), r#""a\uFFFD""#);
        assert_eq!(fix_lone_surrogates(r#""\uDE00x""#), r#""\uFFFDx""#);
        // a whole pair, and an escaped backslash before a u, stay
        assert_eq!(
            fix_lone_surrogates(r#""\uD83D\uDE00""#),
            r#""\uD83D\uDE00""#
        );
        assert_eq!(fix_lone_surrogates(r#""\\uD83D""#), r#""\\uD83D""#);
        let v = parse_tolerant(b"\xEF\xBB\xBF{\"title\":\"cut \\uD83D\"}").unwrap();
        assert_eq!(v["title"], "cut \u{FFFD}");
    }

    #[test]
    fn invalid_utf8_is_replaced_not_refused() {
        let v = parse_tolerant(b"{\"t\":\"a\xFFb\"}").unwrap();
        assert_eq!(v["t"], "a\u{FFFD}b");
        assert!(parse_tolerant(b"{not json").is_none());
    }

    #[test]
    fn repairs_are_marked() {
        let t = |b: &[u8], fl| parse_tolerant_in(b, fl);
        assert!(t(b"{\"t\":\"a\xFFb\"}", Flavour::Desktop).repaired);
        assert!(t(br#"{"t":"\ud83dx"}"#, Flavour::Core).repaired);
        assert!(!t(br#"{"t":"\ud83d\ude00\uFFFD"}"#, Flavour::Core).repaired);
        assert!(!t("{\"t\":\"\u{FFFD}\"}".as_bytes(), Flavour::Core).repaired);
        // 5.1 drops what is cut at the end, and reads on; pwsh 7 cannot
        let cut = b"{\"t\":1}\xE2\x82";
        assert_eq!(t(cut, Flavour::Desktop).value, Some(json!({"t": 1})));
        assert!(t(cut, Flavour::Desktop).repaired);
        assert_eq!(t(cut, Flavour::Core).value, None);
    }

    #[test]
    fn a_number_json_cannot_hold_is_lossy() {
        let t = |b: &[u8], fl| parse_tolerant_in(b, fl);
        for fl in [Flavour::Desktop, Flavour::Core] {
            let nan = t(b"{\"a\":[1,-Infinity]}", fl);
            assert_eq!(nan.value, Some(json!({"a": [1, "-Infinity"]})));
            assert!(nan.lossy && !nan.repaired);
            assert!(!t(b"{\"a\":1.5}", fl).lossy);
        }
        assert!(t(b"{\"a\":1e400}", Flavour::Core).lossy);
        // pwsh 7 reads an integer past a double's range as a BigInteger: true
        // and its digits under [string], where null would be false and ''.
        // No vector: 5.1 throws on it, so the two answers never settle
        let digits = format!("1{}", "0".repeat(329));
        let big = t(format!("{{\"a\":{digits}}}").as_bytes(), Flavour::Core);
        assert!(big.lossy && !big.repaired);
        let a = get(big.value.as_ref(), "a");
        assert!(truthy(a));
        assert_eq!(to_ps_string(a), digits);
        assert_eq!(
            t(format!("{{\"a\":{digits}}}").as_bytes(), Flavour::Desktop).value,
            None
        );
        // within a double's range it is the nearest double, as before
        let near = t(
            format!("{{\"a\":1{}}}", "0".repeat(299)).as_bytes(),
            Flavour::Core,
        );
        assert!(!near.lossy);
        assert_eq!(near.value.unwrap()["a"].as_f64(), Some(1e299));
    }

    #[test]
    fn names_as_convertfrom_json_takes_them() {
        let v = |s: &str, fl| parse_tolerant_in(s.as_bytes(), fl).value;
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(v(r#"{"a":1,"A":2}"#, fl), None);
            assert_eq!(v(r#"{"x":[{"":1}]}"#, fl), None);
            assert_eq!(v("{\"\u{E9}\":1,\"\u{C9}\":2}", fl), None);
            let distinct = "{\"\u{131}\":1,\"I\":2,\"\u{17F}\":3,\"S\":4,\"\u{DF}\":5,\"SS\":6}";
            assert!(v(distinct, fl).is_some());
        }
        let dup = r#"{"a":1,"b":2,"a":3}"#;
        let keys = |fl| -> Vec<String> {
            v(dup, fl)
                .unwrap()
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect()
        };
        assert_eq!(keys(Flavour::Desktop), ["a", "b"]);
        assert_eq!(keys(Flavour::Core), ["b", "a"]);
        assert_eq!(v(dup, Flavour::Core).unwrap()["a"], 3);
    }

    #[test]
    fn names_fold_as_each_dotnet_folds() {
        // (a, b, 5.1 takes them for one name, pwsh 7 does), as ConvertFrom-Json
        // under 5.1.22621 and 7.6.6 answered `{"a":1,"b":2}`, and their
        // OrdinalIgnoreCase.Equals with it. A pair the two part on cannot be a
        // vector: pwsh 7's reader of the file would take 5.1's answer for one
        // name and refuse it
        let rows = [
            (0xB5, 0x39C, false, true),
            (0xB5, 0x3BC, false, true),
            (0xFF, 0x178, true, true),
            (0x3C2, 0x3A3, false, true),
            (0x3D0, 0x392, false, true),
            (0x1E9B, 0x1E60, false, true),
            (0x1FBE, 0x399, false, true),
            (0x1C5, 0x1C4, false, true),
            (0x1C6, 0x1C5, false, true),
            (0x1FB3, 0x1FBC, true, true),
            (0xDF, 0x1E9E, false, false),
            (0x10400, 0x10428, false, true),
            (0x2D00, 0x10A0, true, true),
            (0x10D0, 0x1C90, false, true),
            (0xAB70, 0x13A0, false, true),
            (0x2170, 0x2160, true, true),
            (0x24D0, 0x24B6, true, true),
            (0xFF41, 0xFF21, true, true),
            (0x3D1, 0x398, false, true),
            (0xE5, 0x212B, false, false),
            (0x131, 0x49, false, false),
            (0x17F, 0x53, false, false),
            (0x212A, 0x6B, false, false),
            (0x1E9E, 0x73, false, false),
            (0x149, 0x4E, false, false),
        ];
        for (a, b, desktop, core) in rows {
            let [ca, cb] = [a, b].map(|c| char::from_u32(c).expect("a character"));
            let doc = format!("{{\"{ca}\":1,\"{cb}\":2}}");
            for (fl, folds) in [(Flavour::Desktop, desktop), (Flavour::Core, core)] {
                let one = parse_tolerant_in(doc.as_bytes(), fl).value.is_none();
                assert_eq!(one, folds, "{a:04X}/{b:04X} under {fl:?}");
            }
        }
    }

    #[test]
    fn a_constructor_is_refused_a_known_divergence() {
        // pwsh 7.6.6 reads {"a":{date 1 ms},"b":2} and {"b":2} for the first
        // two; 5.1 throws on all. Deferred: DEFERRED.md "pwsh 7's JSON
        // constructors"
        for s in [
            r#"{"a":new Date(1),"b":2}"#,
            r#"{"a":new Foo(1),"b":2}"#,
            "[new Date(1), 2]",
        ] {
            for fl in [Flavour::Desktop, Flavour::Core] {
                assert_eq!(
                    parse_tolerant_in(s.as_bytes(), fl).value,
                    None,
                    "{s} {fl:?}"
                );
            }
        }
    }

    #[test]
    fn a_list_in_a_list_is_true_when_it_has_items() {
        // `if ($o.a)` under 5.1 and 7.6.6 for {"a": ...}
        let t = |s: &str| truthy(Some(&serde_json::from_str(s).unwrap()));
        assert!(t("[[0]]") && t("[[false]]") && t("[[[0]]]") && t("[[null]]"));
        assert!(!t("[[]]") && !t("[0]") && !t("[]"));
        assert!(t("[1]") && t("[0,0]"));
    }

    #[test]
    fn the_top_level_unrolls_as_return_does() {
        let r = |s: &str, fl| ps_return(serde_json::from_str(s).ok(), fl);
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(r("[]", fl), None);
            assert_eq!(r(r#"["x"]"#, fl), Some(json!("x")));
            assert_eq!(r("[1,2]", fl), Some(json!([1, 2])));
            assert_eq!(r("[[1,2]]", fl), Some(json!([1, 2])));
        }
        assert_eq!(r("[[1]]", Flavour::Desktop), Some(json!([1])));
        assert_eq!(r("[[1]]", Flavour::Core), Some(json!(1)));
        assert_eq!(r("[[]]", Flavour::Desktop), Some(json!([])));
        assert_eq!(r("[[]]", Flavour::Core), None);
    }

    #[test]
    fn dates_as_each_convertfrom_json_makes_them() {
        let kst = FixedOffset::east_opt(9 * 3600).unwrap();
        let d = |s: &str, fl| ps_dates_in(s.as_bytes(), fl, kst);
        let doc = r#"{"a":"2026-10-15T01:02:03.1Z","b":"2026-10-15T01:02:03-05:30","c":"2026-10-15T01:02:03","d":"\/Date(1760490123000)\/","e":"/Date(1760490123000+0900)/","f":"2026-10-15T24:00:00Z","g":"2026-02-30T01:02:03Z"}"#;
        let p = |v: &[(&str, &str)]| -> Vec<(String, String)> {
            v.iter()
                .map(|(a, b)| (a.to_string(), b.to_string()))
                .collect()
        };
        assert_eq!(
            d(doc, Flavour::Desktop),
            p(&[("/d", "2025-10-15T01:02:03.0000000Z")])
        );
        assert_eq!(
            d(doc, Flavour::Core),
            p(&[
                ("/a", "2026-10-15T01:02:03.1000000Z"),
                ("/b", "2026-10-15T15:32:03.0000000+09:00"),
                ("/c", "2026-10-15T01:02:03.0000000"),
                ("/d", "2025-10-15T01:02:03.0000000Z"),
                ("/e", "2025-10-15T10:02:03.0000000+09:00"),
                ("/f", "2026-10-16T00:00:00.0000000Z"),
            ])
        );
        // a DateTime out of range makes the whole read throw
        let huge = r#"{"a":"\/Date(99999999999999999)\/"}"#;
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(parse_tolerant_in(huge.as_bytes(), fl).value, None);
        }
    }

    #[test]
    fn nesting_as_deep_as_each_convertfrom_json_reads() {
        // (n; 5.1 reads n lists in each other, n objects around a 1; pwsh 7
        // the same), as ConvertFrom-Json under 5.1.22621 and 7.6.6 answered.
        // Not a vector: the vector files are read by 5.1's ConvertFrom-Json,
        // and an answer this deep would stop it
        let rows = [
            (101, true, true, true, true),
            (102, true, false, true, true),
            (103, false, false, true, true),
            (1024, false, false, true, true),
            (1025, false, false, false, false),
        ];
        let lists = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let objects = |n: usize| format!("{}1{}", "{\"a\":".repeat(n), "}".repeat(n));
        // in a 1 MB thread: the depth costs no calls
        std::thread::Builder::new()
            .stack_size(1 << 20)
            .spawn(move || {
                for (n, dl, dob, cl, cob) in rows {
                    for (fl, l, ob) in [(Flavour::Desktop, dl, dob), (Flavour::Core, cl, cob)] {
                        let read = |s: String| parse_tolerant_in(s.as_bytes(), fl).value.is_some();
                        assert_eq!(read(lists(n)), l, "{n} lists under {fl:?}");
                        assert_eq!(read(objects(n)), ob, "{n} objects under {fl:?}");
                    }
                }
                assert!(parse_tolerant(lists(100_000).as_bytes()).is_none());
            })
            .expect("a thread")
            .join()
            .expect("no stack overflow");
    }

    const D: Flavour = Flavour::Desktop;
    const C: Flavour = Flavour::Core;

    /// [ps_read] of one text, uncapped and without dates.
    fn ps(text: &str, fl: Flavour) -> Option<PsVal> {
        let s: Vec<char> = text.chars().collect();
        ps_read(&s, fl, None, false).ok()
    }

    #[test]
    fn each_edition_reads_its_own_json() {
        // pwsh 7 only: comments, trailing commas, `$` in a bare key, NUL
        // between tokens, an empty slot
        for line in [
            "{\"a\":1,}",
            "{a$b:1}",
            "{\"a\":1 /* c */}",
            "{\"a\":1,\u{0}\"x\":1}",
            "[1,,2]",
        ] {
            assert!(ps(line, C).is_some(), "{line}");
            assert!(ps(line, D).is_none(), "{line}");
        }
        // 5.1 only: a spaced \u escape, a dotted bare key
        for line in ["\"\\u 041\"", "{a.b:1}"] {
            assert!(ps(line, D).is_some(), "{line}");
            assert!(ps(line, C).is_none(), "{line}");
        }
        // pwsh 7's comment wants a character after its opener
        for line in [
            "{\"a\":1}//",
            "{\"a\":1} //",
            "{\"a\":1}/",
            "{\"a\":1}/*",
            "1//",
        ] {
            assert!(ps(line, C).is_none(), "{line}");
        }
        for line in ["{\"a\":1}//x", "{\"a\":1}/**/", "{\"a\":1}//\n"] {
            assert!(ps(line, C).is_some(), "{line}");
        }
        // both: a bare key of letters
        assert!(ps("{a:1}", D).is_some() && ps("{a:1}", C).is_some());
        assert_eq!(ps("\"\\u 041\"", D), Some(PsVal::Str("A".into())));
    }

    #[test]
    fn keys_twin_by_case_as_each_edition_folds() {
        assert!(ps("{\"a\":1,\"A\":2}", D).is_none());
        assert!(ps("{\"é\":1,\"É\":2}", C).is_none());
        assert!(ps("{\"s\":1,\"ſ\":2}", C).is_some());
        assert!(ps("{\"σ\":1,\"ς\":2}", C).is_none());
        assert!(ps("{\"σ\":1,\"ς\":2}", D).is_some());
        assert!(ps("{\"\u{B5}\":1,\"\u{39C}\":2}", D).is_some());
        assert!(ps("{\"\u{B5}\":1,\"\u{39C}\":2}", C).is_none());
        assert_eq!(
            ps("{\"__type\":\"x\",\"a\":1}", D),
            Some(PsVal::Obj(vec![("a".into(), PsVal::Int(1))]))
        );
    }

    /// Probed under both: no vector can hold these, as 5.1's reader of the
    /// file drops a scalar `__type` in pwsh 7's answer and throws on `{}`.
    #[test]
    fn a_type_hint_is_5_1s_alone() {
        let a = || ("a".to_owned(), PsVal::Int(1));
        assert_eq!(
            ps("{\"__type\":{},\"a\":1}", C),
            Some(PsVal::Obj(vec![("__type".into(), PsVal::Obj(vec![])), a()]))
        );
        assert_eq!(ps("{\"__type\":{},\"a\":1}", D), None);
        assert_eq!(
            ps("{\"__type\":\"x\",\"a\":1}", C),
            Some(PsVal::Obj(vec![
                ("__type".into(), PsVal::Str("x".into())),
                a()
            ]))
        );
    }

    #[test]
    fn psobjects_own_member_names_are_refused() {
        for fl in [D, C] {
            for line in [
                "{\"PSObject\":1}",
                "{\"a\":[{\"psbase\":1}]}",
                "{\"a\":{\"PSTYPENAMES\":1}}",
            ] {
                assert!(ps(line, fl).is_none(), "{line}");
            }
            for line in [
                "{\"psobjectx\":1}",
                "{\"p\u{17F}object\":1}",
                "{\"ps\u{AD}base\":1}",
            ] {
                assert!(ps(line, fl).is_some(), "{line}");
            }
        }
    }

    #[test]
    fn twenty_digits_are_a_big_integer_in_pwsh_7() {
        let zero = ps("-00000000000000000000", C).unwrap();
        assert_eq!(zero, PsVal::Big("0".into()));
        assert_eq!(ps("-0000000000000000001", C), Some(PsVal::Int(-1)));
        assert_eq!(
            ps("-00000000000000000001", C),
            Some(PsVal::Big("-1".into()))
        );
        assert_eq!(ps("-00000000000000000001", D), Some(PsVal::Int(-1)));
        assert_eq!(ps("00000000000000000000", C), Some(PsVal::Int(0)));
    }

    #[test]
    fn a_date_out_of_range_throws_in_any_string_value() {
        for (text, fl) in [
            ("[\"\\/Date(99999999999999999)\\/\"]", D),
            ("{\"a\":{\"b\":\"9999-12-31T24:00:00Z\"}}", C),
        ] {
            assert_eq!(ps(text, fl), None, "{text}");
        }
        // a name is never a date
        assert!(ps("{\"9999-12-31T24:00:00Z\":1}", C).is_some());
    }

    #[test]
    fn names_are_case_blind() {
        let v = json!({"Reply": {"On": true}});
        assert_eq!(get(get(Some(&v), "reply"), "on"), Some(&json!(true)));
        assert_eq!(get(Some(&json!("x")), "on"), None);
        // OrdinalIgnoreCase never takes a non-ASCII name for an ASCII one
        let o = json!({"\u{DF}": 1, "\u{17F}": 2, "\u{FB01}": 3});
        for name in ["SS", "S", "FI", "s", "fi"] {
            assert_eq!(get(Some(&o), name), None, "{name}");
        }
    }

    #[test]
    fn powershell_truth() {
        for (v, t) in [
            (json!(null), false),
            (json!(0), false),
            (json!(""), false),
            (json!([]), false),
            (json!([0]), false),
            (json!("False"), true),
            (json!({}), true),
            (json!(2), true),
        ] {
            assert_eq!(truthy(Some(&v)), t, "{v}");
        }
        for (v, t) in [
            (json!(true), true),
            (json!("TRUE"), true),
            (json!(1), true),
            (json!(1.0), true),
            (json!("1"), false),
            (json!(2), false),
            (json!(false), false),
            (json!(null), false),
        ] {
            assert_eq!(eq_true(Some(&v)), t, "{v}");
        }
        assert!(eq_str(Some(&json!("Queued")), "queued"));
        assert!(!eq_str(Some(&json!(1)), "queued"));
    }

    #[test]
    fn strings_as_powershell_casts_them() {
        // probed under both editions with -File
        let v = json!({"x": 1, "o": {"a": 1}, "l": [1, [2]]});
        assert_eq!(to_ps_string(Some(&v)), "@{x=1; o=; l=System.Object[]}");
        for (v, want) in [
            (json!(1e3), "1000"),
            (json!(1e20), "1E+20"),
            (json!(1.5), "1.5"),
            (json!(18446744073709551615u64), "18446744073709551615"),
            (json!([1, "a", true, null]), "1 a True "),
            (json!({}), ""),
        ] {
            assert_eq!(to_ps_string(Some(&v)), want, "{v}");
        }
        assert_eq!(to_ps_string(None), "");
    }
}
