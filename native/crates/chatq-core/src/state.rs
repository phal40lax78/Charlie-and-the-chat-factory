//! The watcher's run state `$W` and its file, data/state.json, as
//! [Save-ChatqWatchState](src/watcher.ps1) writes it and
//! [Restore-ChatqWatchState](src/watcher.ps1) reads it back after a handoff.
//! Either engine can hand over to the other through it. `$W` and the shared
//! caches also cross to and from a helper step, and into D/native/handoff.json,
//! as `w` (SPEC 3.6 "The `w` encoding").

use crate::json::{self, ieq};
use crate::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

/// A lane limited until a time ([Update-ChatqBlock](src/watcher.ps1)).
#[derive(Clone, Debug, PartialEq)]
pub struct Blocked {
    pub until: Instant,
    pub kind: Value,
    pub source: Value,
    /// when the lane was blocked: a soon alert needs the wait to have been long
    pub at: Option<Instant>,
}

/// A lane in an overload outage ([Enter-ChatqOutage](src/watcher.ps1)).
#[derive(Clone, Debug, PartialEq)]
pub struct Outage {
    pub since: Instant,
    pub next_check: Instant,
    pub last_probe: Instant,
    pub status: Value,
    pub attempts: i64,
    pub alerted: bool,
    pub reminded: bool,
    /// the auto-continue job the outage holds back: None is the $null of an
    /// outage just entered ([Enter-ChatqOutage](src/watcher.ps1)), written
    /// as null; a restore makes it `[string]`, "" when the file has none,
    /// and None again only from an empty array
    pub auto_job: Option<String>,
}

/// [New-ChatqWatchState](src/watcher.ps1) and the shared caches. Lanes keep
/// the order they were read in. state.json carries `blocked`, `outage`,
/// `auth_alerted` and the scalars; the rest lives only in memory and in `w`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WatchState {
    pub blocked: Vec<(String, Blocked)>,
    pub outage: Vec<(String, Outage)>,
    pub auth_alerted: Vec<String>,
    pub current: Option<String>,
    pub next: Option<String>,
    pub started_at: String,
    pub handoff: bool,
    pub listening: bool,
    /// `$W.lastAllowed`: `<lane>` and `<lane>|<model>` → Date or null
    pub last_allowed: Pairs,
    /// `$W.probeFails`: lane → int or null
    pub probe_fails: Pairs,
    /// `$W.scannedAt`: lane → Date or null
    pub scanned_at: Pairs,
    /// `w.caches` as a step sent them, carried without reading but through
    /// the accessors below: each name of [CACHES] with its `w` value
    pub caches: Map<String, Value>,
    /// `w`'s `blocked`, `outage` and `authAlerted` as [from_w](Self::from_w)
    /// read them
    pub wire: Wire,
}

/// A map in the `w` encoding: its pairs in the order received. Keys compare
/// as a `@{}` compares them ([ieq]); setting one replaces the value of the
/// pair it matches, else appends a pair.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pairs(pub Vec<(String, Value)>);

/// `w`'s entry maps as a step sent them. [to_w](WatchState::to_w) sends each
/// back as it came while chatqd's typed list still says what it said, so an
/// entry's `_type`, its field spelling, an absent field, a null entry and a
/// field chatqd does not name all survive. Of a list chatqd changed, an
/// entry it kept still goes back as it came.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Wire {
    blocked: Pairs,
    outage: Pairs,
    auth_alerted: Pairs,
}

/// The shared caches of `w.caches` (SPEC 3.6), in its order, each with
/// whether it is a map; the rest are Dates.
pub const CACHES: [(&str, bool); 10] = [
    ("ChatqReplyHandled", true),
    ("ChatqReplySeen", true),
    ("ChatqAskSent", true),
    ("ChatqReplyJunkLog", true),
    ("ChatqReplyPolledAt", false),
    ("ChatqReplyErrAt", false),
    ("ChatqReplyBadIdAt", false),
    ("ChatqReplySavedAt", false),
    ("ChatqUsageSent", true),
    ("ChatqSummaryTriedAt", false),
];

/// The caches whose values are entry objects.
const ENTRY_CACHES: [&str; 2] = ["ChatqAskSent", "ChatqReplyJunkLog"];

