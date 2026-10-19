//! native/vectors/reply-triage.json through chatq_core::wire: each message's
//! verdict under its config and the line a poll of it alone logs
//! (Test-ChatqReplyMessage), then whole polls in order (Invoke-ChatqReplyPoll
//! -Force): what each logged, the caches it left, and where replies.json
//! says polling got to, with each save applied as the caller applies it.

mod common;

use chatq_core::culture::Culture;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp, stamp_utc};
use chatq_core::wire::{
    Feed, Kind, Pass, PollCaches, Save, TriageConfig, Verdict, poll_batch, triage,
};
use chrono::FixedOffset;
use common::{Case, Report, hex, load, same};
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

/// A case's rc as Get-ChatqReplyConfig and Get-ChatqPairKey read it back.
fn config(rc: &Value) -> TriageConfig {
    TriageConfig {
        topic: rc["topic"].as_str().unwrap_or("").to_string(),
        master: rc["master"].as_str().map(|m| Zeroizing::new(hex(m))),
        pair_id: rc["pairId"].as_str().map(str::to_string),
        pair_key: rc["pairKey"].as_bool() == Some(true),
    }
}

/// Get-ChatqReplyConfig's On, replies wanted: a topic, and the phone's key D
/// or a pairing in progress.
fn on(rc: &TriageConfig) -> bool {
    !rc.topic.is_empty()
        && (rc.master.as_ref().is_some_and(|m| m.len() == 32) || rc.pair_id.is_some())
}

fn verdict_json(v: &Verdict) -> Value {
    match v {
        Verdict::Junk { stage, error } => {
            json!({"junk": true, "stage": stage, "error": error, "kind": null})
        }
        Verdict::Candidate(k) => {
            let kind = match k {
                Kind::Reply => "reply",
                Kind::Compose => "compose",
                Kind::Pair => "pair",
            };
            json!({"junk": false, "stage": null, "error": null, "kind": kind})
        }
    }
}

fn utc(t: &str) -> Instant {
    parse_stamp(t, Flavour::Desktop).unwrap_or_else(|| panic!("no stamp: {t}"))
}

fn utc0() -> Zone {
    Zone::Fixed(FixedOffset::east_opt(0).unwrap())
}

/// One message: chatqd's verdict where the case holds one (native), else
/// PowerShell's; then, with replies on, a poll of it alone.
fn one_message(r: &mut Report, case: &Case, fl: Flavour) {
    let i = &case.input;
    let rc = config(&i["rc"]);
    let message = i["message"].as_str().unwrap_or("");
    let want = case.expect(fl);
    let verdict = triage(message, &rc, fl);
    let expected = match want.get("native") {
        Some(n) => n.clone(),
        None => {
            json!({"junk": want["junk"], "stage": want["stage"], "error": want["error"], "kind": want["kind"]})
        }
    };
    let got = verdict_json(&verdict);
    if !same(&got, &expected) {
        r.fail(case, fl, format!("want {expected}\n    got  {got}"));
        return;
    }
    if !on(&rc) {
        // replies off: a poll fetches nothing
        if want["log"].is_null() {
            r.pass();
        } else {
            r.fail(
                case,
                fl,
                format!("replies are off, yet PowerShell logged {}", want["log"]),
            );
        }
        return;
    }
    let mut caches = PollCaches::default();
    let line = json!({"id": "m1", "event": "message", "message": message}).to_string();
    let now = utc("2026-10-15T00:00:00Z");
    let pass = poll_batch(
        &mut caches,
        &rc,
        Feed::Text(&line),
        now,
        utc0(),
        &Culture::invariant(),
        fl,
    );
    let candidate = matches!(verdict, Verdict::Candidate(_));
    match pass {
        Pass::Candidate if candidate => r.pass(),
        Pass::Done { log, .. }
            if !candidate && log.len() == 1 && want["log"] == log[0].as_str() =>
        {
            r.pass()
        }
        p => r.fail(
            case,
            fl,
            format!(
                "a poll of it alone: {p:?}, PowerShell logged {}",
                want["log"]
            ),
        ),
    }
}

fn stamp(t: Option<Instant>) -> Value {
    t.map_or(Value::Null, |t| json!(stamp_utc(t)))
}

/// Whole polls in order, each at its time, in the case's zone and culture.
fn polls(r: &mut Report, case: &Case, fl: Flavour) {
    let i = &case.input;
    let rc = config(&i["rc"]);
    let offset = i["utcOffsetMinutes"].as_i64().expect("an offset") * 60;
    let zone = Zone::Fixed(FixedOffset::east_opt(offset as i32).expect("an offset in range"));
    let culture = Culture {
        name: i["culture"].as_str().expect("a culture").to_string(),
        time_sep: i["timeSep"].as_str().expect("a time separator").to_string(),
        ..Culture::invariant()
    };
    let mut caches = PollCaches::default();
    // replies.json
    let (mut last_id, mut last_polled_at) = (Value::Null, Value::Null);
    let mut steps = Vec::new();
    for step in i["steps"].as_array().expect("steps") {
        let at = step["at"].as_str().expect("a time");
        let now = utc(at);
        caches.polled_at = Some(now);
        let text;
        let feed = match step.get("fail") {
            Some(why) => Feed::Failed(why.as_str().expect("a failure's text")),
            None => {
                let lines = step["lines"].as_array().expect("lines");
                text = lines
                    .iter()
                    .map(|l| l.as_str().expect("a line"))
                    .collect::<Vec<_>>()
                    .join("\n");
                Feed::Text(&text)
            }
        };
        let log = match poll_batch(&mut caches, &rc, feed, now, zone, &culture, fl) {
            Pass::Candidate => {
                r.fail(case, fl, format!("the poll at {at} found a candidate"));
                return;
            }
            Pass::Done { log, save } => {
                match save {
                    Save::None => {}
                    Save::LastId { id, tags } => {
                        last_id = json!(id);
                        last_polled_at = json!(stamp_utc(now));
                        caches.saved(&tags, now);
                    }
                    Save::PolledAt => last_polled_at = json!(stamp_utc(now)),
                }
                log
            }
        };
        let junk: Map<String, Value> = caches
            .junk_log
            .iter()
            .map(|(k, j)| (k.clone(), json!({"at": stamp_utc(j.at), "count": j.count})))
            .collect();
        steps.push(json!({
            "acted": 0,
            "log": log,
            "junk": junk,
            "polledAt": stamp(caches.polled_at),
            "errAt": stamp(caches.err_at),
            "badIdAt": stamp(caches.bad_id_at),
            "savedAt": stamp(caches.saved_at),
            "handled": caches.handled.tags(),
            "lastId": last_id,
            "lastPolledAt": last_polled_at,
        }));
    }
    r.check(case, fl, &json!({"steps": steps}));
}

#[test]
fn reply_triage_vectors() {
    let mut r = Report::new("reply-triage.json");
    for case in load("reply-triage") {
        for fl in case.flavours() {
            if case.input.get("steps").is_some() {
                polls(&mut r, &case, fl);
            } else {
                one_message(&mut r, &case, fl);
            }
        }
    }
    r.finish();
}
