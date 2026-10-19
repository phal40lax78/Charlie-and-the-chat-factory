//! Which of the loop's timers fire on a pass, on a fixed clock, as
//! [Invoke-ChatqWatchLoop](src/watcher.ps1) runs them (SPEC 1.1, 2.10).
//! The loop is native from M2; the rules are pinned now. Vector:
//! native/vectors/timers.json.
//!
//! A pass asks each timer once, in the loop's own order, and a timer that
//! says yes has been stamped: asking twice runs it twice. The lane rescan
//! is [crate::gates::rescan_due], which the loop keeps per lane in
//! `$W.scannedAt`, not here.

use crate::time::Instant;
use chrono::TimeDelta;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): auto-continue's scan, on the
/// first pass and then this far apart (`TotalMinutes -ge 5`).
pub const AUTO_SCAN_MINUTES: i64 = 5;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): the stray sweep
/// ([Clear-ChatqStrayFiles](src/queue.ps1)), on the first pass and then this
/// far apart (`TotalHours -ge 6`).
pub const STRAY_SWEEP_HOURS: i64 = 6;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): while the reply window is open
/// the wait is short, so the board and the state are written at most this
/// often, not once a wait.
pub const BOARD_SECONDS: i64 = 30;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1)'s `$pollEvery` with the window
/// shut. Nothing reads it: both its readers run only while the window is
/// open ([poll_every]).
pub const CLOSED_POLL_SECONDS: u32 = 15;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): how long the loop waits with
/// nothing sooner to wake for (`$now.AddMinutes(15)`).
pub const DEFAULT_WAIT_MINUTES: i64 = 15;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): the machine is held awake only
/// for a wait no longer than this (`($nextAt - $now).TotalHours -le 6`).
pub const KEEP_AWAKE_HOURS: i64 = 6;

/// [Test-ChatqAskLanded](src/ask.ps1): an answer sent to a chat is looked
/// for in its transcript once it is this old (`$age -lt 20` waits).
pub const ASK_LANDED_SECONDS: i64 = 20;

/// The `$onTick` of [Invoke-ChatqJob](src/watcher.ps1): while a job runs,
/// the state is saved this often (`$beat.At`).
pub const HEARTBEAT_SECONDS: i64 = 60;

/// The `$onTick` of [Invoke-ChatqJob](src/watcher.ps1): the reply poll while
/// a permission request is open, in place of
/// [crate::gates::RUN_POLL_SECONDS].
pub const RUN_ASKING_POLL_SECONDS: u32 = 5;

/// [Wait-ChatqUntil](src/watcher.ps1): one sleep of a wait, so a stop or a
/// wake is seen this soon.
pub const WAIT_STEP_SECONDS: i64 = 2;

/// [Wait-ChatqUntil](src/watcher.ps1): the longest one wait lasts, however
/// far off the time it was given. The loop comes round again and waits on.
pub const WAIT_MAX_SECONDS: i64 = 30;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): tries at the data/watch.lock
/// before giving up, a watcher handing over being let go of as it exits.
pub const LOCK_TRIES: u32 = 5;

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): the wait between those tries.
pub const LOCK_WAIT_MILLIS: u64 = 200;

/// The timers [Invoke-ChatqWatchLoop](src/watcher.ps1) keeps across its
/// passes: `$autoAt`, `$strayAt` and `$boardAt`. Each starts at
/// `[datetime]::MinValue`, None here, so each is due on the first pass.
#[derive(Clone, Debug, Default)]
pub struct Timers {
    auto_at: Option<Instant>,
    stray_at: Option<Instant>,
    board_at: Option<Instant>,
}

/// Is `at` due, and stamp it when it is: a timer the loop keeps as "when it
/// last ran", never run being due.
fn fire(at: &mut Option<Instant>, now: Instant, every: TimeDelta) -> bool {
    let due = at.is_none_or(|t| now - t >= every);
    if due {
        *at = Some(now);
    }
    due
}

impl Timers {
    /// A loop that has not run a pass yet.
    pub fn new() -> Timers {
        Timers::default()
    }

    /// Does this pass run auto-continue's scan
    /// ([Invoke-ChatqWatchAutoScan](src/watcher.ps1))? Every
    /// [AUTO_SCAN_MINUTES], the first pass included.
    pub fn auto_due(&mut self, now: Instant) -> bool {
        fire(
            &mut self.auto_at,
            now,
            TimeDelta::minutes(AUTO_SCAN_MINUTES),
        )
    }

    /// Does this pass sweep the stray files
    /// ([Clear-ChatqStrayFiles](src/queue.ps1))? Every [STRAY_SWEEP_HOURS],
    /// the first pass included.
    pub fn stray_due(&mut self, now: Instant) -> bool {
        fire(&mut self.stray_at, now, TimeDelta::hours(STRAY_SWEEP_HOURS))
    }

