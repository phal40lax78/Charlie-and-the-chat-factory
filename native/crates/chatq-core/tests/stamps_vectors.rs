//! native/vectors/stamps.json (tests/vectors/stamps.ps1), under both
//! flavours: Get-ChatqStamp's and Add-ChatqLogLine's stamps of an instant in
//! a zone, through [stamp_utc] and [stamp_in]; and ConvertTo-ChatqDate of
//! the `at` of a JSON file as Read-ChatqJson reads it, through [date_of_in].
//! A case ran in a real Windows zone; its input gives what an answer can
//! depend on there, the offset, or the offsets either side of a DST change.

mod common;

use chatq_core::time::{Instant, Zone, date_of_in, stamp_in, stamp_utc};
use chrono::{DateTime, FixedOffset, Utc};
use serde_json::{Value, json};

fn instant(s: &str) -> Instant {
    DateTime::parse_from_rfc3339(s)
        .unwrap_or_else(|e| panic!("{s}: {e}"))
        .with_timezone(&Utc)
}

fn minutes(v: &Value) -> FixedOffset {
    let m = v.as_i64().unwrap_or_else(|| panic!("minutes, not {v}"));
    i32::try_from(m * 60)
        .ok()
        .and_then(FixedOffset::east_opt)
        .unwrap_or_else(|| panic!("an offset, not {m} minutes"))
}

/// The zone of a case, as far as its answer goes.
fn zone(input: &Value) -> Zone {
    match input.get("change").and_then(Value::as_str) {
        Some(at) => Zone::Change {
            at: instant(at),
            before: minutes(&input["before"]),
            after: minutes(&input["after"]),
        },
        None => Zone::Fixed(minutes(&input["utcOffsetMinutes"])),
    }
}

#[test]
fn stamps_read_and_write_as_powershell_does() {
    let mut report = common::Report::new("stamps.json");
    for case in common::load("stamps") {
        let z = zone(&case.input);
        for fl in case.flavours() {
            let got = match case.input["kind"].as_str() {
                Some("stamp") => {
                    let t = instant(case.input["at"].as_str().expect("a stamp case has at"));
                    json!({"utc": stamp_utc(t), "local": stamp_in(t, z)})
                }
                Some("date") => {
                    let text = case.input["text"].as_str().expect("a date case has text");
                    let file: Value = serde_json::from_str(text)
                        .unwrap_or_else(|e| panic!("'{}': {e}", case.name));
                    date_of_in(file.get("at"), fl, z)
                        .map_or(Value::Null, |t| Value::String(stamp_utc(t)))
                }
                k => {
                    report.fail(&case, fl, format!("a case of kind {k:?}"));
                    continue;
                }
            };
            report.check(&case, fl, &got);
        }
    }
    report.finish();
}
