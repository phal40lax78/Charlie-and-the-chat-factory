//! native/vectors/timers.json (tests/vectors/timers.ps1) through chatqd's own
//! loop: [run] on a [Fake] host with the case's scripted clock, its jobs and
//! its answers. The fake records what PowerShell's stubs recorded, at the
//! same points: `repair` where the repair is weighed, `held summary`,
//! `auto` and `stray` where their gates are asked, `soon` at the soon gate,
//! `block <lane>` and `run #<seq>` at their steps, the keep-awake, state,
//! board and wait calls, and each watcher.log line. So the answer is the
//! one chatq-core/tests/timers_vectors.rs gives.
//!
//! A case with `openPasses` hands off at its first open pass (M2 listens
//! through the PS watcher): its passes before that one are checked, and the
//! handoff. M3 replays the rest.
//!
//! The same fake also holds the loop to what no vector pins: the respawn
//! after `queue empty`, a failed step's recorded attempt, the pick-failure
//! path, the soon pre-gate (SPEC 2.4, 3.6) and a job its own id does not
//! find.

use super::{Exit, Host, listen_after_empty, run};
use crate::watch::step::Outcome;
use chatq_core::gates::{self, BlockedLane, UsageSoon};
use chatq_core::jobs::{self, Written};
use chatq_core::json;
use chatq_core::state::WatchState;
use chatq_core::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use chatq_core::timers;
use chrono::{FixedOffset, TimeDelta, TimeZone, Utc};
use serde_json::{Value, json};
use std::io;
use std::time::SystemTime;

#[path = "../../../chatq-core/tests/common/mod.rs"]
mod common;

/// An input's list, empty when the case has none.
fn list<'a>(input: &'a Value, field: &str) -> &'a [Value] {
    input
        .get(field)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

fn seconds(input: &Value, field: &str) -> Vec<i64> {
    list(input, field)
        .iter()
        .map(|v| v.as_i64().expect("a whole number"))
        .collect()
}

/// The world the loop sees, scripted, and what it did there.
struct Fake {
    fl: Flavour,
    start: Instant,
    script: Vec<Instant>,
    /// passes begun, 1-based once the first is
    pass: usize,
    now: Instant,
    held: bool,
    /// passes with the reply window open
    open: Vec<i64>,
    /// the respawn case: the window opens from this call on, whatever the pass
    open_from_call: Option<usize>,
    calls: usize,
    strays: usize,
    soon_at: Option<Instant>,
    /// the soon gate's due keys, and data/usage-alerts.json as read
    soon_due: Vec<String>,
    usage_alerts: Option<Value>,
    /// ops whose step gives no answer, and what failing a job writes
    fail: Vec<&'static str>,
    failed_as: Option<Written>,
    /// each job, and whether its run is over
    jobs: Vec<(Value, bool)>,
    before: Vec<String>,
    passes: Vec<(i64, Vec<String>)>,
    after: Vec<String>,
    /// past the stop or `queue empty`: what follows is the exit
    leaving: bool,
    /// every record in its order
    trail: Vec<String>,
}

impl Fake {
    fn new(fl: Flavour, start: Instant, script: Vec<Instant>) -> Fake {
        Fake {
            fl,
            start,
            script,
            pass: 0,
            now: start,
            held: false,
            open: Vec::new(),
            open_from_call: None,
            calls: 0,
            strays: 0,
            soon_at: None,
            soon_due: Vec::new(),
            usage_alerts: None,
            fail: Vec::new(),
            failed_as: None,
            jobs: Vec::new(),
            before: Vec::new(),
            passes: Vec::new(),
            after: Vec::new(),
            leaving: false,
            trail: Vec::new(),
        }
    }

