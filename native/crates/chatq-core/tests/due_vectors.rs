//! native/vectors/due.json (tests/vectors/due.ps1): [gates::due_time],
//! [gates::lane] and [gates::rescan_due] against Get-ChatqDueTime and
//! Update-ChatqBlock's skip rule, in a zone of a fixed offset.

mod common;

use chatq_core::gates;
use chatq_core::json::ieq;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use chrono::FixedOffset;
use serde_json::{Value, json};

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

/// `$W.<map>[lane]` for the one entry a case may give: lanes are case-blind
/// hashtable keys.
fn entry(
    input: &Value,
    map: &str,
    field: &str,
    lane: &str,
    fl: Flavour,
    zone: Zone,
) -> Option<Instant> {
    let e = input.get(map)?;
    let key = e["lane"].as_str().expect("an entry has a lane");
    ieq(key, lane).then(|| at(&e[field], fl, zone))
}

fn answer(input: &Value, fl: Flavour) -> Value {
    let zone = zone_of(input);
    let now = at(&input["now"], fl, zone);
    let job = &input["job"];
    let lane = gates::lane(job);
    match input["fn"].as_str() {
        Some("due") => {
            let blocked = entry(input, "blocked", "until", &lane, fl, zone);
            let outage = entry(input, "outage", "next", &lane, fl, zone);
            let due = gates::due_time(blocked, outage, job, now, fl, zone);
            json!({ "due": due.map(stamp_utc) })
        }
        Some("rescan") => {
            let before = entry(input, "scanned", "at", &lane, fl, zone);
            let force = input["force"].as_bool().expect("force is a bool");
            let scanned = gates::rescan_due(before, now, force);
            let after = if scanned { Some(now) } else { before };
            json!({ "scanned": scanned, "scannedAt": after.map(stamp_utc) })
        }
        other => panic!("no fn {other:?}"),
    }
}

#[test]
fn due() {
    let mut r = common::Report::new("due");
    for case in common::load("due") {
        for fl in case.flavours() {
            let got = answer(&case.input, fl);
            r.check(&case, fl, &got);
        }
    }
    r.finish();
}
