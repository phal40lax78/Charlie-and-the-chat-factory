//! native/vectors/gates.json (tests/vectors/gates.ps1): the watcher loop's
//! cheap gates in [chatq_core::gates], each against files in a data/ of the
//! case's own, read as chatqd reads them, in a zone of a fixed offset.

mod common;

use chatq_core::config::read_config;
use chatq_core::culture::Culture;
use chatq_core::fsx::read_json;
use chatq_core::gates::{self, BlockedLane};
use chatq_core::json::{self, ieq};
use chatq_core::paths::Paths;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use chrono::FixedOffset;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn zone_of(input: &Value) -> Zone {
    let m = input["utcOffsetMinutes"]
        .as_i64()
        .expect("a case has utcOffsetMinutes");
    Zone::Fixed(FixedOffset::east_opt(m as i32 * 60).expect("an offset"))
}

/// A stamp of the input, every one of which has a zone.
fn at(v: &Value, fl: Flavour, zone: Zone) -> Instant {
    let s = v.as_str().unwrap_or_else(|| panic!("a stamp, not {v}"));
    parse_stamp_in(s, fl, zone).unwrap_or_else(|| panic!("a stamp, not {s}"))
}

/// An input's list, empty when the case has none.
fn list<'a>(input: &'a Value, field: &str) -> &'a [Value] {
    input
        .get(field)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// The case's own data/, empty, as tests/vectors/common.ps1's Enter-NvData
/// names it.
fn data_of(name: &str) -> Paths {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/test-data/gates_vectors")
        .join(safe);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("data")).expect("a scratch data/");
    Paths::new(root.to_str().expect("a UTF-8 path"))
}

/// A data/ file from an input's object field (as JSON) or its text field (as
/// it is); with neither, no file.
fn write_file(path: &Path, input: &Value, obj: &str, text: &str) {
    let body = match (input.get(obj), input.get(text)) {
        (Some(v), _) => v.to_string(),
        (None, Some(t)) => t.as_str().expect("a text field").to_string(),
        (None, None) => return,
    };
    fs::create_dir_all(path.parent().expect("a folder")).expect("the folder");
    fs::write(path, body).expect("the file");
}

/// [Unprotect-ChatqSecret](src/alerts.ps1) on what a vector carries: a
/// secret not protected is its value; DPAPI opens none of those that are.
fn unprotect(s: &Value) -> Option<String> {
    let v = json::get(Some(s), "value");
    if !json::truthy(Some(s)) || !json::truthy(v) || json::truthy(json::get(Some(s), "protected")) {
        return None;
    }
    Some(json::to_ps_string(v))
}

/// Files aged against the case's clock: `{name, ageSeconds}`, or
/// `{name, dir: true}` for a folder.
fn make_files(p: &Paths, files: &[Value], now: SystemTime) {
    for f in files {
        let path = Path::new(&p.data).join(f["name"].as_str().expect("a name"));
        if f["dir"].as_bool() == Some(true) {
            fs::create_dir_all(&path).expect("the folder");
            continue;
        }
        fs::create_dir_all(path.parent().expect("a folder")).expect("the folder");
        fs::write(&path, "").expect("the file");
        let age = f["ageSeconds"].as_i64().expect("an age");
        let when = if age >= 0 {
            now - Duration::from_secs(age as u64)
        } else {
            now + Duration::from_secs(age.unsigned_abs())
        };
        fs::File::options()
            .write(true)
            .open(&path)
            .and_then(|h| h.set_modified(when))
            .expect("the file's time");
    }
}

