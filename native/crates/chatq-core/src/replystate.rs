//! data/replies.json as [Use-ChatqReplyState](src/phone.ps1) reads it and
//! [Save-ChatqReplyState](src/phone.ps1) writes it: its fixed key set and
//! every prune rule (SPEC 1.3). Vector: native/vectors/reply-state.json.
//!
//! The file is read as [Get-ChatqReplyState](src/phone.ps1) and
//! [Read-ChatqBoardState](src/phone-down.ps1) read it into their state
//! hashtable, each field cast as there, and written as Save-ChatqReplyState
//! and [Get-ChatqBoardState](src/phone-down.ps1) write it, pruned at the
//! save's now. Where the two PowerShells read a value in a way not pinned
//! here - their looser number and date parsing, a list where a map goes, a
//! pwsh 7 DateTime where text goes, a file that needed repair (SPEC 2.2) -
//! the answer is [Error::PsOnly] and the file is left for PowerShell.

use crate::config::read_config;
use crate::fsx;
use crate::json::{self, eq_true, get, truthy};
use crate::paths::Paths;
use crate::time::{self, Flavour, Instant, Made, Zone, parse_stamp_in, stamp_utc};
use crate::utf8;
use chrono::{NaiveDate, TimeDelta, Timelike};
use serde_json::{Map, Number, Value, json};
use std::fmt;
use std::fs::{self, File};
use std::hash::{BuildHasher, RandomState};
use std::io;
use std::path::Path;
use std::thread::sleep;
use std::time::Duration;

/// Why [use_state] did not save: what [Use-ChatqReplyState](src/phone.ps1)
/// throws, and [Error::PsOnly] for a file only PowerShell can answer for.
#[derive(Debug)]
pub enum Error {
    /// [Open-ChatqLock](src/queue.ps1) found replies.lock held for 3 s.
    Locked,
    /// [Get-ChatqReplyState](src/phone.ps1)'s throw at a file that does not
    /// parse after 3 tries, or parses to nothing ($null, false, 0, "", []).
    Unreadable(String),
    /// A cast that throws there (`Cannot convert ...`), such as `[int]` of a
    /// use count that is no number; or a prune time out of .NET's calendar.
    Invalid(String),
    /// What the PowerShells read in ways not pinned here. Nothing was written:
    /// the caller leaves this change to PowerShell.
    PsOnly(String),
    /// The data folder could not be made, or the save failed
    /// ([Save-ChatqText](src/queue.ps1)'s throw).
    Io(io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Locked => f.write_str("data/replies.lock is held by another process"),
            Error::Unreadable(why) => write!(f, "data/replies.json could not be read: {why}"),
            Error::Invalid(why) => write!(
                f,
                "data/replies.json holds what PowerShell cannot convert: {why}"
            ),
            Error::PsOnly(why) => write!(
                f,
                "data/replies.json holds what only PowerShell reads as it does: {why}"
            ),
            Error::Io(e) => write!(f, "data/replies.json: {e}"),
        }
    }
}

impl std::error::Error for Error {}

fn ps_only(why: impl Into<String>) -> Error {
    Error::PsOnly(why.into())
}

fn invalid(why: impl Into<String>) -> Error {
    Error::Invalid(why.into())
}

/// The state hashtable [Get-ChatqReplyState](src/phone.ps1) hands its block:
/// the fields a change of chatqd's may set are public, the rest is carried
/// from the read to the save. Times are UTC instants, as the hashtable holds
/// them as UTC strings.
#[derive(Clone, Debug, Default)]
pub struct ReplyState {
    /// `openUntil`: when the reply window closes
    pub open_until: Option<Instant>,
    /// `since`: where polling starts when there is no `lastId`
    pub since: Option<i64>,
    /// `lastId`: the last message polled
    pub last_id: Option<String>,
    /// `lastPolledAt`
    pub last_polled_at: Option<Instant>,
    /// `lastReplyAt`
    pub last_reply_at: Option<Instant>,
    /// `standing`: listening all the time ([Read-ChatqBoardState](src/phone-down.ps1))
    pub standing: bool,
    /// `composeRefusedAt` ([Read-ChatqBoardState](src/phone-down.ps1))
    pub compose_refused_at: Option<Instant>,
    /// `hotUntil` ([Read-ChatqBoardState](src/phone-down.ps1))
    pub hot_until: Option<Instant>,
    alerts: Vec<(String, Alert)>,
    seen: Vec<(String, Option<Instant>)>,
    refused: Vec<(String, Option<Instant>)>,
    candidates: Vec<Candidate>,
    picks: Vec<(String, Pick)>,
    compose: Vec<Compose>,
    down: Option<Down>,
    down_sent: Vec<(String, DownSent)>,
}

/// One of `alerts`, as Get-ChatqReplyState casts it.
#[derive(Clone, Debug, Default)]
struct Alert {
    at: Option<Instant>,
    expires: Option<Instant>,
    event: String,
    job_id: Option<String>,
    seq: Option<i32>,
    session_id: Option<String>,
    provider: Option<String>,
    title: Option<String>,
    uses: i32,
    path: Option<String>,
    cwd: Option<String>,
    /// there, as `$null` or text, only when the file had it
    home: Option<Option<String>>,
    live: bool,
    usage: Option<String>,
    permit: Option<Permit>,
    mark: Option<String>,
    seen: Option<Instant>,
    len: Option<i64>,
}

/// An alert's `permit`, as [ConvertFrom-ChatqPermitEntry](src/permit.ps1)
/// reads it.
#[derive(Clone, Debug, Default)]
struct Permit {
    run: Option<String>,
    rid: Option<String>,
    digest: Option<String>,
    until: Option<Instant>,
    state: Option<String>,
    tool: Option<String>,
    tool_use_id: Option<String>,
    asked: Option<Instant>,
    answered_at: Option<Instant>,
}

/// One of `pairCandidates`; `d` is carried as read.
#[derive(Clone, Debug)]
struct Candidate {
    id: String,
    pid: String,
    d: Value,
    label: String,
    code: String,
    at: Option<Instant>,
    expires: Option<Instant>,
}

