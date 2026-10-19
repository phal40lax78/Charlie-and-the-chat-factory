//! native/vectors/reply-state.json through [replystate::use_state]: each
//! case's data/replies.json read under replies.lock, changed and saved at
//! the case's now, as Use-ChatqReplyState (src/phone.ps1) does, and the
//! saved file, or the throw, checked against both PowerShells' answers.
//! A file chatqd refuses to write back (`repair`, SPEC 2.2) must be left
//! alone; its read and save are then checked one step lower.

mod common;

use chatq_core::fsx;
use chatq_core::json::parse_tolerant_in;
use chatq_core::paths::Paths;
use chatq_core::replystate::{self, Error, ReplyState};
use chatq_core::time::{Flavour, Instant, Zone, stamp_utc};
use chrono::{DateTime, FixedOffset, TimeDelta, Utc};
use common::{Case, Report};
use serde_json::{Map, Value, json};
use std::cmp::Ordering;
use std::fs;
use std::path::Path;

fn utc(s: &str) -> Instant {
    DateTime::parse_from_rfc3339(s)
        .unwrap_or_else(|e| panic!("{s}: {e}"))
        .with_timezone(&Utc)
}

/// `[StringComparer]::Ordinal`: by UTF-16 code unit.
fn ordinal(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Get-NvReplyStateB32: a pick's name.
fn b32(i: i64) -> String {
    const ABC: &[u8] = b"abcdefghijklmnopqrstuvwxyz234567";
    (0..6)
        .rev()
        .map(|k| char::from(ABC[((i >> (5 * k)) & 31) as usize]))
        .collect()
}

/// New-NvReplyStateRecipe: more alerts and picks than the caps keep.
fn recipe(r: &Value) -> Value {
    let num = |k: &str| r[k].as_i64().unwrap_or_else(|| panic!("recipe {k}"));
    let (n, step, base) = (
        num("alerts"),
        num("alertStep"),
        utc(r["alertBase"].as_str().unwrap()),
    );
    let mut alerts = Map::new();
    for i in 0..n {
        let at = if i == 0 {
            Value::Null
        } else {
            stamp_utc(base + TimeDelta::minutes(i * step % n)).into()
        };
        alerts.insert(
            format!("a{i:03}"),
            json!({"at": at, "expires": r["alertExpires"]}),
        );
    }
    let (m, step, base) = (
        num("picks"),
        num("pickStep"),
        utc(r["pickBase"].as_str().unwrap()),
    );
    let mut picks = Map::new();
    for i in 0..m {
        let at = stamp_utc(base + TimeDelta::seconds(i * step % m));
        picks.insert(
            b32(i),
            json!({"kind": "k", "at": at, "expires": r["pickExpires"]}),
        );
    }
    json!({"alerts": alerts, "picks": picks, "seen": r["seen"]})
}

/// Get-NvReplyStateBytes: the bytes a case's file starts as.
fn file_bytes(f: &Value) -> Option<Vec<u8>> {
    if f.is_null() {
        None
    } else if let Some(h) = f.get("hex") {
        Some(common::hex(h.as_str().unwrap()))
    } else if let Some(t) = f.get("text") {
        Some(t.as_str().unwrap().as_bytes().to_vec())
    } else {
        Some(f["json"].to_string().into_bytes())
    }
}

/// Invoke-NvReplyState's block: the case's change.
fn apply(s: &mut ReplyState, change: &Value, now: Instant) {
    if let Some(id) = change.get("lastId") {
        s.last_id = Some(id.as_str().unwrap().to_string());
    }
    if change["polled"] == true {
        s.last_polled_at = Some(now);
    }
}

/// The answer of a save: the file, its hashtables' names sorted; or, for
/// the recipe, the names kept.
fn answer(input: &Value, saved: &Value) -> Value {
    let o = saved.as_object().expect("the saved file is an object");
    let names = |k: &str, sort: bool| {
        let mut v: Vec<&str> = o[k]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        if sort {
            v.sort_by(|a, b| ordinal(a, b));
        }
        json!(v)
    };
    if !input["recipe"].is_null() {
        return json!({"threw": null, "alerts": names("alerts", false),
            "picks": names("picks", false), "seen": names("seen", true)});
    }
    let mut file = Map::new();
    for (k, v) in o {
        let v = match (k.as_str(), v) {
            ("seen" | "refused" | "downSent", Value::Object(m)) => {
                let mut e: Vec<_> = m.iter().collect();
                e.sort_by(|a, b| ordinal(a.0, b.0));
                Value::Object(e.into_iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            }
            _ => v.clone(),
        };
        file.insert(k.clone(), v);
    }
    json!({"threw": null, "file": file})
}

fn run(report: &mut Report, case: &Case, fl: Flavour, dir: &Path) {
    let input = &case.input;
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir).unwrap();
    let p = Paths::new(dir.to_str().unwrap());
    if input["noData"] != true {
        fs::create_dir_all(&p.data).unwrap();
    }
    if !input["config"].is_null() {
        fs::write(p.config(), input["config"].to_string()).unwrap();
    }
    let before = if input["recipe"].is_null() {
        file_bytes(&input["file"])
    } else {
        Some(recipe(&input["recipe"]).to_string().into_bytes())
    };
    if let Some(b) = &before {
        fs::write(p.replies(), b).unwrap();
    }
    let east = input["utcOffsetMinutes"].as_i64().unwrap() as i32 * 60;
    let zone = Zone::Fixed(FixedOffset::east_opt(east).unwrap());
    let now = utc(input["now"].as_str().unwrap());
    let hours = input["hours"].as_f64().unwrap();
    let change = &input["change"];

    let held = (input["lock"] == "held").then(|| fsx::try_lock(&p.replies_lock()).unwrap());
    let r = replystate::use_state(&p, hours, now, fl, zone, |s| apply(s, change, now));
    drop(held);
    let after = fs::read(p.replies()).ok();
    if input["repair"] == true && !matches!(r, Err(Error::PsOnly(_))) {
        return report.fail(
            case,
            fl,
            format!("a file that needed repair, not left to PowerShell: {r:?}"),
        );
    }

    let got = match r {
        Ok(()) => match serde_json::from_slice(after.as_deref().unwrap_or_default()) {
            Ok(saved) => answer(input, &saved),
            Err(e) => return report.fail(case, fl, format!("the saved file: {e}")),
        },
        Err(Error::PsOnly(why)) if input["repair"] == true => {
            if after != before {
                return report.fail(case, fl, "a file left to PowerShell was changed");
            }
            report.pass();
            // what chatqd's read makes of it, saved
            let v = parse_tolerant_in(before.as_deref().unwrap(), fl)
                .value
                .expect(&why);
            let mut s = match ReplyState::from_json(&v, fl, zone) {
                Ok(s) => s,
                Err(e) => return report.fail(case, fl, format!("the repaired read: {e}")),
            };
            apply(&mut s, change, now);
            match s.to_json(hours, now) {
                Ok(saved) => answer(input, &saved),
                Err(e) => return report.fail(case, fl, format!("the repaired save: {e}")),
            }
        }
        Err(e @ (Error::PsOnly(_) | Error::Io(_))) => return report.fail(case, fl, e),
        Err(e) => {
            let threw = match e {
                Error::Locked => "locked",
                Error::Unreadable(_) => "unreadable",
                _ => "invalid",
            };
            let file = match &after {
                None => Value::Null,
                Some(a) if before.as_ref() == Some(a) => "unchanged".into(),
                Some(_) => "changed".into(),
            };
            json!({"threw": threw, "file": file})
        }
    };
    report.check_ordered(case, fl, &got);
}

#[test]
fn every_case_saves_as_powershell_does() {
    let cases = common::load("reply-state");
    let root =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/reply_state_vectors");
    let mut report = Report::new("reply-state.json");
    for (i, case) in cases.iter().enumerate() {
        for fl in case.flavours() {
            run(
                &mut report,
                case,
                fl,
                &root.join(format!("{i:03}-{}", common::edition(fl))),
            );
        }
    }
    report.finish();
}