fn soon(input: &Value, p: &Paths, now: Instant, fl: Flavour, zone: Zone) -> Value {
    let cfg = read_config(&p.config(), fl);
    let blocked: Vec<BlockedLane> = list(input, "blocked")
        .iter()
        .map(|b| BlockedLane {
            lane: b["lane"].as_str().expect("a lane"),
            until: at(&b["until"], fl, zone),
            kind: b["type"].as_str().expect("a type"),
            at: b.get("at").map(|a| at(a, fl, zone)),
        })
        .collect();
    let queued: Vec<Value> = list(input, "jobs")
        .iter()
        .filter(|j| json::eq_str(j.get("state"), "queued"))
        .cloned()
        .collect();
    let key = |e: &Value| {
        gates::soon_key(
            e["lane"].as_str().expect("a lane"),
            at(&e["until"], fl, zone),
        )
    };
    let sent: Vec<String> = list(input, "sentBefore").iter().map(key).collect();
    let file: Vec<String> = list(input, "fileHas").iter().map(key).collect();
    let r = gates::usage_soon(&cfg, &blocked, &queued, &sent, now, fl, zone);
    let mut due = r.due.clone();
    due.sort();
    // Use-ChatqUsageAlertState: a key data/usage-alerts.json has already
    // is not sent again
    let send: Vec<&String> = due
        .iter()
        .filter(|k| !file.iter().any(|f| ieq(f, k)))
        .collect();
    json!({ "next": r.next.map(stamp_utc), "due": due, "send": send, "alerts": send.len() })
}

fn answer(case: &common::Case, fl: Flavour) -> Value {
    let input = &case.input;
    let zone = zone_of(input);
    let now = at(&input["now"], fl, zone);
    let p = data_of(&case.name);
    let replies = p.replies();
    match input["fn"].as_str() {
        Some("replyOpen") => {
            write_file(&p.config(), input, "config", "configText");
            write_file(&replies, input, "replies", "repliesText");
            let cfg = read_config(&p.config(), fl);
            json!({ "open": gates::reply_open_in(&cfg, &replies, now, fl, zone) })
        }
        Some("held") => {
            let clock = UNIX_EPOCH + Duration::from_secs(now.timestamp() as u64);
            make_files(&p, list(input, "files"), clock);
            json!({ "waiting": gates::held_waiting(&p, clock) })
        }
        Some("auto") => {
            write_file(&p.config(), input, "config", "configText");
            write_file(&p.auto_state(), input, "autoState", "autoText");
            let cfg = read_config(&p.config(), fl);
            let st = read_json(&p.auto_state(), fl);
            json!({ "wanted": gates::auto_wanted(&cfg, st.as_ref()) })
        }
        Some("soon") => {
            write_file(&p.config(), input, "config", "configText");
            soon(input, &p, now, fl, zone)
        }
        Some("route") => {
            write_file(&p.config(), input, "config", "configText");
            let cfg = read_config(&p.config(), fl);
            let no_reply = input
                .get("noReply")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            json!({
                "links": gates::reply_links(&cfg, &unprotect),
                "answerable": gates::alert_answerable(&cfg, no_reply, &unprotect),
            })
        }
        Some("pollSeconds") => {
            write_file(&replies, input, "replies", "repliesText");
            let in_run = input["inRun"].as_bool().expect("inRun is a bool");
            let st = read_json(&replies, fl);
            json!({ "seconds": gates::reply_poll_seconds(st.as_ref(), in_run, now, fl, zone) })
        }
        Some("listenText") => {
            write_file(&replies, input, "replies", "repliesText");
            // the separator is the launcher's to hand on (--culture), so it
            // comes from the answer: PowerShell's culture gave it
            let sep = case.expect(fl)["timeSep"].as_str().expect("a separator");
            let culture = Culture {
                time_sep: sep.into(),
                ..Culture::invariant()
            };
            let st = read_json(&replies, fl);
            json!({ "timeSep": sep, "text": gates::listen_text(st.as_ref(), now, fl, zone, &culture) })
        }
        other => panic!("no fn {other:?}"),
    }
}

#[test]
fn gates() {
    let mut r = common::Report::new("gates");
    for case in common::load("gates") {
        for fl in case.flavours() {
            let got = answer(&case, fl);
            r.check(&case, fl, &got);
        }
    }
    r.finish();
}
