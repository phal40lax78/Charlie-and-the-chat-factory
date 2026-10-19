//! native/vectors/state.json: data/state.json across a handoff, under both
//! flavours. A save case checks [WatchState::to_json] against the file
//! Save-ChatqWatchState wrote, field order included, and
//! [WatchState::restore_in] of that file against Restore-ChatqWatchState's;
//! a restore case checks the restore of a text, and for a text chatqd writes
//! that [WatchState::to_text] writes exactly it.

mod common;

use chatq_core::json;
use chatq_core::state::{Blocked, Outage, WatchState};
use chatq_core::time::{Instant, Zone, stamp_utc};
use chrono::{DateTime, FixedOffset, Utc};
use serde_json::{Map, Value, json};

/// The pid the generator's chatqd text names, and the one a save case's
/// file is checked against before it becomes 'PID'.
const PID: u32 = 4242;

fn instant(s: &Value) -> Instant {
    let s = s.as_str().unwrap_or_else(|| panic!("a stamp, not {s}"));
    DateTime::parse_from_rfc3339(s)
        .unwrap_or_else(|e| panic!("{s}: {e}"))
        .with_timezone(&Utc)
}

fn text(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

/// The run state a case describes, as the generator's New-NvStateRun builds
/// `$W` from it: lanes in the listed order, only alerted lanes in
/// authAlerted.
fn run_of(s: &Value) -> WatchState {
    let mut w = WatchState {
        started_at: s["startedAt"].as_str().unwrap().to_string(),
        current: text(&s["current"]),
        next: text(&s["next"]),
        handoff: s["handoff"] == true,
        listening: s["listening"] == true,
        ..Default::default()
    };
    for b in s["blocked"].as_array().unwrap() {
        w.blocked.push((
            b["lane"].as_str().unwrap().to_string(),
            Blocked {
                until: instant(&b["until"]),
                kind: b["type"].clone(),
                source: b["source"].clone(),
                at: b.get("at").map(instant),
            },
        ));
    }
    for o in s["outage"].as_array().unwrap() {
        w.outage.push((
            o["lane"].as_str().unwrap().to_string(),
            Outage {
                since: instant(&o["since"]),
                next_check: instant(&o["next"]),
                last_probe: instant(&o["lastProbe"]),
                status: o["status"].clone(),
                attempts: o["attempts"].as_i64().unwrap(),
                alerted: o["alerted"] == true,
                reminded: o["reminded"] == true,
                auto_job: text(&o["autoJob"]),
            },
        ));
    }
    for a in s["authAlerted"].as_array().unwrap() {
        if a["on"] == true {
            w.auth_alerted.push(a["lane"].as_str().unwrap().to_string());
        }
    }
    w
}

/// .NET's ordinal order: UTF-16 code units.
fn ordinal(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// A value with every object's keys sorted ordinally, as the generator's
/// ConvertTo-NvStateSorted leaves PowerShell's hashtables.
fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort_by(|a, b| ordinal(a, b));
            Value::Object(
                keys.into_iter()
                    .map(|k| (k.clone(), sorted(&m[k])))
                    .collect(),
            )
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        v => v.clone(),
    }
}

fn sorted_names(names: &[String]) -> Value {
    let mut n: Vec<&String> = names.iter().collect();
    n.sort_by(|a, b| ordinal(a, b));
    json!(n)
}

/// The file as the generator's ConvertTo-NvStateFile shows PowerShell's:
/// its fields in their order, pid as 'PID', the lanes sorted.
fn file_view(file: &Value) -> Value {
    let mut out = Map::new();
    for (k, v) in file.as_object().unwrap() {
        let v = match k.as_str() {
            "pid" => {
                assert_eq!(v, &json!(PID), "to_json writes the pid it is given");
                json!("PID")
            }
            "blocked" | "outage" => sorted(v),
            "authAlerted" => match v.as_array() {
                Some(a) => {
                    let names: Vec<String> = a.iter().map(|x| x.as_str().unwrap().into()).collect();
                    sorted_names(&names)
                }
                None => v.clone(),
            },
            _ => v.clone(),
        };
        out.insert(k.clone(), v);
    }
    Value::Object(out)
}

/// What a restore left, as the generator's Get-NvStateView shows it: the
/// lanes sorted, every time UTC 'o'.
fn restored_view(ok: bool, w: &WatchState) -> Value {
    let mut blocked = Map::new();
    for (k, b) in &w.blocked {
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
    for (k, o) in &w.outage {
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
        "restored": ok,
        "blocked": sorted_lanes(blocked),
        "outage": sorted_lanes(outage),
        "authAlerted": sorted_names(&w.auth_alerted),
    })
}

/// The lanes in ordinal order, each entry's fields left in theirs.
fn sorted_lanes(m: Map<String, Value>) -> Value {
    let mut lanes: Vec<(String, Value)> = m.into_iter().collect();
    lanes.sort_by(|a, b| ordinal(&a.0, &b.0));
    Value::Object(lanes.into_iter().collect())
}

#[test]
fn state_files_as_powershell_writes_and_reads_them() {
    let mut report = common::Report::new("state.json");
    for case in common::load("state") {
        let input = &case.input;
        let mins = input["utcOffsetMinutes"].as_i64().unwrap() as i32;
        let zone = Zone::Fixed(FixedOffset::east_opt(mins * 60).unwrap());
        let now = instant(&input["now"]);
        for fl in case.flavours() {
            if input["kind"] == "save" {
                let w = run_of(&input["state"]);
                let version = input["version"].as_str().unwrap();
                let file = w.to_json(PID, version, now);
                // the file PowerShell wrote, read back by chatqd
                let ps_file = &case.expect(fl)["file"];
                let mut back = WatchState::default();
                let ok = back.restore_in(Some(ps_file), now, fl, zone);
                let got = json!({"file": file_view(&file), "restored": restored_view(ok, &back)});
                report.check_ordered(&case, fl, &got);
                continue;
            }
            if let Some(state) = input.get("state") {
                let written = run_of(state).to_text(
                    PID,
                    input["version"].as_str().unwrap(),
                    instant(&input["heartbeat"]),
                );
                if written != input["text"].as_str().unwrap() {
                    report.fail(
                        &case,
                        fl,
                        format!("to_text wrote\n{written}\nnot the case's text"),
                    );
                    continue;
                }
            }
            let s = input["text"]
                .as_str()
                .and_then(|t| json::parse_tolerant_in(t.as_bytes(), fl).value);
            let mut w = WatchState::default();
            let ok = w.restore_in(s.as_ref(), now, fl, zone);
            report.check_ordered(&case, fl, &restored_view(ok, &w));
        }
    }
    report.finish();
}