/// One of `picks`, as [Read-ChatqBoardState](src/phone-down.ps1) casts it:
/// each optional field there only when the file had it.
#[derive(Clone, Debug, Default)]
struct Pick {
    kind: String,
    session_id: Option<String>,
    provider: Option<String>,
    path: Option<String>,
    cwd: Option<String>,
    home: Option<Option<String>>,
    title: Option<String>,
    job_id: Option<String>,
    seq: Option<i32>,
    mark: Option<String>,
    len: Option<i64>,
    at: Option<Instant>,
    expires: Option<Instant>,
}

#[derive(Clone, Debug)]
struct Compose {
    at: Option<Instant>,
    act: String,
}

#[derive(Clone, Debug)]
struct Down {
    day: String,
    full: i32,
    other: i32,
}

#[derive(Clone, Debug)]
struct DownSent {
    at: Option<Instant>,
    attached: bool,
}

impl ReplyState {
    /// The file's JSON as [Get-ChatqReplyState](src/phone.ps1) and
    /// [Read-ChatqBoardState](src/phone-down.ps1) read it into the state, in
    /// their order, so the first cast to throw is the one reported. A stamp
    /// with no zone is read as `fl`'s PowerShell reads it, in `zone`. JSON
    /// that is falsy is [Error::Unreadable], as the read throws on it; any
    /// other that is no object is a fresh state.
    /// Deferred: DEFERRED.md "The reply registry's reads left to PowerShell"
    pub fn from_json(j: &Value, fl: Flavour, zone: Zone) -> Result<ReplyState, Error> {
        let r = Rd { fl, zone };
        let mut s = ReplyState::default();
        if !truthy(Some(j)) {
            return Err(Error::Unreadable(String::new()));
        }
        let j = match j {
            Value::Object(_) => Some(j),
            // its fields would be its elements' (member enumeration)
            Value::Array(_) => return Err(ps_only("the file is a list")),
            _ => return Ok(s),
        };
        let f = |name| get(j, name);
        s.open_until = r.date(f("openUntil"))?;
        s.last_polled_at = r.date(f("lastPolledAt"))?;
        s.last_reply_at = r.date(f("lastReplyAt"))?;
        // `if ($j.since -as [int64]) { $s.since = [int64]$j.since }`
        s.since = r.as_i64(f("since"))?.filter(|n| *n != 0);
        s.last_id = r.opt_string(f("lastId"))?;
        if let Some(m) = r.map(f("alerts"), "alerts")? {
            for (k, v) in m {
                if let Some(a) = r.entry(v, "an alert")? {
                    s.alerts.push((k.clone(), r.alert(a)?));
                }
            }
        }
        for (name, out) in [("seen", &mut s.seen), ("refused", &mut s.refused)] {
            if let Some(m) = r.map(f(name), name)? {
                for (k, v) in m {
                    out.push((k.clone(), r.date(Some(v))?));
                }
            }
        }
        if let Some(cs) = f("pairCandidates").filter(|v| truthy(Some(v))) {
            for c in items(cs) {
                // `if (-not ($c -and $c.id -and $c.pid -and $c.d)) { continue }`
                let Some(c) = r.entry(c, "a pairing answer")? else {
                    continue;
                };
                let g = |name| get(Some(c), name);
                if !(truthy(g("id")) && truthy(g("pid")) && truthy(g("d"))) {
                    continue;
                }
                s.candidates.push(Candidate {
                    id: r.string(g("id"))?,
                    pid: r.string(g("pid"))?,
                    d: r.raw(g("d"))?,
                    label: r.string(g("label"))?,
                    code: r.string(g("code"))?,
                    at: r.date(g("at"))?,
                    expires: r.date(g("expires"))?,
                });
            }
        }
        // Read-ChatqBoardState
        s.standing = r.is_true(f("standing"))?;
        s.compose_refused_at = r.date(f("composeRefusedAt"))?;
        s.hot_until = r.date(f("hotUntil"))?;
        // a list's or a text's own properties (Count, Length ...) never pass
        // the name test, so anything but an object holds no pick
        if let Some(Value::Object(m)) = f("picks") {
            for (k, v) in m {
                if !truthy(Some(v)) || !pick_name(k) {
                    continue;
                }
                if let Some(v) = r.entry(v, "a pick")? {
                    s.picks.push((k.clone(), r.pick(v)?));
                }
            }
        }
        if let Some(cs) = f("compose").filter(|v| truthy(Some(v))) {
            for c in items(cs) {
                // `if ($c -and $c.at)`
                let Some(c) = r.entry(c, "a compose act")? else {
                    continue;
                };
                if truthy(get(Some(c), "at")) {
                    s.compose.push(Compose {
                        at: r.date(get(Some(c), "at"))?,
                        act: r.string(get(Some(c), "act"))?,
                    });
                }
            }
        }
        // `if ($J.down -and $J.down.day)`
        if let Some(d) = r.obj(f("down"), "down")? {
            let d = Some(d);
            if truthy(get(d, "day")) {
                s.down = Some(Down {
                    day: r.string(get(d, "day"))?,
                    full: r.int(get(d, "full"))?,
                    other: r.int(get(d, "other"))?,
                });
            }
        }
        if let Some(m) = r.map(f("downSent"), "downSent")? {
            for (k, v) in m {
                if let Some(v) = r.entry(v, "a whole answer sent")? {
                    let v = Some(v);
                    s.down_sent.push((
                        k.clone(),
                        DownSent {
                            at: r.date(get(v, "at"))?,
                            attached: truthy(get(v, "attached")),
                        },
                    ));
                }
            }
        }
        Ok(s)
    }
}

/// How the file is read: which PowerShell, and its zone.
#[derive(Clone, Copy)]
struct Rd {
    fl: Flavour,
    zone: Zone,
}