/// A Date in `w`: the UTC 'o' text ConvertTo-ChatqStepW writes. Any other
/// value is carried, but names no time.
fn w_date(v: Option<&Value>) -> Option<Instant> {
    DateTime::parse_from_rfc3339(v?.as_str()?)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// An entry object's `_type`, which the decoder builds and chatqd keeps.
fn tagged(fields: Value, tag: &str) -> Value {
    let mut e = Map::new();
    e.insert("_type".into(), tag.into());
    if let Value::Object(m) = fields {
        e.extend(m);
    }
    Value::Object(e)
}

impl Pairs {
    /// The value of `key`, compared case-blind.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.iter().find(|(k, _)| ieq(k, key)).map(|(_, v)| v)
    }

    /// The Date `key` holds, if it holds one.
    pub fn date(&self, key: &str) -> Option<Instant> {
        w_date(self.get(key))
    }

    pub fn set(&mut self, key: &str, value: Value) {
        put(&mut self.0, key, value);
    }

    pub fn remove(&mut self, key: &str) {
        self.0.retain(|(k, _)| !ieq(k, key));
    }

    fn to_w(&self) -> Value {
        Value::Array(
            self.0
                .iter()
                .map(|(k, v)| json!({"k": k, "v": v}))
                .collect(),
        )
    }

    /// A list of `{k, v}` with `k` a string, and every `v` an entry object
    /// (with a `_type` the decoder knows) or null when `entries`, else a
    /// scalar. None for anything else, which is a bad answer.
    fn from_w(v: Option<&Value>, entries: bool) -> Option<Pairs> {
        let mut out = Vec::new();
        for p in v?.as_array()? {
            let m = p.as_object()?;
            let k = m.get("k")?.as_str()?;
            let v = m.get("v")?;
            let ok = match v {
                Value::Null => true,
                Value::Object(e) => {
                    entries
                        && matches!(
                            e.get("_type").and_then(Value::as_str),
                            Some("psobject" | "hashtable")
                        )
                }
                Value::Array(_) => false,
                _ => !entries,
            };
            if !ok {
                return None;
            }
            out.push((k.to_string(), v.clone()));
        }
        Some(Pairs(out))
    }
}

/// The typed list of an entry map: its entries that decode, in order.
fn typed<T>(p: &Pairs, decode: fn(&Value) -> Option<T>) -> Vec<(String, T)> {
    let mut out = Vec::new();
    for (k, v) in &p.0 {
        if let Some(t) = decode(v) {
            put(&mut out, k, t);
        }
    }
    out
}

/// A typed list in `w`: as received while it still decodes to `list`; else
/// `list`, each entry as received where its lane's did decode to it.
fn entries_w<T: PartialEq>(
    list: &[(String, T)],
    wire: &Pairs,
    decode: fn(&Value) -> Option<T>,
    encode: fn(&T) -> Value,
) -> Value {
    if typed(wire, decode) == list {
        return wire.to_w();
    }
    let pairs = list.iter().map(|(k, t)| {
        let v = wire
            .get(k)
            .filter(|v| decode(v).as_ref() == Some(t))
            .cloned();
        (k.clone(), v.unwrap_or_else(|| encode(t)))
    });
    Pairs(pairs.collect()).to_w()
}

impl Blocked {
    /// A `blocked` entry of `w`: `Until` a Date, else it is carried only.
    fn of_w(e: &Value) -> Option<Blocked> {
        let f = |n: &str| json::get(Some(e), n);
        Some(Blocked {
            until: w_date(f("Until"))?,
            kind: f("Type").cloned().unwrap_or(Value::Null),
            source: f("Source").cloned().unwrap_or(Value::Null),
            at: w_date(f("At")),
        })
    }

    /// As [Restore-ChatqWatchState](src/watcher.ps1) builds it: a
    /// `[pscustomobject]`, `At` only when known.
    fn to_w(&self) -> Value {
        let mut e =
            json!({"Until": stamp_utc(self.until), "Type": self.kind, "Source": self.source});
        if let Some(at) = self.at {
            e["At"] = stamp_utc(at).into();
        }
        tagged(e, "psobject")
    }
}

