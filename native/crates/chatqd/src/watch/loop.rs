//! [Invoke-ChatqWatchLoop](src/watcher.ps1), as far as M0 goes (SPEC 7 M0):
//! start-up's own writes, then passes that each hand over to the PS watcher
//! or end the watcher. Only the `hold` seam ever waits.

use super::wait::{mtime, wait_until};
use super::{Ctx, KeepAwake, save_state};
use crate::VERSION;
use chatq_core::board;
use chatq_core::config::read_config;
use chatq_core::fsx::{read_json, save_text, write_ascii_line};
use chatq_core::gates;
use chatq_core::jobs::{any_queued, read_jobs};
use chatq_core::json::ieq;
use chatq_core::state::WatchState;
use chatq_core::time::{Instant, stamp_utc};
use chrono::{Duration, Local, Utc};
use std::fs;
use std::time::SystemTime;

/// How the loop ended, and so what last.json says and what comes after.
pub enum Exit {
    Stopped,
    Empty,
    Restart,
    /// a duty M0 cannot do yet, or a panic: the PS watcher takes over
    Handoff(String),
}

/// A `-Now` is a request of the moment: older than this it is ignored.
const NOW_FRESH: std::time::Duration = std::time::Duration::from_secs(5 * 60);
/// Keep the machine awake only for a wait this short or shorter.
const AWAKE_HOURS: i64 = 6;
/// Auto-continue's scan and the stray sweep: at start, then this often.
const AUTO_EVERY_MIN: i64 = 5;
const STRAY_EVERY_HOURS: i64 = 6;

/// The first-pass timers, `[datetime]::MinValue` until they first run.
#[derive(Default)]
struct Timers {
    auto_at: Option<Instant>,
    stray_at: Option<Instant>,
}

fn due(at: &mut Option<Instant>, every: Duration, now: Instant) -> bool {
    if at.is_some_and(|t| now - t < every) {
        return false;
    }
    *at = Some(now);
    true
}

/// Would the PS pass do anything M0 cannot? Each answer names why, for
/// chatqd.log. Read once a pass, from the files as they are now.
fn handoff_reason(ctx: &Ctx, w: &WatchState, first: bool, t: &mut Timers) -> Option<&'static str> {
    let p = &ctx.p;
    let now = Utc::now();
    let sys_now = SystemTime::now();
    let jobs = read_jobs(&p.queue_dir(), ctx.fl);
    if first && gates::repair_due(&jobs, p) {
        return Some("the watcher before it left something to repair");
    }
    if any_queued(&jobs) {
        return Some("a job is queued");
    }
    let cfg = read_config(&p.config(), ctx.fl);
    if gates::reply_open(&cfg, &p.replies(), now, ctx.fl) {
        return Some("the phone reply window is open");
    }
    if gates::held_waiting(p, sys_now) {
        return Some("held alerts are waiting");
    }
    if due(&mut t.auto_at, Duration::minutes(AUTO_EVERY_MIN), now)
        && gates::auto_wanted(&cfg, read_json(&p.auto_state(), ctx.fl).as_ref())
    {
        return Some("auto-continue is on");
    }
    if due(&mut t.stray_at, Duration::hours(STRAY_EVERY_HOURS), now)
        && gates::stray_maybe(&p.queue_dir(), sys_now)
    {
        return Some("data/queue may hold stray files");
    }
    if !board::is_trivial(&jobs, w, now, ctx.fl) {
        return Some("the board shows more than an empty queue");
    }
    None
}

/// [Write-ChatqBoard](src/alerts.ps1), only ever the empty board here:
/// anything more was a handoff.
fn write_board(ctx: &Ctx) {
    let _ = save_text(
        &ctx.p.board(),
        &board::trivial_text(&ctx.culture, &Local::now()),
    );
}

pub fn run(ctx: &Ctx, w: &mut WatchState, awake: &mut KeepAwake) -> Exit {
    let p = &ctx.p;
    let _ = write_ascii_line(&p.pid(), &ctx.pid.to_string());
    if p.stop().exists() {
        let _ = fs::remove_file(p.stop());
    }
    ctx.wlog(&format!("watcher {} started ({VERSION})", ctx.pid));
    if w.restore(read_json(&p.state(), ctx.fl).as_ref(), Utc::now(), ctx.fl) {
        ctx.wlog("carrying on from the watcher before it");
    }
    let hold_end = ctx
        .seams
        .hold
        .map(|m| Utc::now() + Duration::milliseconds((m * 60_000.0) as i64));
    let mut first = true;
    let mut wake_seen: Option<SystemTime> = None;
    let mut timers = Timers::default();
    loop {
        if p.stop().exists() {
            let _ = fs::remove_file(p.stop());
            ctx.wlog("stop requested");
            return Exit::Stopped;
        }
        if p.restart().exists() {
            let _ = fs::remove_file(p.restart());
            ctx.wlog("a newer copy was installed - handing over");
            w.handoff = true;
            return Exit::Restart;
        }
        if first && ctx.seams.panic {
            panic!("the panic seam");
        }
        // before this pass writes anything (SPEC 7 M0); a fresh -Now is so
        // left for the PS watcher, which takes it with the job writes
        if let Some(why) = handoff_reason(ctx, w, first, &mut timers) {
            w.handoff = true;
            return Exit::Handoff(why.into());
        }
        first = false;

        if let Some(m) = mtime(&p.wake())
            && Some(m) != wake_seen
        {
            wake_seen = Some(m);
            let what = fs::read_to_string(p.wake())
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            // a wake dated in the future counts as fresh, as in PS
            let fresh = SystemTime::now()
                .duration_since(m)
                .map_or(true, |age| age < NOW_FRESH);
            if ieq(&what, "now") && fresh {
                if any_queued(&read_jobs(&p.queue_dir(), ctx.fl)) {
                    w.handoff = true;
                    return Exit::Handoff("a job is queued".into());
                }
                let _ = fs::create_dir_all(&p.data);
                let _ = write_ascii_line(&p.wake(), "seen");
                w.blocked.clear();
                w.outage.clear();
                ctx.wlog("woken: -Now");
            }
        }

        let now = Utc::now();
        if let Some(end) = hold_end
            && now < end
        {
            // the wait branch of the PS loop, with the seam's end as nextAt
            awake.set(end - now <= Duration::hours(AWAKE_HOURS));
            w.next = Some(stamp_utc(end));
            save_state(ctx, w);
            write_board(ctx);
            wait_until(p, end);
            continue;
        }

        // Tidy up first and look once more last thing: a job queued while
        // this one is on its way out gets only a poke.
        awake.set(false);
        w.current = None;
        w.next = None;
        save_state(ctx, w);
        write_board(ctx);
        if any_queued(&read_jobs(&p.queue_dir(), ctx.fl)) {
            continue;
        }
        // the same for an alert a shell sent meanwhile
        if gates::reply_open(
            &read_config(&p.config(), ctx.fl),
            &p.replies(),
            Utc::now(),
            ctx.fl,
        ) {
            continue;
        }
        ctx.wlog("queue empty");
        return Exit::Empty;
    }
}