impl Rd {
    fn alert(self, a: &Value) -> Result<Alert, Error> {
        let f = |name| get(Some(a), name);
        let mut e = Alert {
            at: self.date(f("at"))?,
            expires: self.date(f("expires"))?,
            event: self.string(f("event"))?,
            job_id: self.opt_string(f("jobId"))?,
            seq: self.opt_int(f("seq"))?,
            session_id: self.opt_string(f("sessionId"))?,
            provider: self.opt_string(f("provider"))?,
            title: self.opt_string(f("title"))?,
            uses: self.int(f("uses"))?,
            path: self.opt_string(f("path"))?,
            cwd: self.opt_string(f("cwd"))?,
            ..Alert::default()
        };
        if let Some(h) = f("home") {
            e.home = Some(self.opt_string(Some(h))?);
        }
        e.live = self.is_true(f("live"))?;
        e.usage = self.opt_string(f("usage"))?;
        if truthy(f("permit")) {
            // ConvertFrom-ChatqPermitEntry: Get-ChatField finds nothing on
            // what is no object, so that is a permit of nulls
            let p = |name| get(f("permit"), name);
            e.permit = Some(Permit {
                run: self.permit_string(p("run"))?,
                rid: self.permit_string(p("rid"))?,
                digest: self.permit_string(p("digest"))?,
                until: self.date(p("until"))?,
                state: self.permit_string(p("state"))?,
                tool: self.permit_string(p("tool"))?,
                tool_use_id: self.permit_string(p("toolUseId"))?,
                asked: self.date(p("asked"))?,
                answered_at: self.date(p("answeredAt"))?,
            });
        }
        e.mark = self.opt_string(f("mark"))?;
        if truthy(f("seen")) {
            e.seen = self.date(f("seen"))?;
        }
        if f("len").is_some() {
            e.len = self.as_i64(f("len"))?;
        }
        Ok(e)
    }

    fn pick(self, v: &Value) -> Result<Pick, Error> {
        let f = |name| get(Some(v), name);
        let mut e = Pick {
            kind: self.string(f("kind"))?,
            at: self.date(f("at"))?,
            expires: self.date(f("expires"))?,
            ..Pick::default()
        };
        e.session_id = self.opt_string(f("sessionId"))?;
        e.provider = self.opt_string(f("provider"))?;
        e.path = self.opt_string(f("path"))?;
        e.cwd = self.opt_string(f("cwd"))?;
        e.title = self.opt_string(f("title"))?;
        e.job_id = self.opt_string(f("jobId"))?;
        e.mark = self.opt_string(f("mark"))?;
        e.seq = self.opt_int(f("seq"))?;
        if f("len").is_some() {
            e.len = self.as_i64(f("len"))?;
        }
        if let Some(h) = f("home") {
            e.home = Some(self.opt_string(Some(h))?);
        }
        Ok(e)
    }

    /// Text that is a DateTime once this PowerShell's ConvertFrom-Json has
    /// read it ([time::json_date]; a 5.1 `/Date(ms)/` was escaped, or
    /// [parse] left the file to PowerShell). Cast to text or tested, it is
    /// no longer the text.
    fn datey(self, s: &str) -> bool {
        matches!(time::json_date(s, None, self.fl), Made::Date(_))
    }

    /// `& $iso $v`: [ConvertTo-ChatqDate](src/queue.ps1), as UTC.
    /// Deferred: DEFERRED.md "The reply registry's reads left to PowerShell"
    fn date(self, v: Option<&Value>) -> Result<Option<Instant>, Error> {
        if !truthy(v) {
            return Ok(None);
        }
        match v {
            Some(Value::String(s)) => {
                // pwsh 7's DateTimes, and what it leaves text, in the ISO
                // shapes read alike here; [datetime]::Parse takes the rest
                if self.fl == Flavour::Core && maybe_iso(s) && !newtonsoft_iso(s) {
                    return Err(ps_only(format!("a time pwsh 7 reads its own way: {s}")));
                }
                match parse_stamp_in(s, self.fl, self.zone) {
                    // where ToLocalTime could clamp it, a day from either end
                    Some(t) if t >= ymd(1, 1, 2) && t < ymd(9999, 12, 31) => Ok(Some(t)),
                    Some(_) => Err(ps_only(format!("a time at the end of the calendar: {s}"))),
                    // .NET parses many more shapes, but none without a digit
                    None if s.bytes().any(|b| b.is_ascii_digit()) => {
                        Err(ps_only(format!("a time not read here: {s}")))
                    }
                    None => Ok(None),
                }
            }
            // [datetime]::Parse fails at an integer's text, a bool's and an
            // object's; a fraction's ("1.5") may be a day this year
            Some(Value::Number(n)) if n.is_f64() => Err(ps_only("a fraction where a time goes")),
            Some(Value::Array(_)) => Err(ps_only("a list where a time goes")),
            _ => Ok(None),
        }
    }

    /// `[string]$v`
    fn string(self, v: Option<&Value>) -> Result<String, Error> {
        match v {
            None | Some(Value::Null) => Ok(String::new()),
            Some(Value::Bool(b)) => Ok(if *b { "True" } else { "False" }.into()),
            Some(Value::Number(n)) if !n.is_f64() => Ok(n.to_string()),
            Some(Value::String(s)) if self.datey(s) => {
                Err(ps_only(format!("a time where text goes: {s}")))
            }
            Some(Value::String(s)) => Ok(s.clone()),
            // 5.1 keeps 1.0 a Decimal, "1.0", where 7 has a Double, "1"
            Some(_) => Err(ps_only("a fraction, a list or an object where text goes")),
        }
    }

    /// `if ($v) { [string]$v } else { $null }`
    fn opt_string(self, v: Option<&Value>) -> Result<Option<String>, Error> {
        if truthy(v) {
            self.string(v).map(Some)
        } else {
            Ok(None)
        }
    }

    /// ConvertFrom-ChatqPermitEntry's
    /// `if ($null -ne $v -and '' -ne $v) { [string]$v } else { $null }`
    fn permit_string(self, v: Option<&Value>) -> Result<Option<String>, Error> {
        match v {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if s.is_empty() => Ok(None),
            Some(Value::Array(_)) => Err(ps_only("a list in a permit")),
            _ => self.string(v).map(Some),
        }
    }

    /// `$v -eq $true`, as [crate::json::eq_true]
    fn is_true(self, v: Option<&Value>) -> Result<bool, Error> {
        match v {
            Some(Value::Array(_)) => Err(ps_only("a list where true or false goes")),
            Some(Value::String(s)) if self.datey(s) => {
                Err(ps_only(format!("a time where true or false goes: {s}")))
            }
            _ => Ok(eq_true(v)),
        }
    }

    /// `[int]$v`, which throws at what it cannot convert
    fn int(self, v: Option<&Value>) -> Result<i32, Error> {
        let n = match v {
            None | Some(Value::Null) => 0,
            Some(Value::Bool(b)) => i128::from(*b),
            Some(Value::Number(n)) => rounded(n).unwrap_or(i128::MAX),
            Some(Value::String(s)) => {
                text_int(s)?.ok_or_else(|| invalid(format!("[int] of '{s}'")))?
            }
            Some(_) => return Err(invalid("[int] of a list or an object")),
        };
        i32::try_from(n).map_err(|_| invalid(format!("{n} is past Int32")))
    }

