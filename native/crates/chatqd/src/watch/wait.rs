//! [Wait-ChatqUntil](src/watcher.ps1): wall-clock, in short steps, so a
//! machine that slept wakes up past the time and goes straight on, and
//! `stop` or a new `wake` cut it short.

use chatq_core::paths::Paths;
use chatq_core::time::Instant;
use chrono::Utc;
use std::path::Path;
use std::thread::sleep;
use std::time::{Duration, SystemTime};

/// One step of the wait.
const STEP: Duration = Duration::from_secs(2);
/// Longest single wait; the loop comes round again after it.
const MAX_SECS: f64 = 30.0;

/// `LastWriteTimeUtc`, or None when the file is not there.
pub fn mtime(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// `min(30, max(1, secs to when))` seconds, ending on `stop` or a change to
/// `wake`'s mtime.
pub fn wait_until(p: &Paths, when: Instant) {
    let wake = mtime(&p.wake());
    let secs = (when - Utc::now()).num_milliseconds() as f64 / 1000.0;
    let end = secs.clamp(1.0, MAX_SECS);
    let t0 = Utc::now();
    while ((Utc::now() - t0).num_milliseconds() as f64 / 1000.0) < end {
        sleep(STEP);
        if p.stop().exists() || mtime(&p.wake()) != wake {
            return;
        }
    }
}