    fn of_case(input: &Value, fl: Flavour) -> Fake {
        // the case's zone, a fixed offset, as timers_vectors.rs reads it
        let m = input["utcOffsetMinutes"]
            .as_i64()
            .expect("utcOffsetMinutes");
        let zone = Zone::Fixed(FixedOffset::east_opt(m as i32 * 60).expect("an offset"));
        let start = parse_stamp_in(input["start"].as_str().expect("a start"), fl, zone)
            .expect("a start stamp");
        let script = seconds(input, "passes")
            .iter()
            .map(|s| start + TimeDelta::seconds(*s))
            .collect();
        let mut h = Fake::new(fl, start, script);
        h.held = input["held"].as_bool().unwrap_or(false);
        h.open = seconds(input, "openPasses");
        h.strays = list(input, "strayFiles").len();
        h.soon_at = input
            .get("soonSeconds")
            .and_then(Value::as_i64)
            .map(|s| start + TimeDelta::seconds(s));
        h.jobs = list(input, "jobs")
            .iter()
            .map(|j| (j.clone(), false))
            .collect();
        h
    }

    fn rec(&mut self, s: impl Into<String>) {
        let s = s.into();
        self.trail.push(s.clone());
        if self.leaving {
            self.after.push(s);
        } else if let Some((_, fired)) = self.passes.last_mut() {
            fired.push(s);
        } else {
            self.before.push(s);
        }
    }

    fn job(&mut self, id: &str) -> &mut (Value, bool) {
        self.jobs
            .iter_mut()
            .find(|(j, _)| j["id"] == id)
            .expect("a step for a job of the case")
    }

    fn answer(&self) -> Value {
        let passes: Vec<Value> = self
            .passes
            .iter()
            .map(|(at, fired)| json!({"at": at, "fired": fired}))
            .collect();
        json!({"before": self.before, "passes": passes, "after": self.after})
    }
}

/// A good answer: `w`, and the result.
fn ok(w: WatchState, result: Value) -> Outcome {
    let Value::Object(m) = result else {
        unreachable!("a result is an object")
    };
    Outcome::Ok(Box::new(w), m)
}

/// `ChatqAskSent` as [Test-ChatqAskLanded](src/ask.ps1) names an entry.
fn ask_name(w: &WatchState, rid: &str) -> String {
    let sent = w.caches.get("ChatqAskSent").and_then(Value::as_array);
    sent.into_iter()
        .flatten()
        .find(|p| p["k"] == rid)
        .and_then(|p| p["v"]["Title"].as_str())
        .unwrap_or("the chat")
        .to_string()
}

