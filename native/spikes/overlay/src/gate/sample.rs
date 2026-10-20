// The gate's own memory and cost figures (m9-plan.md, "Memory method"):
// a read every 10 s, from a thread of its own, and every 60 s - the minute
// marks from the start - a logged sample of private bytes (the figure behind
// the WPF overlay's 271 MB), working set, GDI, USER, thread and handle
// counts, the process's cycle time and CPU since the last sample, and the
// snapshot's age. The summary (summary), from the sampler's own thread at
// minute 60's sample, or at the stop for a shorter run: the start peak, the
// per-minute series, the gate figure, the slope and the handle verdict.

use std::sync::{Arc, Mutex, OnceLock};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering::SeqCst};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::FILETIME;
use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX};
use windows::Win32::System::Threading::{GR_GDIOBJECTS, GR_USEROBJECTS, GetCurrentProcess, GetGuiResources, GetProcessHandleCount, GetProcessTimes};
use windows::Win32::System::WindowsProgramming::QueryProcessCycleTime;

use crate::selflog;

const MB: f64 = 1024.0 * 1024.0;

/// epoch ms of the snapshot on the panel ("at"), 0 for none yet.
pub static SNAP_AT: AtomicI64 = AtomicI64::new(0);

/// The sample whose minute ends the gate hour, and the summary with it.
const GATE_MINUTE: u32 = 60;

