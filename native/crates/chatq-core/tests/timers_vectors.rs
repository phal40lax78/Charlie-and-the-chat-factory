//! native/vectors/timers.json (tests/vectors/timers.ps1): the watcher loop's
//! timers in [chatq_core::timers], replayed pass by pass on the same scripted
//! clock PowerShell ran [Invoke-ChatqWatchLoop](src/watcher.ps1) on. This
//! runner is the loop's branch order; the timers themselves are the library's.
//! Chatqd grows its own loop in M2 against these same answers.

mod common;

use chatq_core::culture::Culture;
use chatq_core::gates;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp_in};
use chatq_core::timers::{self, Timers};
use chrono::{FixedOffset, TimeDelta};
use serde_json::{Value, json};
use std::collections::HashMap;

/// The case's zone, a fixed offset so no zone database is needed.
fn zone_of(input: &Value) -> Zone {
    let m = input["utcOffsetMinutes"]
        .as_i64()
        .expect("a case has utcOffsetMinutes");
    Zone::Fixed(FixedOffset::east_opt(m as i32 * 60).expect("an offset"))
}

/// An input's list, empty when the case has none.
fn list<'a>(input: &'a Value, field: &str) -> &'a [Value] {
    input
        .get(field)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// Whole seconds a case's field holds, in its order.
fn seconds(input: &Value, field: &str) -> Vec<i64> {
    list(input, field)
        .iter()
        .map(|v| v.as_i64().expect("a whole number"))
        .collect()
}

/// A queued job of the case, in the order data/queue gives it back.
struct Job {
    value: Value,
    lane: String,
    seq: i64,
    done: bool,
}

/// An answer the phone sent, waiting out [timers::ASK_LANDED_SECONDS].
struct Ask {
    rid: String,
    name: String,
    at: Instant,
}