    /// Does this pass write the state and the board? With the window shut
    /// every pass does, since the loop then waits minutes; while it is open
    /// the pass that a poll did something on, and otherwise one pass every
    /// [BOARD_SECONDS]. Only the branch that waits asks: the one that
    /// listens, the one that empties the queue and the one that ran a job
    /// each write them whatever this says.
    pub fn board_due(&mut self, now: Instant, reply_open: bool, polled: bool) -> bool {
        if !reply_open || polled {
            self.board_at = Some(now);
            return true;
        }
        fire(&mut self.board_at, now, TimeDelta::seconds(BOARD_SECONDS))
    }
}

/// [Invoke-ChatqWatchLoop](src/watcher.ps1)'s `$pollEvery`:
/// [crate::gates::reply_poll_seconds] while the reply window is open, else
/// [CLOSED_POLL_SECONDS].
pub fn poll_every(reply_open: bool, open_seconds: u32) -> u32 {
    if reply_open {
        open_seconds
    } else {
        CLOSED_POLL_SECONDS
    }
}

/// [Invoke-ChatqWatchLoop](src/watcher.ps1)'s `$nextAt` before any job's due
/// time, any usage alert or any poll shortens it.
pub fn default_next_at(now: Instant) -> Instant {
    now + TimeDelta::minutes(DEFAULT_WAIT_MINUTES)
}

/// [Invoke-ChatqWatchLoop](src/watcher.ps1): is a wait until `next_at` worth
/// holding the machine awake for ([KEEP_AWAKE_HOURS])? A weekly limit days
/// out is not.
pub fn keep_awake(now: Instant, next_at: Instant) -> bool {
    next_at - now <= TimeDelta::hours(KEEP_AWAKE_HOURS)
}

/// [Invoke-ChatqWatchLoop](src/watcher.ps1)'s `$wakeAt`: `next_at`, but no
/// further off than the next poll while the reply window is open.
pub fn wake_at(next_at: Instant, now: Instant, reply_open: bool, poll_every: u32) -> Instant {
    let cap = now + TimeDelta::seconds(i64::from(poll_every));
    if reply_open && next_at > cap {
        cap
    } else {
        next_at
    }
}

/// [Test-ChatqAskLanded](src/ask.ps1): is an answer sent at `sent_at` old
/// enough to look for ([ASK_LANDED_SECONDS])? Younger ones are left for a
/// later pass.
pub fn ask_landed_due(sent_at: Instant, now: Instant) -> bool {
    now - sent_at >= TimeDelta::seconds(ASK_LANDED_SECONDS)
}

/// The `$onTick` of [Invoke-ChatqJob](src/watcher.ps1): is the running job's
/// state due to be saved again ([HEARTBEAT_SECONDS])?
pub fn heartbeat_due(saved_at: Instant, now: Instant) -> bool {
    now - saved_at >= TimeDelta::seconds(HEARTBEAT_SECONDS)
}

/// [Wait-ChatqUntil](src/watcher.ps1): how long one call sleeps for, in
/// [WAIT_STEP_SECONDS] steps - a second at the least, [WAIT_MAX_SECONDS] at
/// the most, however far off `when` is. A wait cut short by a stop or a
/// wake is not this.
pub fn wait_slice(when: Instant, now: Instant) -> TimeDelta {
    (when - now).clamp(TimeDelta::seconds(1), TimeDelta::seconds(WAIT_MAX_SECONDS))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::Flavour;
    use crate::time::parse_stamp;

    fn at(s: &str) -> Instant {
        parse_stamp(s, Flavour::Core).expect("a stamp")
    }

    #[test]
    fn a_timer_fires_then_waits_its_turn() {
        let mut t = Timers::new();
        assert!(t.auto_due(at("2026-10-15T09:00:00Z")));
        assert!(!t.auto_due(at("2026-10-15T09:04:59Z")));
        assert!(t.auto_due(at("2026-10-15T09:05:00Z")));
        assert!(t.stray_due(at("2026-10-15T09:05:00Z")));
        assert!(!t.stray_due(at("2026-10-15T14:00:00Z")));
        assert!(t.stray_due(at("2026-10-15T15:05:00Z")));
    }

    #[test]
    fn the_board_waits_only_while_the_window_is_open() {
        let mut t = Timers::new();
        assert!(t.board_due(at("2026-10-15T09:00:00Z"), true, false));
        assert!(!t.board_due(at("2026-10-15T09:00:20Z"), true, false));
        // a poll that did something, then the window shut: both write
        assert!(t.board_due(at("2026-10-15T09:00:25Z"), true, true));
        assert!(t.board_due(at("2026-10-15T09:00:30Z"), false, false));
    }

    #[test]
    fn a_wait_is_capped_and_sliced() {
        let now = at("2026-10-15T09:00:00Z");
        let next = default_next_at(now);
        assert_eq!(wake_at(next, now, false, 20), next);
        assert_eq!(wake_at(next, now, true, 20), now + TimeDelta::seconds(20));
        assert_eq!(wait_slice(next, now), TimeDelta::seconds(WAIT_MAX_SECONDS));
        assert_eq!(wait_slice(now, now), TimeDelta::seconds(1));
        assert!(keep_awake(now, next));
        assert!(!keep_awake(now, now + TimeDelta::hours(7)));
    }
}
