//! [Invoke-ChatqWatchLoop](src/watcher.ps1) as M3 runs it (SPEC 7): the
//! control flow, the gates, the board and the reply poll native, each piece
//! of PowerShell work a helper step (SPEC 3.6). An open reply window is
//! listened to here; only a panic, or the system refusing chatqd its
//! connect, hands over to the PS watcher. Every input
//! from outside and every effect goes through [Host], so a replay can stand
//! in for the files, the clock and the steps.

use super::step::{self, Outcome};
use super::wait::{mtime, wait_until};
use super::{Ctx, KeepAwake, reply, save_state};
use crate::VERSION;
use crate::http::Fail;
use chatq_core::board;
use chatq_core::config::read_config;
use chatq_core::fsx::{read_json, save_text, write_ascii_line};
use chatq_core::gates::{self, BlockedLane, UsageSoon};
use chatq_core::jobs::{
    self, Written, any_queued, found_by_id, get_jobs, lane, read_jobs, state_in,
};
use chatq_core::json::{self, ieq, parse_tolerant_in};
use chatq_core::paths;
use chatq_core::state::WatchState;
use chatq_core::time::{Flavour, Instant, Zone, stamp_utc};
use chatq_core::timers::{self, Timers};
use chrono::{DateTime, TimeDelta, Utc};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::time::SystemTime;

/// How the loop ended, and so what last.json says and what comes after.
pub enum Exit {
    Stopped,
    Empty,
    Restart,
    /// a panic, or the system refusing chatqd a poll's connect: the PS
    /// watcher takes over
    Handoff(String),
}

/// A `-Now` is a request of the moment: older than this it is ignored.
const NOW_FRESH: TimeDelta = TimeDelta::minutes(5);

/// `$script:ChatqDot`
const DOT: char = '\u{00B7}';

/// Everything the loop reads from outside it and everything it does there.
pub trait Host {
    /// `Get-Date`
    fn now(&mut self) -> Instant;
    /// how the PowerShell chatqd stands in for reads a stamp
    fn flavour(&self) -> Flavour;
    /// the `panic` seam (SPEC 6.5): the first pass panics
    fn panic_seam(&self) -> bool {
        false
    }
    /// data/stop is there; it is deleted
    fn take_stop(&mut self) -> bool;
    /// data/stop is there; it is left
    fn stop_waiting(&mut self) -> bool;
    /// data/restart is there; it is deleted
    fn take_restart(&mut self) -> bool;
    /// data/wake's `LastWriteTimeUtc`, None when it is not there
    fn wake_mtime(&mut self) -> Option<SystemTime>;
    /// data/wake's word, trimmed; "" when it does not read
    fn wake_word(&mut self) -> String;
    /// `Send-ChatqWake 'seen'`
    fn wake_seen(&mut self);
    /// [Get-ChatqJobs](src/queue.ps1), every job in the queue's order
    fn jobs(&mut self) -> Vec<Value>;
    /// [jobs::files_with_id]
    fn job_files(&mut self, id: &str) -> Vec<String>;
    /// [gates::usage_soon] on [Get-ChatqConfig](src/queue.ps1) as it is: the
    /// one place a replay stands in for Send-ChatqUsageSoon's answer
    fn usage_soon(
        &mut self,
        blocked: &[BlockedLane],
        queued: &[Value],
        sent: &[String],
        now: Instant,
    ) -> UsageSoon;
    /// [Test-ChatqReplyOpen](src/phone.ps1)
    fn reply_open(&mut self) -> bool;
    /// [Get-ChatqReplyPollSeconds](src/phone-down.ps1)
    fn poll_seconds(&mut self) -> u32;
    /// [Invoke-ChatqReplyPoll](src/phone.ps1) `-MinSeconds <min_seconds>`,
    /// as [reply::Poller::poll] runs it: how many messages were acted on
    fn poll(&mut self, w: &mut WatchState, min_seconds: u32) -> u32;
    /// the system refused a poll its connect ([reply::Poller::forbidden])
    fn poll_forbidden(&mut self) -> bool {
        false
    }
    /// [Get-ChatqReplyListenText](src/phone-down.ps1)
    fn listen_text(&mut self) -> String;
    /// [Write-ChatqBoard](src/alerts.ps1) while only listening: a `board`
    /// step, as [reply::Poller::board] runs it
    fn board_step(&mut self, w: &mut WatchState);
    /// [gates::repair_due] on the queue as it is
    fn repair_due(&mut self) -> bool;
    /// [gates::held_summary_due], the summary's last failed try `tried_at`
    fn held_due(&mut self, tried_at: Option<Instant>) -> bool;
    /// [gates::auto_wanted]
    fn auto_wanted(&mut self) -> bool;
    /// [gates::stray_maybe]
    fn stray_maybe(&mut self) -> bool;
    /// data/usage-alerts.json as read, with no lock and no retry
    fn usage_alerts(&mut self) -> Option<Value>;
    /// [jobs::clear_defer]
    fn clear_defer(&mut self, id: &str) -> io::Result<Written>;
    /// [jobs::fail_job]
    fn fail_job(&mut self, id: &str, reason: &str) -> io::Result<Written>;
    /// [step::run]
    fn step(&mut self, op: &str, alert_job: Option<&str>, w: &WatchState, args: Value) -> Outcome;
    /// [Set-ChatqKeepAwake](src/watcher.ps1)
    fn awake(&mut self, on: bool);
    /// [Save-ChatqWatchState](src/watcher.ps1)
    fn save_state(&mut self, w: &WatchState);
    /// [Write-ChatqBoard](src/alerts.ps1), from the state just saved
    fn board(&mut self);
    /// [Wait-ChatqUntil](src/watcher.ps1)
    fn wait(&mut self, until: Instant);
    /// [Write-ChatqWatchLog](src/watcher.ps1)
    fn wlog(&mut self, text: &str);
    /// chatqd.log
    fn dlog(&mut self, text: &str);
}