impl Host for Fake {
    fn now(&mut self) -> Instant {
        self.now
    }
    fn flavour(&self) -> Flavour {
        self.fl
    }
    /// The pass marker, as the Test-ChatqHeldWaiting stub is PowerShell's:
    /// it moves the clock, and the last scripted pass leaves a stop.
    fn take_stop(&mut self) -> bool {
        if self.pass == self.script.len() {
            return true;
        }
        self.pass += 1;
        self.now = self.script[self.pass - 1];
        let at = (self.now - self.start).num_seconds();
        self.passes.push((at, Vec::new()));
        false
    }
    fn stop_waiting(&mut self) -> bool {
        false
    }
    fn take_restart(&mut self) -> bool {
        false
    }
    fn wake_mtime(&mut self) -> Option<SystemTime> {
        None
    }
    fn wake_word(&mut self) -> String {
        unreachable!("no wake in a replay")
    }
    fn wake_seen(&mut self) {
        unreachable!("no wake in a replay")
    }
    fn jobs(&mut self) -> Vec<Value> {
        let open = self.jobs.iter().filter(|(_, done)| !done);
        open.map(|(j, _)| j.clone()).collect()
    }
    /// each job of that id's `file`, else `<id>.json`
    fn job_files(&mut self, id: &str) -> Vec<String> {
        let of_id = self
            .jobs
            .iter()
            .filter(|(j, _)| json::ieq(&json::to_ps_string(json::get(Some(j), "id")), id));
        of_id
            .map(|(j, _)| {
                j["file"]
                    .as_str()
                    .map_or(format!("{id}.json"), str::to_string)
            })
            .collect()
    }
    fn usage_soon(
        &mut self,
        _blocked: &[BlockedLane],
        _queued: &[Value],
        _sent: &[String],
        _now: Instant,
    ) -> UsageSoon {
        self.rec("soon");
        UsageSoon {
            next: self.soon_at,
            due: self.soon_due.clone(),
        }
    }
    fn reply_open(&mut self) -> bool {
        let Some(from) = self.open_from_call else {
            return self.open.contains(&(self.pass as i64));
        };
        self.calls += 1;
        let o = self.calls >= from;
        // as PowerShell prints a bool
        self.rec(format!("reply open: {}", if o { "True" } else { "False" }));
        o
    }
    fn repair_due(&mut self) -> bool {
        self.rec("repair");
        true
    }
    fn held_due(&mut self, tried_at: Option<Instant>) -> bool {
        if self.held {
            self.rec("held summary");
        }
        // the gate's 5-minute wait after a failed try
        self.held && tried_at.is_none_or(|t| self.now - t >= TimeDelta::minutes(5))
    }
    fn auto_wanted(&mut self) -> bool {
        self.rec("auto");
        true
    }
    fn stray_maybe(&mut self) -> bool {
        self.rec("stray");
        true
    }
    fn usage_alerts(&mut self) -> Option<Value> {
        assert!(!self.soon_due.is_empty(), "no soon key is due in a replay");
        self.usage_alerts.clone()
    }
    fn clear_defer(&mut self, _id: &str) -> io::Result<Written> {
        unreachable!("no wake in a replay")
    }
    fn fail_job(&mut self, id: &str, reason: &str) -> io::Result<Written> {
        let Some(written) = self.failed_as.clone() else {
            unreachable!("a pick of {id} failed")
        };
        self.rec(format!("fail {id}: {reason}"));
        Ok(written)
    }
    /// Each op as the stub of the function it runs records it.
    fn step(&mut self, op: &str, alert_job: Option<&str>, w: &WatchState, args: Value) -> Outcome {
        if self.fail.contains(&op) {
            self.rec(format!("{op} step failed"));
            return Outcome::NoAnswer(5);
        }
        let mut w = w.clone();
        match op {
            "repair" | "held" | "auto" => ok(w, json!({"sent": true})),
            "stray" => {
                // the step's own line, as the loop writes it after the sweep
                if self.strays > 0 {
                    let n = self.strays;
                    self.rec(format!(
                        "log: removed {n} stray file(s) and folder(s) from data/queue"
                    ));
                }
                ok(w, json!({"removed": self.strays}))
            }
            "ask-landed" => {
                for (rid, at) in w.ask_sent() {
                    if at.is_some_and(|a| timers::ask_landed_due(a, self.now)) {
                        let name = ask_name(&w, &rid);
                        self.rec(format!("reply log: ask {rid} {name}: landed"));
                        w.drop_ask_sent(&rid);
                    }
                }
                ok(w, json!({}))
            }
            "block" => {
                let ids = args["jobIds"].as_array().expect("jobIds");
                assert_eq!(ids.len(), 1, "one job a block step");
                let lane = gates::lane(&self.job(ids[0].as_str().unwrap()).0);
                self.rec(format!("block {lane}"));
                // Update-ChatqBlock stamps the lane as scanned
                w.scanned_at.set(&lane, stamp_utc(self.now).into());
                ok(w, json!({}))
            }
            "pick" => {
                // the step finds the job again as Find-ChatqJob -Exact does
                let id = args["jobId"].as_str().unwrap();
                let open = self.jobs();
                let Some(found) = jobs::find_exact(&open, id).cloned() else {
                    self.rec(format!("pick {id}: not found"));
                    return ok(w, json!({"gone": true}));
                };
                let job = self
                    .jobs
                    .iter_mut()
                    .find(|(j, _)| *j == found)
                    .expect("a job of the case");
                job.1 = true;
                let seq = job.0["seq"].clone();
                assert_eq!(alert_job, Some(format!("#{seq}").as_str()));
                self.rec(format!("run #{seq}"));
                ok(w, json!({"gone": false}))
            }
            "soon" => {
                self.rec("soon step");
                ok(w, json!({"soonAt": null}))
            }
            "job-write" => {
                self.rec(format!("job-write {args}"));
                ok(w, json!({"saved": true}))
            }
            "alert" => {
                let text = args["text"].as_str().unwrap_or_default();
                self.rec(format!("alert {} {text}", alert_job.unwrap_or("-")));
                ok(w, json!({"sent": true}))
            }
            _ => unreachable!("no {op} step in a replay"),
        }
    }
    fn awake(&mut self, on: bool) {
        self.rec(if on { "awake on" } else { "awake off" });
    }
    fn save_state(&mut self, _w: &WatchState) {
        self.rec("state");
    }
    fn board(&mut self) {
        self.rec("board");
    }
    fn wait(&mut self, until: Instant) {
        let s = (until - self.now).num_seconds();
        self.rec(format!("wait {s}"));
    }
    fn wlog(&mut self, text: &str) {
        // the stop is the way out: what follows it is the exit
        if text == "stop requested" {
            self.leaving = true;
        }
        self.rec(format!("log: {text}"));
        if text == "queue empty" {
            self.leaving = true;
        }
    }
    /// A timers case writes none, so a line here fails its comparison.
    fn dlog(&mut self, text: &str) {
        self.rec(format!("chatqd.log: {text}"));
    }
}