    /// `if ($v) { [int]$v } else { $null }`
    fn opt_int(self, v: Option<&Value>) -> Result<Option<i32>, Error> {
        if truthy(v) {
            self.int(v).map(Some)
        } else {
            Ok(None)
        }
    }

    /// `$v -as [int64]`: None where the cast fails (`$null` casts to 0)
    fn as_i64(self, v: Option<&Value>) -> Result<Option<i64>, Error> {
        let n = match v {
            None | Some(Value::Null) => Some(0),
            Some(Value::Bool(b)) => Some(i128::from(*b)),
            Some(Value::Number(n)) => rounded(n),
            Some(Value::String(s)) => text_int(s)?,
            Some(Value::Object(_)) => None,
            Some(Value::Array(_)) => return Err(ps_only("a list where a number goes")),
        };
        Ok(n.and_then(|n| i64::try_from(n).ok()))
    }

    /// `if ($x)` before `$x.PSObject.Properties` is walked: an object's own.
    /// A list's walk reaches its elements' fields (through SyncRoot), and a
    /// pwsh 7 DateTime's its own (Date, Day ...): only PowerShell follows.
    fn obj<'a>(self, v: Option<&'a Value>, what: &str) -> Result<Option<&'a Value>, Error> {
        match v {
            Some(Value::Object(_)) => Ok(v),
            Some(a @ Value::Array(_)) if truthy(Some(a)) => {
                Err(ps_only(format!("{what} is a list")))
            }
            Some(Value::String(s)) if self.datey(s) => Err(ps_only(format!("{what} is a time"))),
            _ => Ok(None),
        }
    }

    /// [Rd::obj] for a map whose names become a hashtable's keys: a name
    /// out of printable ASCII may fold into another by 5.1's culture rules.
    fn map<'a>(
        self,
        v: Option<&'a Value>,
        what: &str,
    ) -> Result<Option<&'a Map<String, Value>>, Error> {
        let Some(m) = self.obj(v, what)?.and_then(Value::as_object) else {
            return Ok(None);
        };
        if m.keys()
            .any(|k| !k.bytes().all(|b| (0x20..0x7f).contains(&b)))
        {
            return Err(ps_only(format!("a name in {what} out of printable ASCII")));
        }
        Ok(Some(m))
    }

    /// One value in a map or a list, before its fields are read: an object,
    /// or None to pass over. What is falsy is passed over there; a text or a
    /// number has none of the fields, so what it makes is pruned at the save.
    fn entry<'a>(self, v: &'a Value, what: &str) -> Result<Option<&'a Value>, Error> {
        match v {
            Value::Object(_) => Ok(Some(v)),
            Value::Array(_) if truthy(Some(v)) => Err(ps_only(format!("{what} is a list"))),
            _ => Ok(None),
        }
    }

    /// `d = $c.d`, which the save writes back as read: so only one with no
    /// text that either PowerShell made a DateTime, nesting no deeper than
    /// ConvertTo-Json's -Depth 8 was probed to keep.
    fn raw(self, v: Option<&Value>) -> Result<Value, Error> {
        fn plain(r: Rd, v: &Value, depth: usize) -> bool {
            match v {
                Value::String(s) => !r.datey(s),
                Value::Array(a) => depth < 3 && a.iter().all(|x| plain(r, x, depth + 1)),
                Value::Object(m) => depth < 3 && m.values().all(|x| plain(r, x, depth + 1)),
                _ => true,
            }
        }
        let v = v.cloned().unwrap_or(Value::Null);
        if plain(self, &v, 0) {
            Ok(v)
        } else {
            Err(ps_only("a pairing answer's d holds a time or nests deep"))
        }
    }
}

/// `@($v)`: a list's elements, or the value alone.
fn items(v: &Value) -> Vec<&Value> {
    match v {
        Value::Array(a) => a.iter().collect(),
        _ => vec![v],
    }
}

/// A name `-cmatch '^[a-z2-7]{6}$'` passes: .NET's `$` lets one newline
/// follow.
fn pick_name(k: &str) -> bool {
    let k = k.strip_suffix('\n').unwrap_or(k);
    k.len() == 6 && k.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

fn ms_shaped(s: &str) -> bool {
    s.len() >= 8 && s.starts_with("/Date(") && s.ends_with(")/")
}

/// Text Newtonsoft (pwsh 7's ConvertFrom-Json) may make a DateTime: what
/// its ISO test looks at - 19 to 40 long, `yyyy-MM-ddTHH:mm:ss` first.
fn maybe_iso(s: &str) -> bool {
    let b = s.as_bytes();
    (19..=40).contains(&b.len())
        && b[..19]
            .iter()
            .zip(b"dddd-dd-ddTdd:dd:dd")
            .all(|(c, p)| match p {
                b'd' => c.is_ascii_digit(),
                _ => c == p,
            })
}

/// What Newtonsoft does make a DateTime, of [maybe_iso]'s text, in the
/// shapes [parse_stamp_in] reads alike: a real day, an hour to 23, seven
/// fraction digits at most, then nothing, `Z`, or an offset to 14 hours.
fn newtonsoft_iso(s: &str) -> bool {
    if !maybe_iso(s) {
        return false;
    }
    let b = s.as_bytes();
    let two = |x: &[u8], max: u32| {
        x.len() == 2
            && x.iter().all(u8::is_ascii_digit)
            && u32::from(x[0] - b'0') * 10 + u32::from(x[1] - b'0') <= max
    };
    let n = |i: usize| u32::from(b[i] - b'0') * 10 + u32::from(b[i + 1] - b'0');
    let year = n(0) * 100 + n(2);
    if year < 1
        || NaiveDate::from_ymd_opt(year as i32, n(5), n(8)).is_none()
        || n(11) > 23
        || n(14) > 59
        || n(17) > 59
    {
        return false;
    }
    let mut i = 19;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        while i < b.len() && i - start < 7 && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return false;
        }
    }
    match &b[i..] {
        [] | [b'Z' | b'z'] => true,
        [b'+' | b'-', h @ ..] => match h.len() {
            2 => two(h, 14),
            4 => two(&h[..2], 14) && two(&h[2..], 59),
            5 => two(&h[..2], 14) && h[2] == b':' && two(&h[3..], 59),
            _ => false,
        },
        _ => false,
    }
}