/// The host of a real run: the files under the tool's root, the clock and
/// real steps.
pub struct Live<'a> {
    ctx: &'a Ctx,
    awake: KeepAwake,
    poller: reply::Poller,
}

impl<'a> Live<'a> {
    pub fn new(ctx: &'a Ctx) -> Live<'a> {
        Live {
            ctx,
            awake: KeepAwake::default(),
            poller: reply::Poller::new(&ctx.seams),
        }
    }

    fn cfg_now(&self) -> Value {
        read_config(&self.ctx.p.config(), self.ctx.fl)
    }

    /// data/replies.json as [Read-ChatqBoardState](src/phone-down.ps1)
    /// reads it, for the poll's cadence and the listening line.
    fn replies_now(&self) -> Option<Value> {
        read_json(&self.ctx.p.replies(), self.ctx.fl)
    }
}

/// Deletes `path` when it is there, and says whether it was.
fn take(path: PathBuf) -> bool {
    if !path.exists() {
        return false;
    }
    let _ = fs::remove_file(path);
    true
}

impl Host for Live<'_> {
    fn now(&mut self) -> Instant {
        Utc::now()
    }
    fn flavour(&self) -> Flavour {
        self.ctx.fl
    }
    fn panic_seam(&self) -> bool {
        self.ctx.seams.panic
    }
    fn take_stop(&mut self) -> bool {
        take(self.ctx.p.stop())
    }
    fn stop_waiting(&mut self) -> bool {
        self.ctx.p.stop().exists()
    }
    fn take_restart(&mut self) -> bool {
        take(self.ctx.p.restart())
    }
    fn wake_mtime(&mut self) -> Option<SystemTime> {
        mtime(&self.ctx.p.wake())
    }
    fn wake_word(&mut self) -> String {
        fs::read_to_string(self.ctx.p.wake())
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    }
    fn wake_seen(&mut self) {
        let _ = fs::create_dir_all(&self.ctx.p.data);
        let _ = write_ascii_line(&self.ctx.p.wake(), "seen");
    }
    fn jobs(&mut self) -> Vec<Value> {
        get_jobs(&self.ctx.p.queue_dir(), self.ctx.fl, Zone::Local)
    }
    fn job_files(&mut self, id: &str) -> Vec<String> {
        jobs::files_with_id(&self.ctx.p.queue_dir(), id, self.ctx.fl)
    }
    fn usage_soon(
        &mut self,
        blocked: &[BlockedLane],
        queued: &[Value],
        sent: &[String],
        now: Instant,
    ) -> UsageSoon {
        let cfg = self.cfg_now();
        gates::usage_soon(&cfg, blocked, queued, sent, now, self.ctx.fl, Zone::Local)
    }
    fn reply_open(&mut self) -> bool {
        let p = &self.ctx.p;
        gates::reply_open(&self.cfg_now(), &p.replies(), Utc::now(), self.ctx.fl)
    }
    fn poll_seconds(&mut self) -> u32 {
        let st = self.replies_now();
        gates::reply_poll_seconds(st.as_ref(), false, Utc::now(), self.ctx.fl, Zone::Local)
    }
    fn poll(&mut self, w: &mut WatchState, min_seconds: u32) -> u32 {
        let ctx = self.ctx;
        let mut step = |op: &str, w: &WatchState, args: Value| step::run(ctx, op, None, w, args);
        self.poller.poll(ctx, w, min_seconds, Utc::now(), &mut step)
    }
    fn poll_forbidden(&mut self) -> bool {
        self.poller.forbidden()
    }
    fn listen_text(&mut self) -> String {
        let st = self.replies_now();
        let (fl, culture) = (self.ctx.fl, &self.ctx.culture);
        gates::listen_text(st.as_ref(), Utc::now(), fl, Zone::Local, culture)
    }
    fn board_step(&mut self, w: &mut WatchState) {
        let ctx = self.ctx;
        let mut step = |op: &str, w: &WatchState, args: Value| step::run(ctx, op, None, w, args);
        self.poller.board(ctx, w, Utc::now(), &mut step);
    }
    fn repair_due(&mut self) -> bool {
        let p = &self.ctx.p;
        gates::repair_due(&read_jobs(&p.queue_dir(), self.ctx.fl), p)
    }
    fn held_due(&mut self, tried_at: Option<Instant>) -> bool {
        let cfg = self.cfg_now();
        let now = Utc::now();
        // the clock seam moves quiet hours only, as Get-ChatqNow does
        let quiet_at = self.ctx.seams.clock.unwrap_or(now);
        let (p, sys_now) = (&self.ctx.p, SystemTime::now());
        gates::held_summary_due_quiet(p, &cfg, tried_at, sys_now, now, quiet_at, Zone::Local)
    }
    fn auto_wanted(&mut self) -> bool {
        let state = read_json(&self.ctx.p.auto_state(), self.ctx.fl);
        gates::auto_wanted(&self.cfg_now(), state.as_ref())
    }
    fn stray_maybe(&mut self) -> bool {
        gates::stray_maybe(&self.ctx.p.queue_dir(), SystemTime::now())
    }
    fn usage_alerts(&mut self) -> Option<Value> {
        // Get-ChatqUsageAlertState reads it once: no retry, as fsx's has
        let path = paths::join(&self.ctx.p.data, "usage-alerts.json");
        let bytes = fs::read(path).ok()?;
        parse_tolerant_in(&bytes, self.ctx.fl).value
    }
    fn clear_defer(&mut self, id: &str) -> io::Result<Written> {
        jobs::clear_defer(&self.ctx.p, id, self.ctx.fl)
    }
    fn fail_job(&mut self, id: &str, reason: &str) -> io::Result<Written> {
        jobs::fail_job(&self.ctx.p, id, reason, self.ctx.fl, Utc::now())
    }
    fn step(&mut self, op: &str, alert_job: Option<&str>, w: &WatchState, args: Value) -> Outcome {
        step::run(self.ctx, op, alert_job, w, args)
    }
    fn awake(&mut self, on: bool) {
        self.awake.set(on);
    }
    fn save_state(&mut self, w: &WatchState) {
        save_state(self.ctx, w);
    }
    fn board(&mut self) {
        // Write-ChatqBoard's catch writes no board where its text throws
        let (p, fl, now) = (&self.ctx.p, self.ctx.fl, Utc::now());
        let jobs = get_jobs(&p.queue_dir(), fl, Zone::Local);
        let blocks = board::blocks(read_json(&p.state(), fl).as_ref(), now, fl, Zone::Local);
        let text = board::text(
            &p.queue,
            &jobs,
            &blocks,
            now,
            fl,
            Zone::Local,
            &self.ctx.culture,
        );
        if let Some(t) = text {
            let _ = save_text(&p.board(), &t);
        }
    }
    fn wait(&mut self, until: Instant) {
        wait_until(&self.ctx.p, until);
    }
    fn wlog(&mut self, text: &str) {
        self.ctx.wlog(text);
    }
    fn dlog(&mut self, text: &str) {
        self.ctx.dlog(text);
    }
}