fn answer(input: &Value, fl: Flavour) -> Value {
    let zone = zone_of(input);
    let start =
        parse_stamp_in(input["start"].as_str().expect("a start"), fl, zone).expect("a start stamp");
    let script: Vec<Instant> = seconds(input, "passes")
        .iter()
        .map(|s| start + TimeDelta::seconds(*s))
        .collect();
    let open = seconds(input, "openPasses");
    let polled_on = seconds(input, "polledPasses");
    let poll_seconds = input["pollSeconds"].as_u64().expect("pollSeconds") as u32;
    let held = input["held"].as_bool().unwrap_or(false);
    let strays = list(input, "strayFiles").len();
    let soon_at = input
        .get("soonSeconds")
        .and_then(Value::as_i64)
        .map(|s| start + TimeDelta::seconds(s));
    let mut jobs: Vec<Job> = list(input, "jobs")
        .iter()
        .map(|j| Job {
            lane: gates::lane(j),
            seq: j["seq"].as_i64().expect("a seq"),
            value: j.clone(),
            done: false,
        })
        .collect();
    let mut asks: Vec<Ask> = list(input, "asks")
        .iter()
        .map(|a| Ask {
            rid: a["rid"].as_str().expect("a rid").to_string(),
            name: a
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("the chat")
                .to_string(),
            at: start - TimeDelta::seconds(a["ageSeconds"].as_i64().expect("an age")),
        })
        .collect();

    // Restore-ChatqWatchState, then Repair-ChatqInterrupted, before pass 1
    let before = ["repair"];
    let mut out: Vec<Value> = Vec::new();
    let mut after: Vec<&str> = Vec::new();
    let mut t = Timers::new();
    let mut scanned: HashMap<String, Instant> = HashMap::new();
    let mut listening = false;
    let mut reply_was_open = false;
    let mut emptied = false;
    for (i, now) in script.iter().copied().enumerate() {
        let pass = i as i64 + 1;
        let mut fired: Vec<String> = Vec::new();
        if held {
            fired.push("held summary".into());
        }
        let reply_open = open.contains(&pass);
        if reply_was_open && !reply_open {
            fired.push("log: replies closed".into());
        }
        reply_was_open = reply_open;
        let poll_every = timers::poll_every(reply_open, poll_seconds);
        let mut polled = false;
        if reply_open {
            fired.push(format!("poll {poll_every}"));
            polled = polled_on.contains(&pass);
        }
        if !asks.is_empty() {
            let mut waiting = Vec::new();
            for a in asks {
                if timers::ask_landed_due(a.at, now) {
                    fired.push(format!("reply log: ask {} {}: landed", a.rid, a.name));
                } else {
                    waiting.push(a);
                }
            }
            asks = waiting;
        }
        if t.auto_due(now) {
            fired.push("auto".into());
        }
        if t.stray_due(now) {
            fired.push("stray".into());
            if strays > 0 {
                fired.push(format!(
                    "log: removed {strays} stray file(s) and folder(s) from data/queue"
                ));
            }
        }
        let queued: Vec<usize> = (0..jobs.len()).filter(|n| !jobs[*n].done).collect();
        let at = (now - start).num_seconds();
        if queued.is_empty() && reply_open {
            // nothing to run, only listening: the state and the board on the
            // way in and whenever a poll did something, and no keep-awake
            if !listening || polled {
                fired.push("awake off".into());
                fired.push("state".into());
                fired.push("board".into());
            }
            if !listening {
                listening = true;
                let text = gates::listen_text(None, now, fl, zone, &Culture::invariant());
                fired.push(format!("log: listening for phone replies {text}"));
            }
            if !polled {
                fired.push(format!("wait {poll_every}"));
            }
            out.push(json!({ "at": at, "fired": fired }));
            continue;
        }
        listening = false;
        if queued.is_empty() {
            fired.push("awake off".into());
            fired.push("state".into());
            fired.push("board".into());
            // the queue and the window are looked at once more on the way
            // out; no vector changes either within a pass
            fired.push("log: queue empty".into());
            out.push(json!({ "at": at, "fired": fired }));
            emptied = true;
            break;
        }
        let mut next_at = timers::default_next_at(now);
        let mut pick = None;
        for n in queued {
            let lane = jobs[n].lane.clone();
            if gates::rescan_due(scanned.get(&lane).copied(), now, false) {
                fired.push(format!("block {lane}"));
                scanned.insert(lane, now);
            }
            match gates::due_time(None, None, &jobs[n].value, now, fl, zone) {
                Some(d) => {
                    if d < next_at {
                        next_at = d;
                    }
                }
                None => {
                    pick = Some(n);
                    break;
                }
            }
        }
        if let Some(n) = pick {
            fired.push("awake on".into());
            fired.push(format!("run #{}", jobs[n].seq));
            jobs[n].done = true;
            fired.push("state".into());
            fired.push("board".into());
            // a job just ran: round again at once, with no wait
            out.push(json!({ "at": at, "fired": fired }));
            continue;
        }
        fired.push("soon".into());
        next_at = soon_at.filter(|s| *s < next_at).unwrap_or(next_at);
        let awake = if timers::keep_awake(now, next_at) {
            "on"
        } else {
            "off"
        };
        fired.push(format!("awake {awake}"));
        if t.board_due(now, reply_open, polled) {
            fired.push("state".into());
            fired.push("board".into());
        }
        let wake = timers::wake_at(next_at, now, reply_open, poll_every);
        fired.push(format!("wait {}", (wake - now).num_seconds()));
        out.push(json!({ "at": at, "fired": fired }));
    }
    // the loop's own way out: data/stop, unless the queue emptied
    if !emptied {
        after.push("log: stop requested");
    }
    after.push("awake off");
    after.push("state");
    json!({ "before": before, "passes": out, "after": after })
}

#[test]
fn timers() {
    let mut r = common::Report::new("timers");
    for case in common::load("timers") {
        for fl in case.flavours() {
            let got = answer(&case.input, fl);
            r.check(&case, fl, &got);
        }
    }
    r.finish();
}