fn ymd(y: i32, m: u32, d: u32) -> Instant {
    NaiveDate::from_ymd_opt(y, m, d)
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .expect("a real day")
        .and_utc()
}

/// White space as .NET's integer parse allows around a number.
fn num_trim(s: &str) -> &str {
    s.trim_matches(|c| matches!(c, '\t'..='\r' | ' '))
}

/// Text as `[int]` and `-as [int64]` read a number from it: "" is 0, a plain
/// integer its value, text with no digit none; the rest the PowerShells
/// parse each its own way ("1e3", "0x10", "1kb", " ").
/// Deferred: DEFERRED.md "Numbers as a JSON read holds them"
fn text_int(s: &str) -> Result<Option<i128>, Error> {
    if s.is_empty() {
        return Ok(Some(0));
    }
    let t = num_trim(s);
    let body = t.strip_prefix(['+', '-']).unwrap_or(t);
    if !body.is_empty() && body.bytes().all(|b| b.is_ascii_digit()) {
        let n = body.bytes().fold(0i128, |a, b| {
            a.saturating_mul(10).saturating_add(i128::from(b - b'0'))
        });
        return Ok(Some(if t.starts_with('-') { -n } else { n }));
    }
    if s.trim().is_empty() || s.bytes().any(|b| b.is_ascii_digit()) {
        return Err(ps_only(format!(
            "a number in text read here only as an integer: '{s}'"
        )));
    }
    Ok(None)
}

/// A JSON number as .NET's casts round one: to even.
fn rounded(n: &Number) -> Option<i128> {
    if let Some(i) = n.as_i64() {
        return Some(i.into());
    }
    if let Some(u) = n.as_u64() {
        return Some(u.into());
    }
    let f = n.as_f64()?;
    f.is_finite().then(|| f.round_ties_even() as i128)
}

/// 5.1's JavaScriptSerializer makes a DateTime only of the very text
/// `"\/Date(ms)\/"`; anything that reads as `/Date(ms)/` but was written
/// otherwise stays text there, and [Rd::date] would take it for a time.
fn ms_dates_escaped(v: &Value, raw: &str) -> bool {
    match v {
        Value::String(s) if ms_shaped(s) => {
            raw.contains(&format!("\"\\/Date({})\\/\"", &s[6..s.len() - 2]))
        }
        Value::Array(a) => a.iter().all(|x| ms_dates_escaped(x, raw)),
        Value::Object(m) => m.values().all(|x| ms_dates_escaped(x, raw)),
        _ => true,
    }
}

impl ReplyState {
    /// What [Save-ChatqReplyState](src/phone.ps1) writes for this state at
    /// `now`, `hours` being reply.hours: its 16 keys in its order, pruned -
    /// alerts past their expiry and all but the newest 200; spent nonces once
    /// older than twice the timestamp window and every alert still out, less
    /// 10 minutes; refusals past the hour; pairing answers past their expiry
    /// - and [Get-ChatqBoardState](src/phone-down.ps1)'s board, pruned too.
    pub fn to_json(&self, hours: f64, now: Instant) -> Result<Value, Error> {
        // Get-Date's resolution
        let now = now - TimeDelta::nanoseconds(i64::from(now.nanosecond() % 100));
        let mut live: Vec<_> = self
            .alerts
            .iter()
            .filter(|(_, a)| after(a.expires, now))
            .collect();
        // Sort-Object { [string]$_.Value.at }: the UTC strings sort in time
        // order, a missing one ("") first
        live.sort_by_key(|(_, a)| a.at);
        let live = &live[live.len().saturating_sub(200)..];
        let mut cut = nonce_cut(now, hours)?;
        for at in live.iter().filter_map(|(_, a)| a.at) {
            cut = cut.min(at - TimeDelta::minutes(10));
        }
        let hour_ago = now - TimeDelta::hours(1);
        let mut picks: Vec<_> = self
            .picks
            .iter()
            .filter(|(_, p)| after(p.expires, now))
            .collect();
        picks.sort_by_key(|(_, p)| p.at);
        let picks = &picks[picks.len().saturating_sub(300)..];
        let kept = |m: &[(String, Option<Instant>)], than: Instant| -> Value {
            m.iter()
                .filter(|(_, t)| after(*t, than))
                .map(|(k, t)| (k.clone(), stamp(*t)))
                .collect::<Map<_, _>>()
                .into()
        };
        let mut o = Map::new();
        put(&mut o, "openUntil", stamp(self.open_until));
        put(&mut o, "since", self.since);
        put(&mut o, "lastId", self.last_id.clone());
        put(&mut o, "lastPolledAt", stamp(self.last_polled_at));
        put(&mut o, "lastReplyAt", stamp(self.last_reply_at));
        let alerts: Map<_, _> = live.iter().map(|(k, a)| (k.clone(), a.to_json())).collect();
        put(&mut o, "alerts", alerts);
        put(&mut o, "seen", kept(&self.seen, cut));
        put(&mut o, "refused", kept(&self.refused, hour_ago));
        let cands: Vec<Value> = self
            .candidates
            .iter()
            .filter(|c| after(c.expires, now))
            .map(|c| {
                json!({"id": c.id, "pid": c.pid, "d": c.d, "label": c.label, "code": c.code,
                    "at": stamp(c.at), "expires": stamp(c.expires)})
            })
            .collect();
        put(&mut o, "pairCandidates", cands);
        let picks: Map<_, _> = picks
            .iter()
            .map(|(k, p)| (k.clone(), p.to_json()))
            .collect();
        put(&mut o, "picks", picks);
        put(&mut o, "standing", self.standing);
        let compose: Vec<Value> = self
            .compose
            .iter()
            .filter(|c| after(c.at, hour_ago))
            .map(|c| json!({"at": stamp(c.at), "act": c.act}))
            .collect();
        put(&mut o, "compose", compose);
        let down = self
            .down
            .as_ref()
            .map(|d| json!({"day": d.day, "full": d.full, "other": d.other}));
        put(&mut o, "down", down);
        let sent: Map<_, _> = self
            .down_sent
            .iter()
            .filter(|(_, d)| after(d.at, now - TimeDelta::hours(12)))
            .map(|(k, d)| {
                (
                    k.clone(),
                    json!({"at": stamp(d.at), "attached": d.attached}),
                )
            })
            .collect();
        put(&mut o, "downSent", sent);
        put(&mut o, "composeRefusedAt", stamp(self.compose_refused_at));
        put(&mut o, "hotUntil", stamp(self.hot_until));
        Ok(Value::Object(o))
    }
}