/// Start-up's own writes, before the loop: the pid, a stale stop gone, the
/// `started` line, and the restore of a handed-over state.
pub fn start(ctx: &Ctx, w: &mut WatchState) {
    let p = &ctx.p;
    let _ = write_ascii_line(&p.pid(), &ctx.pid.to_string());
    if p.stop().exists() {
        let _ = fs::remove_file(p.stop());
    }
    ctx.wlog(&format!("watcher {} started ({VERSION})", ctx.pid));
    if w.restore(read_json(&p.state(), ctx.fl).as_ref(), Utc::now(), ctx.fl) {
        ctx.wlog("carrying on from the watcher before it");
    }
}

/// After `queue empty`: a shell that sent an answerable alert as this
/// watcher left saw it alive and started none, so one is to be started.
/// Never over a stop.
pub fn listen_after_empty(h: &mut dyn Host) -> bool {
    if h.stop_waiting() || !h.reply_open() {
        return false;
    }
    h.wlog("a phone alert went out as this watcher left - starting another to listen");
    true
}

/// `$j.<name>` as a string puts it.
fn text_of(job: &Value, name: &str) -> String {
    json::to_ps_string(json::get(Some(job), name))
}

/// SPEC 2.2: a job file chatqd does not write itself.
fn by_step_line(id: &str) -> String {
    format!("{id}.json reads repaired, lossy or as a list - a job-write step writes it")
}