impl Outage {
    /// An `outage` entry of `w`: `Since`, `LastProbe` and `NextCheck` Dates,
    /// else it is carried only. An absent `Reminded` reads false, as `$null`
    /// does, and a missing `Attempts` 0.
    fn of_w(e: &Value) -> Option<Outage> {
        let f = |n: &str| json::get(Some(e), n);
        Some(Outage {
            since: w_date(f("Since"))?,
            next_check: w_date(f("NextCheck"))?,
            last_probe: w_date(f("LastProbe"))?,
            status: f("Status").cloned().unwrap_or(Value::Null),
            attempts: f("Attempts").and_then(Value::as_i64).unwrap_or(0),
            alerted: json::truthy(f("Alerted")),
            reminded: json::truthy(f("Reminded")),
            auto_job: f("AutoJob").and_then(Value::as_str).map(str::to_string),
        })
    }

    /// As [Restore-ChatqWatchState](src/watcher.ps1) builds it: a `@{}` of
    /// all eight fields.
    fn to_w(&self) -> Value {
        tagged(
            json!({
                "Since": stamp_utc(self.since),
                "Attempts": self.attempts,
                "Status": self.status,
                "Alerted": self.alerted,
                "Reminded": self.reminded,
                "LastProbe": stamp_utc(self.last_probe),
                "NextCheck": stamp_utc(self.next_check),
                "AutoJob": self.auto_job,
            }),
            "hashtable",
        )
    }
}

/// The lanes `authAlerted` holds true.
fn alerted_lanes(p: &Pairs) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for (k, v) in &p.0 {
        if json::truthy(Some(v)) && !out.iter().any(|x| ieq(x, k)) {
            out.push(k.clone());
        }
    }
    out
}

/// [ConvertTo-ChatqDate](src/queue.ps1) on a field: a stamp, or None.
fn date_in(v: Option<&Value>, fl: Flavour, zone: Zone) -> Option<Instant> {
    parse_stamp_in(v?.as_str()?, fl, zone)
}

/// `[string](Get-ChatField $v 'autoJob')`: Get-ChatField's `return` unrolls
/// an empty array into nothing, which `[string]` leaves $null; anything else
/// is its `[string]`, "" for a missing field.
fn field_string(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::Array(a)) if a.is_empty() => None,
        v => Some(json::to_ps_string(v)),
    }
}

/// Lanes are hashtable keys in PS, so case-blind there.
fn put<T>(list: &mut Vec<(String, T)>, key: &str, value: T) {
    match list.iter_mut().find(|(k, _)| ieq(k, key)) {
        Some(slot) => slot.1 = value,
        None => list.push((key.to_string(), value)),
    }
}

impl WatchState {
    /// Restore-ChatqWatchState: only when the file says `handoff`. A limit
    /// already over is dropped, as is an outage with no `since`.
    pub fn restore(&mut self, s: Option<&Value>, now: Instant, fl: Flavour) -> bool {
        self.restore_in(s, now, fl, Zone::Local)
    }

    /// [Restore-ChatqWatchState](src/watcher.ps1) with `zone` the system's,
    /// which a stamp with no zone is read in under pwsh 7. An `attempts`
    /// that `[int]` cannot convert throws there, and the watch loop's
    /// try/finally lets it end the watcher (its finally saves the state with
    /// handoff off); here the count starts again at 0, as in M0.
    /// Deferred: DEFERRED.md "A list where chatq writes an object"
    pub fn restore_in(&mut self, s: Option<&Value>, now: Instant, fl: Flavour, zone: Zone) -> bool {
        if !json::truthy(json::get(s, "handoff")) {
            return false;
        }
        if let Some(b) = json::get(s, "blocked").and_then(Value::as_object) {
            for (name, v) in b {
                let Some(u) = date_in(json::get(Some(v), "until"), fl, zone).filter(|u| *u > now)
                else {
                    continue;
                };
                let at = date_in(json::get(Some(v), "at"), fl, zone);
                let kind = json::get(Some(v), "type").cloned().unwrap_or(Value::Null);
                let source = json::get(Some(v), "source").cloned().unwrap_or(Value::Null);
                put(
                    &mut self.blocked,
                    name,
                    Blocked {
                        until: u,
                        kind,
                        source,
                        at,
                    },
                );
            }
        }
        if let Some(o) = json::get(s, "outage").and_then(Value::as_object) {
            for (name, v) in o {
                let v = Some(v);
                let Some(since) = date_in(json::get(v, "since"), fl, zone) else {
                    continue;
                };
                let entry = Outage {
                    since,
                    next_check: date_in(json::get(v, "next"), fl, zone).unwrap_or(now),
                    last_probe: date_in(json::get(v, "lastProbe"), fl, zone).unwrap_or(since),
                    status: json::get(v, "status").cloned().unwrap_or(Value::Null),
                    attempts: crate::jobs::ps_int(json::get(v, "attempts"), fl)
                        .map_or(0, i64::from),
                    alerted: json::truthy(json::get(v, "alerted")),
                    reminded: json::truthy(json::get(v, "reminded")),
                    auto_job: field_string(json::get(v, "autoJob")),
                };
                put(&mut self.outage, name, entry);
            }
        }
        let auth: Vec<&Value> = match json::get(s, "authAlerted") {
            Some(Value::Array(a)) => a.iter().collect(),
            Some(v) => vec![v],
            None => vec![],
        };
        for k in auth {
            if json::truthy(Some(k)) {
                let k = json::to_ps_string(Some(k));
                if !self.auth_alerted.iter().any(|x| ieq(x, &k)) {
                    self.auth_alerted.push(k);
                }
            }
        }
        true
    }