/// W as a case starts it: each of its `asks` sent `ageSeconds` before the
/// start, as the PowerShell case fills `$script:ChatqAskSent`.
fn w_of_case(input: &Value, start: Instant) -> WatchState {
    let mut w = WatchState::default();
    let asks: Vec<Value> = list(input, "asks")
        .iter()
        .map(|a| {
            let at = start - TimeDelta::seconds(a["ageSeconds"].as_i64().expect("an age"));
            json!({"k": a["rid"], "v": {
                "_type": "hashtable", "Rid": a["rid"], "At": stamp_utc(at), "ToolUseId": "tu1",
                "Answers": [], "Transcript": "chat.jsonl", "SessionId": "s1", "Title": a.get("title"),
            }})
        })
        .collect();
    w.caches.insert("ChatqAskSent".into(), Value::Array(asks));
    w
}

/// [super::super::run]'s finally, as far as the fake sees it: keep-awake
/// off and the state saved; then, after `queue empty`, its look for a
/// window opened as it left.
fn finish(h: &mut Fake, w: &WatchState, exit: &Exit) -> bool {
    h.awake(false);
    h.save_state(w);
    matches!(exit, Exit::Empty) && listen_after_empty(h)
}

#[test]
fn timers() {
    let mut r = common::Report::new("timers");
    let (mut replayed, mut handed) = (0, 0);
    for case in common::load("timers") {
        for fl in case.flavours() {
            let mut h = Fake::of_case(&case.input, fl);
            let mut w = w_of_case(&case.input, h.start);
            let exit = run(&mut h, &mut w);
            let want = case.expect(fl);
            let Some(first) = h.open.iter().min().copied() else {
                let respawn = finish(&mut h, &w, &exit);
                if matches!(exit, Exit::Handoff(_) | Exit::Restart) || respawn {
                    r.fail(&case, fl, "the loop did not end as it does in PS");
                    continue;
                }
                r.check(&case, fl, &h.answer());
                replayed += 1;
                continue;
            };
            // the passes before the first open one as PS ran them, then a
            // handoff before that pass does anything
            let mut passes: Vec<Value> =
                want["passes"].as_array().unwrap()[..first as usize].to_vec();
            passes.last_mut().unwrap()["fired"] = json!([]);
            let expect = json!({"before": want["before"], "passes": passes, "after": []});
            let why = match &exit {
                Exit::Handoff(why) => why.as_str(),
                _ => "",
            };
            if why != "the phone reply window is open" || !w.handoff {
                r.fail(&case, fl, "no handoff at the first open pass");
            } else if !common::same(&expect, &h.answer()) {
                r.fail(&case, fl, format!("want {expect}\n    got  {}", h.answer()));
            } else {
                r.pass();
                handed += 1;
            }
        }
    }
    eprintln!("timers: {replayed} replayed, {handed} handed off at their first open pass");
    r.finish();
}