/// Takes a good answer's `W` whole (SPEC 3.6); keeps its own otherwise.
fn take_w(w: &mut WatchState, o: Outcome) -> Option<serde_json::Map<String, Value>> {
    match o {
        Outcome::Ok(next, result) => {
            *w = *next;
            Some(result)
        }
        _ => None,
    }
}

pub fn run(h: &mut dyn Host, w: &mut WatchState) -> Exit {
    let fl = h.flavour();
    if h.repair_due() {
        let o = h.step("repair", None, w, json!({}));
        take_w(w, o);
    }
    let mut first = true;
    let mut wake_seen: Option<SystemTime> = None;
    let mut t = Timers::new();
    // the ids a job not found by its own id has been named under
    let mut lost_said: HashSet<String> = HashSet::new();
    // PowerShell's $replyWasOpen and $listening: the loop's own, so false
    // after a restore too
    let mut reply_was_open = false;
    let mut listening = false;
    loop {
        if h.take_stop() {
            h.wlog("stop requested");
            return Exit::Stopped;
        }
        if h.take_restart() {
            h.wlog("a newer copy was installed - handing over");
            w.handoff = true;
            return Exit::Restart;
        }
        if first && h.panic_seam() {
            panic!("the panic seam");
        }
        first = false;
        let now = h.now();
        wake(h, w, &mut wake_seen, now);

        if h.held_due(w.summary_tried_at()) {
            let o = h.step("held", None, w, json!({}));
            // a failed try waits as Send-ChatqHeldSummary's own does
            if take_w(w, o).is_none() && h.held_due(w.summary_tried_at()) {
                let at = h.now();
                w.set_summary_tried_at(at);
            }
        }
        // the phone's replies, while an alert that can be answered is out
        // or listening stands: at most every poll_every, however often the
        // loop comes round
        let reply_open = h.reply_open();
        if reply_was_open && !reply_open {
            h.wlog("replies closed");
        }
        reply_was_open = reply_open;
        let poll_every = if reply_open {
            h.poll_seconds()
        } else {
            timers::CLOSED_POLL_SECONDS
        };
        let polled = if reply_open { h.poll(w, poll_every) } else { 0 };
        // the system lets PowerShell out but not chatqd (a firewall): the
        // PS watcher listens, W and the caches with it, as up to 0.10.20;
        // the next chatqd to start tries again
        if h.poll_forbidden() {
            w.handoff = true;
            return Exit::Handoff(Fail::Forbidden.text());
        }
        // old enough at the step's launch, as the function's own clock reads it
        let at = h.now();
        let landed: Vec<String> = w
            .ask_sent()
            .into_iter()
            .filter(|(_, sent)| sent.is_some_and(|s| timers::ask_landed_due(s, at)))
            .map(|(rid, _)| rid)
            .collect();
        if !landed.is_empty() {
            let o = h.step("ask-landed", None, w, json!({"quick": false}));
            if take_w(w, o).is_none() {
                for rid in &landed {
                    w.drop_ask_sent(rid);
                }
            }
        }
        // both timers move whether a step runs or not
        if t.auto_due(now) && h.auto_wanted() {
            let o = h.step("auto", None, w, json!({}));
            take_w(w, o);
        }
        if t.stray_due(now) && h.stray_maybe() {
            let o = h.step("stray", None, w, json!({}));
            take_w(w, o);
        }

        let all = h.jobs();
        let queued: Vec<Value> = all
            .iter()
            .filter(|j| state_in(j, &["queued"]))
            .cloned()
            .collect();
        if queued.is_empty() && reply_open {
            // Nothing to run, only listening: the machine may sleep, and
            // the board and the state are written on the way in and when a
            // reply did something, not every poll.
            if !listening || polled > 0 {
                h.awake(false);
                w.current = None;
                w.next = None;
                w.listening = true;
                h.save_state(w);
                h.board_step(w);
            }
            if !listening {
                listening = true;
                let text = h.listen_text();
                h.wlog(&format!("listening for phone replies {text}"));
            }
            // after a poll that acted, the next pass's MinSeconds waits
            if polled == 0 {
                let at = h.now();
                h.wait(at + TimeDelta::seconds(i64::from(poll_every)));
            }
            continue;
        }
        listening = false;
        w.listening = false;
        if queued.is_empty() {
            // Tidy up first and look once more last thing: a job queued
            // while this one is on its way out gets only a poke.
            h.awake(false);
            w.current = None;
            w.next = None;
            h.save_state(w);
            h.board();
            if any_queued(&h.jobs()) {
                continue;
            }
            // the same for an alert a shell sent meanwhile
            if h.reply_open() {
                continue;
            }
            h.wlog("queue empty");
            return Exit::Empty;
        }

        let now = h.now();
        let mut next_at = timers::default_next_at(now);
        let mut pick = None;
        for j in &queued {
            if !found_by_id(&all, j) {
                lost(h, &mut lost_said, j);
                continue;
            }
            let ln = lane(j);
            if gates::rescan_due(w.scanned_at.date(&ln), now, false) {
                let o = h.step("block", None, w, json!({"jobIds": [text_of(j, "id")]}));
                if take_w(w, o).is_none() {
                    // as Update-ChatqBlock stamps after its scan
                    let at = h.now();
                    w.scanned_at.set(&ln, stamp_utc(at).into());
                }
            }
            let until = w
                .blocked
                .iter()
                .find(|(k, _)| ieq(k, &ln))
                .map(|(_, b)| b.until);
            let check = w
                .outage
                .iter()
                .find(|(k, _)| ieq(k, &ln))
                .map(|(_, o)| o.next_check);
            match gates::due_time(until, check, j, now, fl, Zone::Local) {
                Some(due) => next_at = next_at.min(due),
                None => {
                    pick = Some(j);
                    break;
                }
            }
        }
        if let Some(j) = pick {
            h.awake(true);
            let (id, seq) = (text_of(j, "id"), text_of(j, "seq"));
            let alert_job = format!("#{seq}");
            let o = h.step("pick", Some(&alert_job), w, json!({"jobId": id}));
            if let Some(why) = o.reason() {
                pick_failed(h, w, &id, &seq, &why);
            } else {
                take_w(w, o);
            }
            // round again at once, with no wait
            h.save_state(w);
            h.board();
            continue;
        }

        next_at = soon(h, w, &queued, now, next_at);
        h.awake(timers::keep_awake(now, next_at));
        w.next = Some(stamp_utc(next_at));
        // listening shortens the wait, which must not rewrite the board
        // any more often than before; both by the clock as it is now
        let at = h.now();
        if t.board_due(at, reply_open, polled > 0) {
            h.save_state(w);
            h.board();
        }
        h.wait(timers::wake_at(next_at, at, reply_open, poll_every));
    }
}