    /// The object Save-ChatqWatchState writes, in its order. `pid` is the
    /// lock holder's, `version` the compiled one (SPEC 4.6).
    pub fn to_json(&self, pid: u32, version: &str, heartbeat: Instant) -> Value {
        let mut blocked = Map::new();
        for (k, b) in &self.blocked {
            let mut e = Map::new();
            e.insert("until".into(), stamp_utc(b.until).into());
            e.insert("type".into(), b.kind.clone());
            e.insert("source".into(), b.source.clone());
            if let Some(at) = b.at {
                e.insert("at".into(), stamp_utc(at).into());
            }
            blocked.insert(k.clone(), Value::Object(e));
        }
        let mut outage = Map::new();
        for (k, o) in &self.outage {
            outage.insert(
                k.clone(),
                json!({
                    "since": stamp_utc(o.since),
                    "next": stamp_utc(o.next_check),
                    "lastProbe": stamp_utc(o.last_probe),
                    "status": o.status,
                    "attempts": o.attempts,
                    "alerted": o.alerted,
                    "reminded": o.reminded,
                    "autoJob": o.auto_job,
                }),
            );
        }
        json!({
            "pid": pid,
            "version": version,
            "startedAt": self.started_at,
            "heartbeat": stamp_utc(heartbeat),
            "current": self.current,
            "next": self.next,
            "blocked": blocked,
            "outage": outage,
            "authAlerted": self.auth_alerted,
            "handoff": self.handoff,
            "listening": self.listening,
        })
    }

    /// The text of data/state.json as chatqd writes it in place of
    /// [Save-ChatqWatchState](src/watcher.ps1): [to_json](Self::to_json),
    /// pretty, two-space indents. native/vectors/state.json holds such texts
    /// and what Restore-ChatqWatchState makes of them.
    pub fn to_text(&self, pid: u32, version: &str, heartbeat: Instant) -> String {
        serde_json::to_string_pretty(&self.to_json(pid, version, heartbeat))
            .expect("a Value with string keys always serialises")
    }

    /// `w` for a step's `In` (SPEC 3.6): the eleven native-owned keys, then
    /// `caches` with all ten, a cache never sent being an empty map or a null
    /// Date, as the parts declare it at load.
    pub fn to_w(&self) -> Value {
        let mut caches = Map::new();
        for (name, map) in CACHES {
            let v = self.caches.get(name).cloned();
            caches.insert(
                name.into(),
                v.unwrap_or(if map { json!([]) } else { Value::Null }),
            );
        }
        let auth = if alerted_lanes(&self.wire.auth_alerted) == self.auth_alerted {
            self.wire.auth_alerted.to_w()
        } else {
            Pairs(
                self.auth_alerted
                    .iter()
                    .map(|k| (k.clone(), true.into()))
                    .collect(),
            )
            .to_w()
        };
        json!({
            "blocked": entries_w(&self.blocked, &self.wire.blocked, Blocked::of_w, Blocked::to_w),
            "lastAllowed": self.last_allowed.to_w(),
            "probeFails": self.probe_fails.to_w(),
            "scannedAt": self.scanned_at.to_w(),
            "outage": entries_w(&self.outage, &self.wire.outage, Outage::of_w, Outage::to_w),
            "authAlerted": auth,
            "current": self.current,
            "next": self.next,
            "handoff": self.handoff,
            "listening": self.listening,
            "startedAt": self.started_at,
            "caches": caches,
        })
    }