static START: OnceLock<Instant> = OnceLock::new();
/// The tray's first-use events (a balloon clicked, the menu opened) and the
/// minute of each: step 4 saw each cost GDI and USER objects once.
static TOUCHES: Mutex<Vec<(u32, &'static str)>> = Mutex::new(Vec::new());

/// A balloon click or a menu open, noted by gate/tray.rs for the handle
/// verdict: one after minute 5 can read as growth that is a first-use cost.
pub fn touched(what: &'static str) {
    let minute = START.get().map_or(0, |s| (s.elapsed().as_secs() / 60) as u32);
    if let Ok(mut t) = TOUCHES.lock() {
        t.push((minute, what));
    }
}

#[derive(Clone, Copy, Default)]
pub struct Sample {
    pub minute: u32,
    pub private_mb: f64,
    pub ws_mb: f64,
    pub gdi: u32,
    pub user: u32,
    pub threads: usize,
    pub handles: u32,
    pub cycles: u64,
    /// process CPU time (kernel + user), 100 ns
    pub cpu: u64,
    pub cpu_pct: f64,
    pub snap_age_s: i64,
}

#[derive(Default)]
pub struct Series {
    pub samples: Vec<Sample>,
    /// the highest private bytes read in the first 5 minutes (10 s reads)
    pub start_peak_mb: f64,
    pub seconds: f64,
}

fn read(minute: u32) -> Sample {
    let p = unsafe { GetCurrentProcess() };
    let mut mem = PROCESS_MEMORY_COUNTERS_EX { cb: size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32, ..Default::default() };
    unsafe { GetProcessMemoryInfo(p, &mut mem as *mut _ as *mut PROCESS_MEMORY_COUNTERS, mem.cb).unwrap() };
    let mut handles = 0;
    unsafe { GetProcessHandleCount(p, &mut handles).unwrap() };
    let mut cycles = 0;
    unsafe { QueryProcessCycleTime(p, &mut cycles).unwrap() };
    let (mut c, mut e, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    unsafe { GetProcessTimes(p, &mut c, &mut e, &mut k, &mut u).unwrap() };
    let ft = |t: FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
    let at = SNAP_AT.load(SeqCst);
    Sample {
        minute,
        private_mb: mem.PrivateUsage as f64 / MB,
        ws_mb: mem.WorkingSetSize as f64 / MB,
        gdi: unsafe { GetGuiResources(p, GR_GDIOBJECTS) },
        user: unsafe { GetGuiResources(p, GR_USEROBJECTS) },
        threads: selflog::thread_count(),
        handles,
        cycles,
        cpu: ft(k) + ft(u),
        cpu_pct: 0.0,
        snap_age_s: if at > 0 { (crate::gate::content::epoch_ms() - at) / 1000 } else { -1 },
    }
}

fn log(s: &Sample) {
    selflog::line(&format!(
        "gate sample m={} private={:.1}MB ws={:.1}MB gdi={} user={} threads={} handles={} cycles={} cpu={:.2}% snapshot_age={}",
        s.minute,
        s.private_mb,
        s.ws_mb,
        s.gdi,
        s.user,
        s.threads,
        s.handles,
        s.cycles,
        s.cpu_pct,
        if s.snap_age_s < 0 { "none".to_string() } else { format!("{}s", s.snap_age_s) }
    ));
}

/// The sampler: minute 0 at once, then a read every 10 s and a sample at
/// each minute mark, until `stop`. The summary is logged from this thread:
/// at minute 60's sample, or at the stop for a shorter run.
pub fn spawn(stop: Arc<AtomicBool>) -> std::thread::JoinHandle<Series> {
    std::thread::Builder::new()
        .name("gate-sample".into())
        .spawn(move || {
            let _ = START.set(Instant::now());
            let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
            let start = Instant::now();
            let mut series = Series::default();
            let first = read(0);
            log(&first);
            series.start_peak_mb = first.private_mb;
            series.samples.push(first);
            let (mut last_cpu, mut last_at) = (first.cpu, Instant::now());
            let mut ticks = 0u64;
            let mut summarised = false;
            while !stop.load(SeqCst) {
                // 10 s in short sleeps, so the stop is quick
                let due = start + Duration::from_secs(10 * (ticks + 1));
                while Instant::now() < due && !stop.load(SeqCst) {
                    std::thread::sleep(Duration::from_millis(200));
                }
                if stop.load(SeqCst) {
                    break;
                }
                ticks += 1;
                let mut s = read((ticks / 6) as u32);
                if ticks <= 30 {
                    series.start_peak_mb = series.start_peak_mb.max(s.private_mb);
                }
                if ticks % 6 == 0 {
                    let wall = last_at.elapsed().as_secs_f64();
                    s.cpu_pct = (s.cpu - last_cpu) as f64 / 1e7 / wall / cpus * 100.0;
                    (last_cpu, last_at) = (s.cpu, Instant::now());
                    log(&s);
                    series.samples.push(s);
                    // the hour's figure from here, the moment it is in: the
                    // close after it runs on Slint timers, which the tray
                    // menu's modal loop stops, and the watchdog would end
                    // the process before any summary at exit
                    if s.minute == GATE_MINUTE && !summarised {
                        summarised = true;
                        series.seconds = start.elapsed().as_secs_f64();
                        summary(&series);
                    }
                }
            }
            if !summarised {
                series.seconds = start.elapsed().as_secs_f64();
                summary(&series);
            }
            series
        })
        .unwrap()
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

/// Least squares slope of private MB over minutes, as MB per hour.
fn slope(points: &[&Sample]) -> Option<f64> {
    let n = points.len() as f64;
    if points.len() < 3 {
        return None;
    }
    let mx = points.iter().map(|s| f64::from(s.minute)).sum::<f64>() / n;
    let my = points.iter().map(|s| s.private_mb).sum::<f64>() / n;
    let sxy: f64 = points.iter().map(|s| (f64::from(s.minute) - mx) * (s.private_mb - my)).sum();
    let sxx: f64 = points.iter().map(|s| (f64::from(s.minute) - mx).powi(2)).sum();
    (sxx > 0.0).then(|| sxy / sxx * 60.0)
}

/// The run's summary lines, from the samples.
pub fn summary(series: &Series) {
    let s = &series.samples;
    let last = s.last().map_or(0, |x| x.minute);
    selflog::line(&format!("gate summary: {:.0} s, {} samples, last minute {last}", series.seconds, s.len()));
    selflog::line(&format!("gate summary start peak (max private, first 5 min, 10 s reads): {:.1}MB", series.start_peak_mb));
    let mem: Vec<String> = s.iter().map(|x| format!("{}:{:.1}", x.minute, x.private_mb)).collect();
    selflog::line(&format!("gate summary private MB per minute: {}", mem.join(" ")));
    let gate: Vec<&Sample> = s.iter().filter(|x| (45..=60).contains(&x.minute)).collect();
    if last >= 60 && !gate.is_empty() {
        let max = gate.iter().map(|x| x.private_mb).fold(f64::MIN, f64::max);
        let med = median(gate.iter().map(|x| x.private_mb).collect());
        selflog::line(&format!("gate summary GATE FIGURE (highest sample, minutes 45-60): {max:.1}MB; median {med:.1}MB; {} samples", gate.len()));
    } else {
        selflog::line(&format!("gate summary GATE FIGURE: n/a (the run ended at minute {last}; needs minute 60)"));
    }
    let late: Vec<&Sample> = s.iter().filter(|x| (30..=60).contains(&x.minute)).collect();
    match (last >= 60).then(|| slope(&late)).flatten() {
        Some(m) => selflog::line(&format!("gate summary slope minutes 30-60: {m:+.2} MB/h{}", if m > 2.0 { " (over 2 MB/h: an 8-hour run before any go)" } else { "" })),
        None => selflog::line("gate summary slope minutes 30-60: n/a (needs minute 60)"),
    }
    // from minute 1: minute 0 is read before any window exists
    let all: Vec<&Sample> = s.iter().filter(|x| x.minute >= 1).collect();
    if let Some(m) = slope(&all) {
        selflog::line(&format!("gate summary slope from minute 1 (for information): {m:+.2} MB/h"));
    }
    let handles: Vec<String> = s.iter().map(|x| format!("{}:g{}/u{}/h{}/t{}", x.minute, x.gdi, x.user, x.handles, x.threads)).collect();
    selflog::line(&format!("gate summary handles per minute: {}", handles.join(" ")));
    // Against minute 5 (past the first-use costs seen in step 4), the
    // highest of the last third of the run.
    let verdict = if last >= 15 {
        let base = s.iter().find(|x| x.minute >= 5).unwrap();
        let tail: Vec<&Sample> = s.iter().filter(|x| x.minute >= last - last / 3).collect();
        let g = tail.iter().map(|x| x.gdi).max().unwrap();
        let u = tail.iter().map(|x| x.user).max().unwrap();
        let h = tail.iter().map(|x| x.handles).max().unwrap();
        let flat = g <= base.gdi + 5 && u <= base.user + 5 && h <= base.handles + 50;
        format!(
            "minute {} g{}/u{}/h{} -> max of minutes {}-{last} g{g}/u{u}/h{h}: {}",
            base.minute,
            base.gdi,
            base.user,
            base.handles,
            last - last / 3,
            if flat { "FLAT" } else { "GROWS" }
        )
    } else {
        format!("n/a (needs minute 15; the run ended at minute {last})")
    };
    // a first use after minute 5 costs objects once, which can read as GROWS
    let late: Vec<String> =
        TOUCHES.lock().map_or(Vec::new(), |t| t.iter().filter(|(m, _)| *m >= 5).map(|(m, w)| format!("{w} m{m}")).collect());
    selflog::line(&format!(
        "gate summary handle verdict: {verdict}; tray first-use events after minute 5: {}{}",
        late.len(),
        if late.is_empty() { String::new() } else { format!(" [{}]", late.join(", ")) }
    ));
    if let (Some(first), Some(end)) = (s.first(), s.last()) {
        let secs = series.seconds.max(1.0);
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
        selflog::line(&format!(
            "gate summary cycles: {} total ({:.0} per second); CPU {:.1} s, {:.3}% of one machine over the run",
            end.cycles,
            (end.cycles - first.cycles) as f64 / secs,
            end.cpu as f64 / 1e7,
            (end.cpu - first.cpu) as f64 / 1e7 / secs / cpus * 100.0
        ));
    }
}