/// tests/sections/watcher.ps1's check "the respawn after queue empty, the
/// window asked per call": shut at the pass's look and at the empty
/// recheck, open by the look after the lock is let go.
#[test]
fn the_respawn_after_queue_empty_asks_the_window_per_call() {
    let start = Utc.with_ymd_and_hms(2026, 10, 15, 9, 0, 0).unwrap();
    let mut h = Fake::new(Flavour::Desktop, start, vec![start]);
    h.open_from_call = Some(3);
    let mut w = WatchState::default();
    let exit = run(&mut h, &mut w);
    assert!(matches!(exit, Exit::Empty));
    let respawn = finish(&mut h, &w, &exit);
    let got: Vec<&str> = h
        .trail
        .iter()
        .filter(|s| s.starts_with("reply open: ") || s.starts_with("log: "))
        .map(String::as_str)
        .collect();
    // the PS check's sequence, less what watch::run does itself: its
    // `started` line, its `stopped` line just before the last look, and the
    // one watcher it starts when finish says so
    let want = [
        "reply open: False",
        "reply open: False",
        "log: queue empty",
        "reply open: True",
        "log: a phone alert went out as this watcher left - starting another to listen",
    ];
    assert_eq!(got, want);
    assert!(respawn, "one watcher started");
}

/// A case's input with one Claude job, `more` merged in.
fn input_with(job: Value, more: Value) -> Value {
    let mut input = json!({
        "start": "2026-10-15T09:00:00.0000000Z", "utcOffsetMinutes": 0, "passes": [0], "jobs": [job],
    });
    for (k, v) in more.as_object().into_iter().flatten() {
        input[k] = v.clone();
    }
    input
}

/// A job that waits till evening, so no pass picks it.
fn waiting_job() -> Value {
    json!({"id": "j1", "seq": 1, "state": "queued", "title": "chat 1", "provider": "claude",
           "notBefore": "2026-10-15T21:00:00.0000000Z"})
}

/// SPEC 3.6 "Failure", decision 3 of 2026-10-18: a `block`, `held` or
/// `ask-landed` step with no good answer counts as tried, so the next pass
/// does not run it again.
#[test]
fn a_failed_step_records_its_attempt() {
    let more = json!({"passes": [0, 10], "held": true, "asks": [{"rid": "r1", "ageSeconds": 30}]});
    let input = input_with(waiting_job(), more);
    let mut h = Fake::of_case(&input, Flavour::Desktop);
    h.fail = vec!["block", "held", "ask-landed"];
    let mut w = w_of_case(&input, h.start);
    assert!(matches!(run(&mut h, &mut w), Exit::Stopped));
    let tried = |op: &str| {
        let line = format!("{op} step failed");
        h.trail.iter().filter(|s| **s == line).count()
    };
    let runs = [tried("block"), tried("held"), tried("ask-landed")];
    assert_eq!(runs, [1, 1, 1], "{:?}", h.trail);
    assert_eq!(w.scanned_at.date("claude"), Some(h.start));
    assert_eq!(w.summary_tried_at(), Some(h.start));
    assert!(w.ask_sent().is_empty());
}