/// A queued job its own id does not find ([found_by_id]), passed over
/// without a step, as the PS loop passes it over: watcher.log names its
/// file(s) the first time its id is met. Nothing is written to them: with
/// the id shared, a write by id could land in its twin's file.
fn lost(h: &mut dyn Host, said: &mut HashSet<String>, j: &Value) {
    let id = text_of(j, "id");
    if !said.insert(id.clone()) {
        return;
    }
    let files = h.job_files(&id).join(", ");
    h.wlog(&format!(
        "{files}: the id '{id}' does not find one job - left queued, not run, until that is put right"
    ));
}

/// `chatqrun -Now`: forget every wait and ask again, as the loop does on a
/// fresh `now` in data/wake.
fn wake(h: &mut dyn Host, w: &mut WatchState, seen: &mut Option<SystemTime>, now: Instant) {
    let Some(m) = h.wake_mtime() else {
        return;
    };
    if Some(m) == *seen {
        return;
    }
    *seen = Some(m);
    // a wake dated in the future counts as fresh, as in PS
    let fresh = now - DateTime::<Utc>::from(m) < NOW_FRESH;
    if !(ieq(&h.wake_word(), "now") && fresh) {
        return;
    }
    h.wake_seen();
    w.clear_for_wake();
    let jobs = h.jobs();
    for j in jobs.iter().filter(|j| state_in(j, &["queued"])) {
        w.scanned_at.set(&lane(j), stamp_utc(now).into());
        if !json::truthy(json::get(Some(j), "deferUntil")) {
            continue;
        }
        let id = text_of(j, "id");
        match h.clear_defer(&id) {
            Ok(Written::Step(_)) => {
                h.dlog(&by_step_line(&id));
                let args = json!({"jobId": id, "set": {"deferUntil": null}});
                let o = h.step("job-write", None, w, args);
                take_w(w, o);
            }
            Ok(_) => {}
            Err(e) => h.dlog(&format!("{id}.json: deferUntil not cleared ({e})")),
        }
    }
    h.wlog("woken: -Now");
}