impl Alert {
    fn to_json(&self) -> Value {
        let mut o = Map::new();
        put(&mut o, "at", stamp(self.at));
        put(&mut o, "expires", stamp(self.expires));
        put(&mut o, "event", self.event.clone());
        put(&mut o, "jobId", self.job_id.clone());
        put(&mut o, "seq", self.seq);
        put(&mut o, "sessionId", self.session_id.clone());
        put(&mut o, "provider", self.provider.clone());
        put(&mut o, "title", self.title.clone());
        put(&mut o, "uses", self.uses);
        put(&mut o, "path", self.path.clone());
        put(&mut o, "cwd", self.cwd.clone());
        if let Some(h) = &self.home {
            put(&mut o, "home", h.clone());
        }
        if self.live {
            put(&mut o, "live", true);
        }
        if let Some(u) = &self.usage {
            put(&mut o, "usage", u.clone());
        }
        if let Some(p) = &self.permit {
            // ConvertTo-ChatqPermitEntry's order
            put(
                &mut o,
                "permit",
                json!({
                    "run": p.run, "rid": p.rid, "digest": p.digest, "until": stamp(p.until),
                    "state": p.state, "tool": p.tool, "toolUseId": p.tool_use_id,
                    "asked": stamp(p.asked), "answeredAt": stamp(p.answered_at)
                }),
            );
        }
        if let Some(m) = &self.mark {
            put(&mut o, "mark", m.clone());
        }
        if let Some(s) = self.seen {
            put(&mut o, "seen", stamp(Some(s)));
        }
        if let Some(l) = self.len {
            put(&mut o, "len", l);
        }
        Value::Object(o)
    }
}

impl Pick {
    fn to_json(&self) -> Value {
        let mut o = Map::new();
        put(&mut o, "kind", self.kind.clone());
        for (k, v) in [
            ("sessionId", &self.session_id),
            ("provider", &self.provider),
            ("path", &self.path),
            ("cwd", &self.cwd),
        ] {
            if let Some(v) = v {
                put(&mut o, k, v.clone());
            }
        }
        if let Some(h) = &self.home {
            put(&mut o, "home", h.clone());
        }
        for (k, v) in [("title", &self.title), ("jobId", &self.job_id)] {
            if let Some(v) = v {
                put(&mut o, k, v.clone());
            }
        }
        if let Some(s) = self.seq {
            put(&mut o, "seq", s);
        }
        if let Some(m) = &self.mark {
            put(&mut o, "mark", m.clone());
        }
        if let Some(l) = self.len {
            put(&mut o, "len", l);
        }
        put(&mut o, "at", stamp(self.at));
        put(&mut o, "expires", stamp(self.expires));
        Value::Object(o)
    }
}

fn put(o: &mut Map<String, Value>, k: &str, v: impl Into<Value>) {
    o.insert(k.to_string(), v.into());
}

/// A time as the state holds it: `.ToUniversalTime().ToString('o')`.
fn stamp(t: Option<Instant>) -> Value {
    t.map_or(Value::Null, |t| stamp_utc(t).into())
}

/// `$x -and $x.ToUniversalTime() -gt $than`
fn after(t: Option<Instant>, than: Instant) -> bool {
    t.is_some_and(|t| t > than)
}

/// `$now.AddSeconds(-2 * ($Hours * 3600 + 600))`. .NET Framework rounds the
/// seconds to the millisecond, .NET 7 cuts them at the tick: hours where the
/// two differ (1.00000001) are [Error::PsOnly]; a cut out of DateTime's
/// range throws there, [Error::Invalid].
fn nonce_cut(now: Instant, hours: f64) -> Result<Instant, Error> {
    const MAX_MILLIS: i64 = 315_537_897_600_000;
    let secs = -2.0 * (hours * 3600.0 + 600.0);
    let fx = secs
        .is_finite()
        .then(|| (secs * 1000.0 + if secs >= 0.0 { 0.5 } else { -0.5 }) as i64)
        .filter(|ms| *ms > -MAX_MILLIS && *ms < MAX_MILLIS)
        .map(|ms| ms * 10_000);
    let core = (secs.is_finite() && secs.abs() <= (MAX_MILLIS / 1000 - 1) as f64).then(|| {
        let whole = secs.trunc();
        whole as i64 * 10_000_000 + ((secs - whole) * 1e7) as i64
    });
    let ticks = match (fx, core) {
        (Some(a), Some(b)) if a == b => a,
        (None, None) => {
            return Err(invalid(format!(
                "reply.hours {hours} is past a date's range"
            )));
        }
        _ => {
            return Err(ps_only(format!(
                "reply.hours {hours}, which 5.1 and 7 prune by differently"
            )));
        }
    };
    now.checked_add_signed(
        TimeDelta::seconds(ticks / 10_000_000) + TimeDelta::nanoseconds(ticks % 10_000_000 * 100),
    )
    .filter(|t| *t >= ymd(1, 1, 1))
    .ok_or_else(|| invalid(format!("reply.hours {hours} cuts before the year 1")))
}

/// [Get-ChatqReplyState](src/phone.ps1)'s read of the file at `path`: a
/// fresh state for none, or for one of white space only; up to 3 tries,
/// 100 ms apart, at one that does not read or parse, then
/// [Error::Unreadable]. It parses by `fl`'s ConvertFrom-Json grammar, so
/// pwsh 7 reads a comment that 5.1 throws at. A file PowerShell decodes
/// otherwise - UTF-16 or UTF-32, one that needed repair, or one holding a
/// `NaN` or an infinity (SPEC 2.2) - is [Error::PsOnly].
/// Deferred: DEFERRED.md "The reply registry's reads left to PowerShell"
pub fn read(path: &Path, fl: Flavour, zone: Zone) -> Result<ReplyState, Error> {
    let mut why = String::new();
    for attempt in 0..3 {
        if attempt > 0 {
            sleep(Duration::from_millis(100));
        }
        let bytes = match fs::read(path) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(ReplyState::default()),
            Err(e) => {
                why = e.to_string();
                continue;
            }
        };
        match parse(&bytes, fl) {
            Ok(Some(v)) => return ReplyState::from_json(&v, fl, zone),
            Ok(None) => return Ok(ReplyState::default()),
            Err(Bad::Again(e)) => why = e,
            Err(Bad::Stop(e)) => return Err(e),
        }
    }
    Err(Error::Unreadable(why))
}

