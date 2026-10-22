// The gate's content: the live overlay's own data/overlay.json, read only.
//
// The file is opened with every share flag (read, write, delete), held only
// for the read, and never written, locked, renamed or deleted. A read that
// fails, or a file caught part-written that does not parse, keeps the last
// good snapshot; each change of state (ok, missing, unreadable, unparsable)
// is logged once. The panel, chip, card and tray are drawn from what is
// parsed here (gate.rs), so the overlay's real titles - Hangul among them -
// reach Slint's glyph cache as they come.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::Read;
use std::os::windows::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::selflog;

/// FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE: the overlay's
/// writer and its replace of the file are never in our way.
const SHARE_ALL: u32 = 0x1 | 0x2 | 0x4;
/// How often the file's size and time are looked at.
pub const POLL: Duration = Duration::from_secs(2);

/// The live overlay's snapshot, from the repo this spike sits in.
pub fn path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../data/overlay.json")
}

#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct Window {
    pub label: String,
    pub percent: i64,
    pub severity: String,
    pub limited: bool,
    pub resets_at: i64,
}

#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct Usage {
    pub provider: String,
    pub stale: bool,
    pub status: String,
    pub windows: Vec<Window>,
}

#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct Counts {
    pub waiting: i64,
    pub busy: i64,
    pub idle: i64,
    pub running: i64,
    pub queued: i64,
    pub needs_input: i64,
    pub cut_off: i64,
    pub unread: i64,
}

#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct Row {
    pub key: String,
    pub provider: String,
    pub status: String,
    pub title: String,
    pub project: String,
    pub prompt: String,
    pub state_text: String,
    pub since: i64,
    pub session_id: String,
    pub cwd: String,
    pub place: String,
    pub unread: bool,
}

#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct Recent {
    pub title: String,
    pub project: String,
    pub state_text: String,
    pub session_id: String,
    pub cwd: String,
}

/// What the panel draws: everything but the time the file was written.
#[derive(Clone, Debug, Default, Hash, PartialEq)]
pub struct View {
    pub version: String,
    pub usage: Vec<Usage>,
    pub usage_text: String,
    pub counts: Counts,
    pub rows: Vec<Row>,
    /// recent, then recentMore
    pub recent: Vec<Recent>,
    pub max_rows: i64,
    pub recent_count: i64,
    pub opacity_pct: i64,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    /// epoch ms the overlay wrote it ("at")
    pub at: i64,
    /// the file's bytes
    pub bytes: usize,
    /// a hash of the view: a new one only when what is drawn changed
    pub sig: u64,
    pub view: View,
}

/// The file's state, for the log's transitions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ok,
    Missing,
    Unreadable,
    Unparsable,
}

fn s(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(t)) => t.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn i(v: &Value, k: &str) -> i64 {
    v.get(k)
        .and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)))
        .unwrap_or(0)
}

fn b(v: &Value, k: &str) -> bool {
    v.get(k).and_then(Value::as_bool).unwrap_or(false)
}

fn arr<'a>(v: &'a Value, k: &str) -> &'a [Value] {
    v.get(k)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

pub fn epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn parse(bytes: &[u8]) -> Result<Snapshot, String> {
    let v: Value = serde_json::from_slice(bytes).map_err(|e| format!("{e}"))?;
    if !v.is_object() {
        return Err("not an object".into());
    }
    let header = v.get("header").cloned().unwrap_or(Value::Null);
    let counts = v.get("counts").cloned().unwrap_or(Value::Null);
    let config = v.get("config").cloned().unwrap_or(Value::Null);
    let usage = arr(&header, "usage")
        .iter()
        .map(|u| Usage {
            provider: s(u, "provider"),
            stale: b(u, "stale"),
            status: s(u, "status"),
            windows: arr(u, "windows")
                .iter()
                .map(|w| Window {
                    label: s(w, "label"),
                    percent: i(w, "percent"),
                    severity: s(w, "severity"),
                    limited: b(w, "limited"),
                    resets_at: i(w, "resetsAt"),
                })
                .collect(),
        })
        .collect();
    let rows = arr(&v, "rows")
        .iter()
        .map(|r| Row {
            key: s(r, "key"),
            provider: s(r, "provider"),
            status: s(r, "status"),
            title: s(r, "title"),
            project: s(r, "project"),
            prompt: s(r, "prompt"),
            state_text: s(r, "stateText"),
            since: i(r, "since"),
            session_id: s(r, "sessionId"),
            cwd: s(r, "cwd"),
            place: s(r, "where"),
            unread: b(r, "unread"),
        })
        .collect();
    let recent = arr(&v, "recent")
        .iter()
        .chain(arr(&v, "recentMore"))
        .map(|r| Recent {
            title: s(r, "title"),
            project: s(r, "project"),
            state_text: s(r, "stateText"),
            session_id: s(r, "sessionId"),
            cwd: s(r, "cwd"),
        })
        .collect();
    let view = View {
        version: s(&v, "version"),
        usage,
        usage_text: s(&header, "usageText"),
        counts: Counts {
            waiting: i(&counts, "waiting"),
            busy: i(&counts, "busy"),
            idle: i(&counts, "idle"),
            running: i(&counts, "running"),
            queued: i(&counts, "queued"),
            needs_input: i(&counts, "needsInput"),
            cut_off: i(&counts, "cutOff"),
            unread: i(&counts, "unread"),
        },
        rows,
        recent,
        max_rows: i(&config, "maxRows"),
        recent_count: i(&config, "recent"),
        opacity_pct: config
            .get("opacity")
            .and_then(Value::as_f64)
            .map_or(100, |o| (o * 100.0).round() as i64),
    };
    let mut h = DefaultHasher::new();
    view.hash(&mut h);
    Ok(Snapshot {
        at: i(&v, "at"),
        bytes: bytes.len(),
        sig: h.finish(),
        view,
    })
}