    /// A step's `Out.w`: None unless it holds every key of the schema in its
    /// shape, which makes the answer a bad one. Dates inside entries and maps
    /// are not checked: a value that is no Date is carried, and names no time.
    pub fn from_w(w: &Value) -> Option<WatchState> {
        let m = w.as_object()?;
        let pairs = |k: &str, entries: bool| Pairs::from_w(m.get(k), entries);
        let text = |k: &str| match m.get(k)? {
            Value::Null => Some(None),
            Value::String(s) => Some(Some(s.clone())),
            _ => None,
        };
        let flag = |k: &str| m.get(k)?.as_bool();
        let c = m.get("caches")?.as_object()?;
        let mut caches = Map::new();
        for (name, map) in CACHES {
            let v = c.get(name)?;
            let ok = if map {
                Pairs::from_w(Some(v), ENTRY_CACHES.contains(&name)).is_some()
            } else {
                v.is_null() || v.is_string()
            };
            if !ok {
                return None;
            }
            caches.insert(name.into(), v.clone());
        }
        let wire = Wire {
            blocked: pairs("blocked", true)?,
            outage: pairs("outage", true)?,
            auth_alerted: pairs("authAlerted", false)?,
        };
        Some(WatchState {
            blocked: typed(&wire.blocked, Blocked::of_w),
            outage: typed(&wire.outage, Outage::of_w),
            auth_alerted: alerted_lanes(&wire.auth_alerted),
            current: text("current")?,
            next: text("next")?,
            started_at: m.get("startedAt")?.as_str()?.to_string(),
            handoff: flag("handoff")?,
            listening: flag("listening")?,
            last_allowed: pairs("lastAllowed", false)?,
            probe_fails: pairs("probeFails", false)?,
            scanned_at: pairs("scannedAt", false)?,
            caches,
            wire,
        })
    }

    /// D/native/handoff.json (SPEC 4.4): `w` with `handoff` true, for the PS
    /// watcher that carries on from chatqd `pid`.
    pub fn to_handoff(&self, pid: u32) -> Value {
        let mut w = self.to_w();
        w["handoff"] = true.into();
        json!({"v": 1, "watcherPid": pid, "w": w})
    }

    /// A map cache, empty when none was sent.
    fn cache(&self, name: &str) -> Pairs {
        Pairs::from_w(self.caches.get(name), ENTRY_CACHES.contains(&name)).unwrap_or_default()
    }

    fn set_cache(&mut self, name: &str, p: &Pairs) {
        self.caches.insert(name.into(), p.to_w());
    }

    /// `ChatqAskSent`: each rid with its entry's `At`, in order.
    pub fn ask_sent(&self) -> Vec<(String, Option<Instant>)> {
        let sent = self.cache("ChatqAskSent").0;
        sent.into_iter()
            .map(|(k, e)| (k, w_date(json::get(Some(&e), "At"))))
            .collect()
    }

    /// Drops `rid` from `ChatqAskSent`, as [Test-ChatqAskLanded](src/ask.ps1)
    /// drops an entry before it looks.
    pub fn drop_ask_sent(&mut self, rid: &str) {
        let mut p = self.cache("ChatqAskSent");
        p.remove(rid);
        self.set_cache("ChatqAskSent", &p);
    }

    /// The `ChatqUsageSent` keys, in order.
    pub fn usage_sent(&self) -> Vec<String> {
        self.cache("ChatqUsageSent")
            .0
            .into_iter()
            .map(|(k, _)| k)
            .collect()
    }

    /// Records soon key `key` as sent, as [Send-ChatqUsageSoon](src/phone-extras.ps1) does.
    pub fn add_usage_sent(&mut self, key: &str) {
        let mut p = self.cache("ChatqUsageSent");
        p.set(key, true.into());
        self.set_cache("ChatqUsageSent", &p);
    }

    /// `ChatqSummaryTriedAt`: the held summary's last failed try.
    pub fn summary_tried_at(&self) -> Option<Instant> {
        w_date(self.caches.get("ChatqSummaryTriedAt"))
    }