enum Bad {
    /// ConvertFrom-Json threw: tried again
    Again(String),
    Stop(Error),
}

/// `[IO.File]::ReadAllText` (its BOM detection) and ConvertFrom-Json under
/// `fl`, by the crate's one grammar ([json::parse_tolerant_in]): None for
/// white space only. What that ConvertFrom-Json throws at - a parse error,
/// an empty name, case twins as that .NET folds them - is tried again.
fn parse(bytes: &[u8], fl: Flavour) -> Result<Option<Value>, Bad> {
    if bytes.starts_with(b"\xFE\xFF")
        || bytes.starts_with(b"\xFF\xFE")
        || bytes.starts_with(b"\0\0\xFE\xFF")
    {
        return Err(Bad::Stop(ps_only("a UTF-16 or UTF-32 file")));
    }
    let (text, _) = utf8::read_text(bytes, fl);
    if text.trim().is_empty() {
        return Ok(None);
    }
    let read = json::parse_tolerant_in(bytes, fl);
    let Some(v) = read.value else {
        return Err(Bad::Again("ConvertFrom-Json threw".into()));
    };
    if read.repaired || read.lossy {
        return Err(Bad::Stop(ps_only(
            "a file that needed repair, or a number JSON cannot hold (SPEC 2.2)",
        )));
    }
    if fl == Flavour::Desktop && !ms_dates_escaped(&v, &text) {
        return Err(Bad::Stop(ps_only("a /Date(ms)/ that 5.1 keeps as text")));
    }
    Ok(Some(v))
}

/// [Save-ChatqReplyState](src/phone.ps1): [ReplyState::to_json] saved as
/// [Save-ChatqJson](src/queue.ps1) saves, by [fsx::save_text].
pub fn save(path: &Path, state: &ReplyState, hours: f64, now: Instant) -> Result<(), Error> {
    let v = state.to_json(hours, now)?;
    let text = serde_json::to_string_pretty(&v).map_err(|e| Error::Io(io::Error::other(e)))?;
    fsx::save_text(path, &text).map_err(Error::Io)
}

/// [Use-ChatqReplyState](src/phone.ps1): replies.lock held from the read
/// to the save, `change` run on the state between them, its answer
/// returned once saved. `hours` is reply.hours, read from config.json
/// ([reply_hours]) when it is not above 0; `now` is the save's time.
pub fn use_state<T>(
    paths: &Paths,
    hours: f64,
    now: Instant,
    fl: Flavour,
    zone: Zone,
    change: impl FnOnce(&mut ReplyState) -> T,
) -> Result<T, Error> {
    let hours = if hours <= 0.0 {
        reply_hours(&read_config(&paths.config(), fl))?
    } else {
        hours
    };
    // Open-ChatqLock's New-ChatqDir
    fs::create_dir_all(&paths.data).map_err(Error::Io)?;
    let _lock = open_lock(&paths.replies_lock()).ok_or(Error::Locked)?;
    let mut state = read(&paths.replies(), fl, zone)?;
    let out = change(&mut state);
    save(&paths.replies(), &state, hours, now)?;
    Ok(out)
}

/// [Get-ChatqReplyHours](src/phone.ps1): reply.hours when it is a number
/// above 0, else 12. Text that 5.1 and 7 read as numbers their own ways
/// ("0x10", "1kb", "1e400") is [Error::PsOnly].
pub fn reply_hours(cfg: &Value) -> Result<f64, Error> {
    let rp = get(Some(cfg), "reply");
    if !truthy(rp) {
        return Ok(12.0);
    }
    // `$rp.hours -as [double]`
    let h = match get(rp, "hours") {
        Some(Value::Bool(b)) => f64::from(u8::from(*b)),
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => {
            let t = num_trim(s);
            let lower = t.to_ascii_lowercase();
            if t.bytes().any(|b| b.is_ascii_digit()) {
                match t.parse::<f64>() {
                    Ok(x) if x.is_finite() && simple_decimal(t) => x,
                    _ => return Err(ps_only(format!("reply.hours '{s}'"))),
                }
            } else if lower.contains("inf") || lower.contains("nan") || t.contains('\u{221E}') {
                return Err(ps_only(format!("reply.hours '{s}'")));
            } else {
                0.0
            }
        }
        // `@(5) -as [double]` is $null in both, as an object's is
        _ => 0.0,
    };
    Ok(if h > 0.0 { h } else { 12.0 })
}

/// `[+-]?(d+[.d*]|.d+)([eE][+-]?d+)?`: what both PowerShells' `-as [double]`
/// read alike.
fn simple_decimal(t: &str) -> bool {
    let b = t.strip_prefix(['+', '-']).unwrap_or(t).as_bytes();
    let (mant, exp) = match b.iter().position(|c| *c == b'e' || *c == b'E') {
        Some(i) => (&b[..i], Some(&b[i + 1..])),
        None => (b, None),
    };
    let digits = |x: &[u8]| x.iter().all(u8::is_ascii_digit);
    let mant_ok = match mant.iter().position(|c| *c == b'.') {
        Some(i) => digits(&mant[..i]) && digits(&mant[i + 1..]) && mant.len() > 1,
        None => !mant.is_empty() && digits(mant),
    };
    let exp_ok = exp.is_none_or(|e| {
        let e = e
            .strip_prefix(b"+")
            .or_else(|| e.strip_prefix(b"-"))
            .unwrap_or(e);
        !e.is_empty() && digits(e)
    });
    mant_ok && exp_ok
}