/// Reads the file once, with every share flag, and closes it.
fn read_bytes() -> Result<Vec<u8>, (State, String)> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .share_mode(SHARE_ALL)
        .open(path())
        .map_err(|e| {
            let state = if e.kind() == std::io::ErrorKind::NotFound {
                State::Missing
            } else {
                State::Unreadable
            };
            (state, e.to_string())
        })?;
    let mut bytes = Vec::with_capacity(16 * 1024);
    file.read_to_end(&mut bytes)
        .map_err(|e| (State::Unreadable, e.to_string()))?;
    Ok(bytes)
}

/// The size and time of the file, without opening it for reading.
fn stamp() -> Option<(u64, SystemTime)> {
    let m = std::fs::metadata(path()).ok()?;
    Some((m.len(), m.modified().ok()?))
}

/// The reader's own memory of what it last saw.
pub struct Reader {
    state: Option<State>,
    stamp: Option<(u64, SystemTime)>,
    pub reads: u32,
    pub failures: u32,
}

impl Reader {
    pub fn new() -> Reader {
        Reader {
            state: None,
            stamp: None,
            reads: 0,
            failures: 0,
        }
    }

    fn note(&mut self, state: State, why: &str) {
        if self.state != Some(state) {
            selflog::line(&format!(
                "content: overlay.json {state:?}{}{why}",
                if why.is_empty() { "" } else { ": " }
            ));
            self.state = Some(state);
        }
    }

    /// A read of the file now: the snapshot, or None with the state logged
    /// once (the caller keeps its last good one).
    pub fn read(&mut self) -> Option<Snapshot> {
        self.stamp = stamp();
        self.reads += 1;
        match read_bytes() {
            Err((state, why)) => {
                self.failures += 1;
                self.note(state, &why);
                None
            }
            Ok(bytes) => match parse(&bytes) {
                Err(why) => {
                    self.failures += 1;
                    self.note(State::Unparsable, &format!("{} bytes, {why}", bytes.len()));
                    // read again at the next poll, whatever the stamp says
                    self.stamp = None;
                    None
                }
                Ok(snap) => {
                    self.note(
                        State::Ok,
                        &format!(
                            "{} bytes, {} rows, {} recent",
                            snap.bytes,
                            snap.view.rows.len(),
                            snap.view.recent.len()
                        ),
                    );
                    Some(snap)
                }
            },
        }
    }

    /// A read only when the size or the time moved since the last.
    pub fn poll(&mut self) -> Option<Snapshot> {
        let now = stamp();
        if now.is_some() && now == self.stamp {
            return None;
        }
        if now.is_none() {
            self.note(State::Missing, "no size or time");
            self.stamp = None;
            return None;
        }
        self.read()
    }
}

/// The poll thread (--gate): every POLL, the file read when it moved, and a
/// good snapshot handed to `got` (which posts it to Slint's loop).
pub fn spawn(
    mut reader: Reader,
    stop: Arc<AtomicBool>,
    got: impl Fn(Snapshot) + Send + 'static,
) -> std::thread::JoinHandle<(u32, u32)> {
    std::thread::Builder::new()
        .name("gate-content".into())
        .spawn(move || {
            while !stop.load(SeqCst) {
                std::thread::sleep(POLL);
                if let Some(snap) = reader.poll() {
                    got(snap);
                }
            }
            (reader.reads, reader.failures)
        })
        .unwrap()
}