/// SPEC 2.4: a pick step with no good answer. The line; the job failed only
/// while still open, a file chatqd may not write through a `job-write`
/// step; then, only for a job so failed, its alert under `#<seq>`; and an
/// alert that does not go said in chatqd.log.
#[test]
fn a_pick_that_fails_fails_its_job_once() {
    let job =
        json!({"id": "j1", "seq": 1, "state": "queued", "title": "chat 1", "provider": "claude"});
    let why = "exited 5 with no answer";
    let alert = format!("alert #1 chat 1 \u{00B7} chatq error: helper step {why}");
    let args = json!({"jobId": "j1", "complete": jobs::fail_complete(why)});
    let by_step =
        "chatqd.log: j1.json reads repaired, lossy or as a list - a job-write step writes it";
    let gone = format!("chatqd.log: the failed alert for #1 did not go: helper step {why}");
    let cases: [(Written, Vec<&'static str>, Vec<String>); 4] = [
        (Written::Left, vec!["pick"], vec![]),
        (
            Written::Step(job.clone()),
            vec!["pick"],
            vec![by_step.into(), format!("job-write {args}"), alert.clone()],
        ),
        (Written::Saved(job.clone()), vec!["pick"], vec![alert]),
        (
            Written::Saved(job.clone()),
            vec!["pick", "alert"],
            vec!["alert step failed".into(), gone],
        ),
    ];
    for (written, fail, tail) in cases {
        let mut h = Fake::of_case(&input_with(job.clone(), json!({})), Flavour::Desktop);
        h.fail = fail;
        h.failed_as = Some(written);
        let mut w = WatchState {
            current: Some("j1".into()),
            ..Default::default()
        };
        run(&mut h, &mut w);
        let from = h
            .trail
            .iter()
            .position(|s| s == "pick step failed")
            .expect("a pick");
        let to = from
            + h.trail[from..]
                .iter()
                .position(|s| s == "state")
                .expect("a save");
        let mut want = vec![
            "pick step failed".to_string(),
            format!("log: #1 error: helper step {why}"),
            format!("fail j1: {why}"),
        ];
        want.extend(tail);
        assert_eq!(h.trail[from..to], want[..]);
        assert_eq!(w.current, None);
    }
}

/// SPEC 3.6 "Pre-gates", soon: a due key data/usage-alerts.json already
/// holds, in any case, is recorded as sent with no step; any other due key
/// means a `soon` step.
#[test]
fn a_heads_up_already_on_file_runs_no_step() {
    for (due, steps) in [
        (vec!["s|claude|1"], 0),
        (vec!["s|claude|1", "s|codex|2"], 1),
    ] {
        let mut h = Fake::of_case(&input_with(waiting_job(), json!({})), Flavour::Desktop);
        h.soon_due = due.iter().map(|k| k.to_string()).collect();
        h.usage_alerts = Some(json!({"S|CLAUDE|1": "2026-10-15T08:00:00.0000000Z"}));
        let mut w = WatchState::default();
        run(&mut h, &mut w);
        let n = h.trail.iter().filter(|s| *s == "soon step").count();
        assert_eq!(n, steps, "{due:?}: {:?}", h.trail);
        assert_eq!(w.usage_sent(), ["s|claude|1"], "{due:?}");
    }
}

/// tests/sections/watcher.ps1's check "a queued job its own id does not
/// find": two files holding one id, and a blank id. Each is passed over with
/// no step, said once in watcher.log with its files, while the job after it
/// runs and the passes after wait. Before, the pick found nothing and the
/// next pass picked the same job at once: a step a pass, every pass.
#[test]
fn a_job_its_own_id_does_not_find_is_passed_over() {
    let job = |id: &str, seq: u32, file: &str| {
        json!({"id": id, "seq": seq, "state": "queued", "title": format!("chat {seq}"),
               "provider": "claude", "file": file})
    };
    let input = json!({
        "start": "2026-10-15T09:00:00.0000000Z", "utcOffsetMinutes": 0, "passes": [0, 60, 120],
        "jobs": [job("d", 1, "a.json"), job("d", 2, "b.json"), job(" ", 3, "blank.json"), job("g", 4, "g.json")],
    });
    let mut h = Fake::of_case(&input, Flavour::Desktop);
    let mut w = WatchState::default();
    assert!(matches!(run(&mut h, &mut w), Exit::Stopped));
    let got: Vec<&str> = h
        .trail
        .iter()
        .map(String::as_str)
        .filter(|s| {
            s.starts_with("log: ")
                || s.starts_with("block ")
                || s.starts_with("run ")
                || s.starts_with("pick ")
                || s.starts_with("wait ")
        })
        .collect();
    let lost = "does not find one job - left queued, not run, until that is put right";
    let want = [
        format!("log: a.json, b.json: the id 'd' {lost}"),
        format!("log: blank.json: the id ' ' {lost}"),
        "block claude".into(),
        "run #4".into(),
        "wait 900".into(),
        "wait 900".into(),
        "log: stop requested".into(),
    ];
    assert_eq!(got, want);
    // the three are left queued, not failed, not written
    assert_eq!(h.jobs.iter().filter(|(_, done)| !done).count(), 3);
}