/// [Open-ChatqLock](src/queue.ps1): tries for 3 s, each wait 15 to 60 ms of
/// its own, so two writers retrying in step do not take turns forever.
fn open_lock(path: &Path) -> Option<File> {
    let until = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        match fsx::try_lock(path) {
            Ok(f) => return Some(f),
            Err(_) if std::time::Instant::now() > until => return None,
            Err(_) => sleep(Duration::from_millis(
                15 + RandomState::new().hash_one(until) % 45,
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, FixedOffset, Utc};

    fn utc(s: &str) -> Instant {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn kst() -> Zone {
        Zone::Fixed(FixedOffset::east_opt(9 * 3600).unwrap())
    }

    fn read_as(v: Value, fl: Flavour) -> Result<ReplyState, Error> {
        ReplyState::from_json(&v, fl, kst())
    }

    #[test]
    fn throws_in_powershell_words() {
        assert_eq!(
            Error::Locked.to_string(),
            "data/replies.lock is held by another process"
        );
        assert_eq!(
            Error::Unreadable(String::new()).to_string(),
            "data/replies.json could not be read: "
        );
        let uses = read_as(json!({"alerts": {"a": {"uses": "abc"}}}), Flavour::Desktop);
        assert!(matches!(uses, Err(Error::Invalid(_))));
        assert!(matches!(
            read_as(json!([]), Flavour::Core),
            Err(Error::Unreadable(_))
        ));
    }

    #[test]
    fn leaves_to_powershell_what_it_reads_its_own_way() {
        let d = Flavour::Desktop;
        for v in [
            json!([{"lastId": "a"}]),
            json!({"alerts": [{"at": "2026-10-15T11:00:00Z"}]}),
            json!({"openUntil": 1.5}),
            json!({"alerts": {"a": {"uses": " "}}}),
            json!({"since": "1e3"}),
            json!({"lastId": "/Date(1)/"}),
            json!({"seen": {"n\u{e9}": "2026-10-15T11:00:00Z"}}),
        ] {
            assert!(
                matches!(read_as(v.clone(), d), Err(Error::PsOnly(_))),
                "{v}"
            );
        }
        // a DateTime to pwsh 7 by then, text to 5.1
        let t = json!({"alerts": {"a": {"title": "2026-10-15T11:00:00Z"}}});
        assert!(matches!(
            read_as(t.clone(), Flavour::Core),
            Err(Error::PsOnly(_))
        ));
        assert!(read_as(t, d).is_ok());
        let late = json!({"openUntil": "2026-10-15T24:00:00Z"});
        assert!(matches!(
            read_as(late, Flavour::Core),
            Err(Error::PsOnly(_))
        ));
    }

    #[test]
    fn files_read_otherwise_are_left_alone() {
        let dir =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/core-replystate");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join("replies.json");
        for bytes in [
            &b"\xFF\xFE{\0}\0"[..],
            b"{\"lastId\":\"a\xFFb\"}",
            b"{\"lastId\":\"cut \\ud83d\"}",
            b"{\"openUntil\":\"/Date(1760529600000)/\"}",
            b"{\"since\":NaN}",
        ] {
            fs::write(&p, bytes).unwrap();
            let r = read(&p, Flavour::Desktop, kst());
            assert!(matches!(r, Err(Error::PsOnly(_))), "{bytes:?}: {r:?}");
        }
        // "last\u{131}d": no .NET folds the dotless i to ASCII
        fs::write(&p, b"{\"last\xC4\xB1d\":\"b\"}").unwrap();
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert!(read(&p, fl, kst()).unwrap().last_id.is_none());
        }
        // the escaped form is 5.1's DateTime
        fs::write(&p, b"{\"openUntil\":\"\\/Date(1760529600000)\\/\"}").unwrap();
        let s = read(&p, Flavour::Desktop, kst()).unwrap();
        assert_eq!(s.open_until, Some(utc("2025-10-15T12:00:00Z")));
        fs::write(&p, b" \r\n").unwrap();
        assert!(read(&p, Flavour::Core, kst()).unwrap().last_id.is_none());
    }

    #[test]
    fn reply_hours_as_powershell_reads_them() {
        for (cfg, want) in [
            (json!({}), 12.0),
            (json!({"reply": {"hours": 1}}), 1.0),
            (json!({"Reply": {"Hours": " 6 "}}), 6.0),
            (json!({"reply": {"hours": -1}}), 12.0),
            (json!({"reply": {"hours": true}}), 1.0),
            (json!({"reply": {"hours": [5]}}), 12.0),
            (json!({"reply": "x"}), 12.0),
        ] {
            assert_eq!(reply_hours(&cfg).unwrap(), want, "{cfg}");
        }
        for h in ["0x10", "1kb", "1e400", "Infinity"] {
            let r = reply_hours(&json!({"reply": {"hours": h}}));
            assert!(matches!(r, Err(Error::PsOnly(_))), "{h}");
        }
    }

    #[test]
    fn the_nonce_cut_as_both_dotnets_add_seconds() {
        let now = utc("2026-10-15T12:00:00Z");
        assert_eq!(nonce_cut(now, 12.0).unwrap(), utc("2026-10-14T11:40:00Z"));
        assert_eq!(
            nonce_cut(now, 0.0001).unwrap(),
            utc("2026-10-15T11:39:59.28Z")
        );
        // 09:40:00 to 5.1, 09:39:59.9999281 to 7
        assert!(matches!(nonce_cut(now, 1.00000001), Err(Error::PsOnly(_))));
        assert!(matches!(nonce_cut(now, f64::NAN), Err(Error::Invalid(_))));
        assert!(matches!(nonce_cut(now, 1e12), Err(Error::Invalid(_))));
    }

    #[test]
    fn iso_text_as_newtonsoft_sees_it() {
        for s in [
            "2026-10-15T01:02:03",
            "2026-10-15T01:02:03.1234567Z",
            "2026-10-15T01:02:03+0900",
            "2026-10-15T01:02:03-05:30",
        ] {
            assert!(newtonsoft_iso(s), "{s}");
        }
        for s in [
            "2026-10-15 01:02:03",
            "2026-10-15",
            "2026-02-30T01:02:03",
            "2026-10-15T01:02:03.12345678",
            "2026-10-15T01:02:03+15:00",
        ] {
            assert!(!newtonsoft_iso(s), "{s}");
        }
        assert!(maybe_iso("2026-02-30T01:02:03"));
        assert!(!maybe_iso("2026-10-15 01:02:03"));
    }
}
