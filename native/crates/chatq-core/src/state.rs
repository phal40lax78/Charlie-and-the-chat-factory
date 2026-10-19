//! The watcher's run state `$W` and its file, data/state.json, as
//! [Save-ChatqWatchState](src/watcher.ps1) writes it and
//! [Restore-ChatqWatchState](src/watcher.ps1) reads it back after a handoff.
//! Either engine can hand over to the other through it.

use crate::json::{self, ieq};
use crate::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
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

/// The parts of [New-ChatqWatchState](src/watcher.ps1) that state.json
/// carries. Lanes keep the order they were read in.
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
}