    pub fn set_summary_tried_at(&mut self, at: Instant) {
        self.caches
            .insert("ChatqSummaryTriedAt".into(), stamp_utc(at).into());
    }

    /// The `-Now` wake's `$W.blocked = @{}; $W.lastAllowed = @{}; $W.outage
    /// = @{}` in [Invoke-ChatqWatchLoop](src/watcher.ps1): the null entries
    /// and the ones chatqd only carries go too.
    pub fn clear_for_wake(&mut self) {
        self.blocked.clear();
        self.outage.clear();
        self.last_allowed = Pairs::default();
        self.wire.blocked = Pairs::default();
        self.wire.outage = Pairs::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, Utc};

    #[test]
    fn restores_only_after_a_handoff() {
        let mut w = WatchState::default();
        assert!(!w.restore(
            Some(&json!({"handoff": false})),
            Utc::now(),
            Flavour::Desktop
        ));
        assert!(!w.restore(None, Utc::now(), Flavour::Desktop));
    }

    #[test]
    fn round_trip_keeps_what_ps_keeps() {
        let now = Utc::now();
        let soon = stamp_utc(now + Duration::hours(2));
        let gone = stamp_utc(now - Duration::minutes(1));
        let since = stamp_utc(now - Duration::minutes(30));
        let file = json!({
            "pid": 7, "version": "0.0.1", "handoff": true,
            "blocked": {
                "claude": {"until": soon, "type": "session", "source": "probe", "at": since},
                "codex": {"until": gone, "type": "weekly", "source": "probe"}
            },
            "outage": {
                "claude|C:\\h": {"since": since, "next": soon, "lastProbe": since, "status": "major_outage",
                                  "attempts": 2, "alerted": true, "reminded": false, "autoJob": null},
                "codex": {"next": soon}
            },
            "authAlerted": "claude"
        });
        let mut w = WatchState::default();
        assert!(w.restore(Some(&file), now, Flavour::Desktop));
        assert_eq!(w.blocked.len(), 1, "a limit already over is dropped");
        assert_eq!(w.outage.len(), 1, "an outage with no since is dropped");
        assert_eq!(
            w.outage[0].1.auto_job.as_deref(),
            Some(""),
            "[string]$null is empty"
        );
        assert_eq!(w.auth_alerted, vec!["claude".to_string()]);
        let saved = w.to_json(42, "0.10.12", now);
        assert_eq!(saved["pid"], 42);
        assert_eq!(saved["blocked"]["claude"]["until"], soon);
        assert_eq!(saved["blocked"]["claude"]["at"], since);
        assert_eq!(saved["outage"]["claude|C:\\h"]["attempts"], 2);
        assert_eq!(saved["authAlerted"], json!(["claude"]));
        let mut again = WatchState::default();
        assert!(
            !again.restore(Some(&saved), now, Flavour::Desktop),
            "handoff false as saved"
        );
        let keys: Vec<&String> = saved.as_object().unwrap().keys().collect();
        assert_eq!(
            keys,
            [
                "pid",
                "version",
                "startedAt",
                "heartbeat",
                "current",
                "next",
                "blocked",
                "outage",
                "authAlerted",
                "handoff",
                "listening"
            ]
        );
    }