/// SPEC 2.4: a pick step that did not answer well. PS's own catch did not
/// run, so its nearest: the line, the job failed while still open, and only
/// then its `failed` alert.
fn pick_failed(h: &mut dyn Host, w: &mut WatchState, id: &str, seq: &str, reason: &str) {
    h.wlog(&format!("#{seq} error: helper step {reason}"));
    w.current = None;
    let job = match h.fail_job(id, reason) {
        Ok(Written::Saved(job)) => job,
        Ok(Written::Left) => return,
        Ok(Written::Step(job)) => {
            h.dlog(&by_step_line(id));
            let args = json!({"jobId": id, "complete": jobs::fail_complete(reason)});
            let o = h.step("job-write", None, w, args);
            match take_w(w, o) {
                Some(r) if json::truthy(r.get("saved")) => job,
                _ => return,
            }
        }
        Err(e) => {
            h.dlog(&format!("#{seq} could not be failed: {e}"));
            return;
        }
    };
    let text = format!(
        "{} {DOT} chatq error: helper step {reason}",
        text_of(&job, "title")
    );
    let args = json!({
        "event": "failed", "text": text, "priority": 2, "jobId": id,
        "loud": false, "quick": false, "noReply": false, "usageKind": null,
    });
    let o = h.step("alert", Some(&format!("#{seq}")), w, args);
    if let Some(why) = o.reason() {
        h.dlog(&format!(
            "the failed alert for #{seq} did not go: helper step {why}"
        ));
    } else {
        take_w(w, o);
    }
}

/// [Send-ChatqUsageSoon](src/phone-extras.ps1)'s pre-gate (SPEC 3.6): the
/// wait shortened for an alert still to come, a due key data/usage-alerts.json
/// already has recorded natively, and a `soon` step for any other.
fn soon(
    h: &mut dyn Host,
    w: &mut WatchState,
    queued: &[Value],
    now: Instant,
    mut next_at: Instant,
) -> Instant {
    let fl = h.flavour();
    let kinds: Vec<String> = w
        .blocked
        .iter()
        .map(|(_, b)| json::to_ps_string(Some(&b.kind)))
        .collect();
    let blocked: Vec<BlockedLane> = w
        .blocked
        .iter()
        .zip(&kinds)
        .map(|((k, b), kind)| BlockedLane {
            lane: k,
            until: b.until,
            kind,
            at: b.at,
        })
        .collect();
    let gate = h.usage_soon(&blocked, queued, &w.usage_sent(), now);
    if let Some(n) = gate.next {
        next_at = next_at.min(n);
    }
    if gate.due.is_empty() {
        return next_at;
    }
    let file = h.usage_alerts();
    let mut left = false;
    for key in &gate.due {
        if gates::soon_already_sent(file.as_ref(), key, fl) {
            w.add_usage_sent(key);
        } else {
            left = true;
        }
    }
    if left {
        let o = h.step("soon", None, w, json!({}));
        let soon_at = take_w(w, o)
            .and_then(|r| r.get("soonAt").and_then(Value::as_str).map(str::to_string))
            .and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
            .map(|d| d.with_timezone(&Utc));
        if let Some(s) = soon_at {
            next_at = next_at.min(s);
        }
    }
    next_at
}

// beside the loop, not in tests/: Host is the bin's own
#[cfg(test)]
#[path = "timers_replay.rs"]
mod timers_replay;