    /// A `w` with every key and cache, entries of both tags, a null entry,
    /// absent and unknown fields, odd spelling and an empty lane.
    fn full_w() -> Value {
        let at = "2026-10-18T01:02:03.4567890Z";
        let until = "2026-10-18T05:00:00.0000000Z";
        json!({
            "blocked": [
                {"k": "claude", "v": {"_type": "psobject", "Until": until, "Type": "session",
                                      "Source": "probe", "At": at, "Extra": 7}},
                {"k": "codex", "v": null},
                {"k": "", "v": {"_type": "hashtable", "until": until, "Type": null, "Source": "run"}}
            ],
            "lastAllowed": [{"k": "claude", "v": at}, {"k": "claude|opus", "v": null}],
            "probeFails": [{"k": "claude", "v": 2}, {"k": "codex", "v": null}],
            "scannedAt": [{"k": "", "v": at}],
            "outage": [
                {"k": "claude|C:\\h", "v": {"_type": "hashtable", "Since": at, "Attempts": 1,
                                             "Status": "major_outage", "Alerted": true,
                                             "LastProbe": at, "NextCheck": until, "AutoJob": null}},
                {"k": "codex", "v": null}
            ],
            "authAlerted": [{"k": "claude", "v": false}, {"k": "codex", "v": true}],
            "current": "j1",
            "next": until,
            "handoff": false,
            "listening": false,
            "startedAt": at,
            "caches": {
                "ChatqReplyHandled": [{"k": "tag1", "v": true}],
                "ChatqReplySeen": [],
                "ChatqAskSent": [{"k": "r1", "v": {"_type": "hashtable", "Rid": "r1", "At": at,
                    "ToolUseId": null, "Answers": [{"k": "Q", "v": "a"}, {"k": "q", "v": "b"}],
                    "Transcript": null, "SessionId": "s", "Title": "t", "New": "kept"}}],
                "ChatqReplyJunkLog": [{"k": "fetch", "v": {"_type": "hashtable", "At": at, "Count": 3}}],
                "ChatqReplyPolledAt": at,
                "ChatqReplyErrAt": null,
                "ChatqReplyBadIdAt": null,
                "ChatqReplySavedAt": null,
                "ChatqUsageSent": [{"k": "claude|session|x", "v": true}],
                "ChatqSummaryTriedAt": at
            }
        })
    }

    /// Exact text, since a Map compares without its order.
    fn same(a: &Value, b: &Value) {
        assert_eq!(a.to_string(), b.to_string());
    }

    #[test]
    fn w_round_trips_every_field() {
        let w = full_w();
        let s = WatchState::from_w(&w).expect("decodes");
        same(&s.to_w(), &w);
        // what chatqd reads of it
        assert_eq!(s.blocked.len(), 2, "the null entry is no lane");
        assert_eq!(s.blocked[0].1.kind, "session");
        assert_eq!(s.blocked[0].1.at, w_date(Some(&w["startedAt"])));
        assert_eq!(s.blocked[1].0, "", "field names compare case-blind");
        assert_eq!(s.outage.len(), 1);
        assert!(!s.outage[0].1.reminded, "an absent Reminded is false");
        assert_eq!(s.auth_alerted, vec!["codex".to_string()]);
        assert_eq!(s.current.as_deref(), Some("j1"));
        assert!(s.scanned_at.date("").is_some());
        assert_eq!(s.probe_fails.get("CLAUDE"), Some(&json!(2)));
        assert_eq!(
            s.ask_sent(),
            vec![("r1".to_string(), w_date(Some(&w["startedAt"])))]
        );
        assert_eq!(s.usage_sent(), vec!["claude|session|x".to_string()]);
        assert_eq!(s.summary_tried_at(), w_date(Some(&w["startedAt"])));
        // a scalar Answers travels as itself (SPEC 3.6 "A named field")
        let mut scalar = full_w();
        scalar["caches"]["ChatqAskSent"][0]["v"]["Answers"] = json!("not a map");
        let back = WatchState::from_w(&scalar).expect("a scalar Answers decodes");
        same(&back.to_w(), &scalar);
        // and the handoff file
        let h = s.to_handoff(42);
        assert_eq!(h["v"], 1);
        assert_eq!(h["watcherPid"], 42);
        assert_eq!(h["w"]["handoff"], true);
        let mut back = WatchState::from_w(&h["w"]).expect("decodes");
        back.handoff = false;
        same(&back.to_w(), &w);
    }

    #[test]
    fn unknown_entry_fields_survive_chatqd_changes() {
        let mut s = WatchState::from_w(&full_w()).unwrap();
        // to the tick, as a Date crosses
        let now = w_date(Some(&stamp_utc(Utc::now()).into())).unwrap();
        s.scanned_at.set("claude", stamp_utc(now).into());
        s.current = None;
        s.add_usage_sent("CLAUDE|session|x");
        s.add_usage_sent("codex|weekly|y");
        s.drop_ask_sent("R1");
        s.set_summary_tried_at(now);
        let w = s.to_w();
        same(&w["blocked"], &full_w()["blocked"]);
        same(&w["outage"], &full_w()["outage"]);
        assert_eq!(
            w["scannedAt"][1],
            json!({"k": "claude", "v": stamp_utc(now)})
        );
        assert_eq!(
            w["caches"]["ChatqUsageSent"].as_array().unwrap().len(),
            2,
            "replaced case-blind"
        );
        assert_eq!(w["caches"]["ChatqAskSent"], json!([]));
        assert_eq!(s.summary_tried_at(), Some(now));
        // a lane chatqd drops goes; the others still come back as they came
        s.blocked.remove(1);
        let w = s.to_w();
        assert_eq!(w["blocked"].as_array().unwrap().len(), 1);
        same(&w["blocked"][0], &full_w()["blocked"][0]);
        // a list chatqd built itself: the tags Restore-ChatqWatchState builds
        s.blocked.clear();
        s.outage.clear();
        s.restore(
            Some(&json!({"handoff": true,
                "blocked": {"claude": {"until": stamp_utc(now + chrono::Duration::hours(1)), "type": "weekly", "source": "probe"}},
                "outage": {"codex": {"since": stamp_utc(now)}}})),
            now,
            Flavour::Desktop,
        );
        let w = s.to_w();
        assert_eq!(w["blocked"][0]["v"]["_type"], "psobject");
        assert!(
            w["blocked"][0]["v"].get("At").is_none(),
            "At absent when not known"
        );
        assert_eq!(w["outage"][0]["v"]["_type"], "hashtable");
        assert_eq!(w["outage"][0]["v"]["AutoJob"], "");
        let back = WatchState::from_w(&w).unwrap();
        assert_eq!(back.blocked, s.blocked);
        assert_eq!(back.outage, s.outage);
    }

    #[test]
    fn a_fresh_state_sends_empty_maps_and_null_dates() {
        let w = WatchState::default().to_w();
        let keys: Vec<&String> = w.as_object().unwrap().keys().collect();
        assert_eq!(
            keys,
            [
                "blocked",
                "lastAllowed",
                "probeFails",
                "scannedAt",
                "outage",
                "authAlerted",
                "current",
                "next",
                "handoff",
                "listening",
                "startedAt",
                "caches"
            ]
        );
        for (name, map) in CACHES {
            assert_eq!(w["caches"][name], if map { json!([]) } else { Value::Null });
        }
        same(&WatchState::from_w(&w).expect("decodes").to_w(), &w);
    }

    #[test]
    fn the_wake_leaves_no_entry_behind() {
        // a null entry alone decodes to an empty list, as the clear leaves it
        let mut w = full_w();
        w["blocked"] = json!([{"k": "codex", "v": null}]);
        w["outage"] = json!([{"k": "codex", "v": null}]);
        let mut s = WatchState::from_w(&w).unwrap();
        s.clear_for_wake();
        let w = s.to_w();
        for k in ["blocked", "lastAllowed", "outage"] {
            assert_eq!(w[k], json!([]), "{k}");
        }
        same(&w["probeFails"], &full_w()["probeFails"]);
        same(&w["authAlerted"], &full_w()["authAlerted"]);
    }

    #[test]
    fn a_w_off_the_schema_is_refused() {
        let bad = |f: fn(&mut Value)| {
            let mut w = full_w();
            f(&mut w);
            WatchState::from_w(&w).is_none()
        };
        assert!(
            bad(|w| w["blocked"] = json!({"claude": null})),
            "an object, not pairs"
        );
        assert!(
            bad(|w| w["probeFails"] = json!({"k": "a", "v": 1})),
            "one pair, not a list"
        );
        assert!(bad(|w| w["blocked"][0]["v"]["_type"] = json!("thing")));
        assert!(bad(|w| w["outage"][0]["v"]
            .as_object_mut()
            .unwrap()
            .clear()));
        assert!(bad(|w| w["lastAllowed"][0]["v"] = json!([1])));
        assert!(bad(|w| w["scannedAt"][0] = json!({"v": null})));
        assert!(bad(|w| w["current"] = json!(1)));
        assert!(bad(|w| {
            w.as_object_mut().unwrap().remove("listening");
        }));
        assert!(bad(|w| {
            w["caches"]
                .as_object_mut()
                .unwrap()
                .remove("ChatqUsageSent");
        }));
        assert!(bad(|w| w["caches"]["ChatqSummaryTriedAt"] = json!(5)));
        assert!(bad(|w| w["caches"]["ChatqAskSent"][0]["v"] = json!("r1")));
    }
}
