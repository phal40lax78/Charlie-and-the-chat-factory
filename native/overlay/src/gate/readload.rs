// The read-load stand-in (--gate, not --ui-only): the reads the PowerShell
// collector does each pass (overlay-data.ps1), done from a worker thread of
// the spike every PASS, so the gate hour's memory includes what a ported
// collector's I/O would hold. Read only, every file opened with all share
// flags; nothing of what is read is logged but counts, bytes and times.
//
// Kept across passes, as the collector's $Ctx keeps it:
//   stat cache    each file's size and time, from the last pass that saw it
//   open chats    each open row's transcript (projects/<slug of cwd>/<id>.jsonl,
//                 else that name in any project), read only when it grew:
//                 the new part from the last whole line, at most 8 MB back
//                 (Update-ChatOverlayText); a new or shrunk one backwards,
//                 256 KB then 1 MB blocks, until its title, a prompt and
//                 its mode are found, 16 MB at most (Find-ChatTailRecords)
//   Recent pool   the 20 newest transcripts not open, listed at most once a
//                 minute (Update-ChatOverlayRecent); each read again only when
//                 its size or time moved: the head, 64 KB (whole when 128 KB
//                 or less, Read-ChatChunk), and a 256 KB tail
//                 (Read-ChatOverlayRecentItem)
//   process table one Toolhelp32 snapshot a pass (Get-ChatProcessTable)
//   leak samples  once a minute each process's private bytes, 15 kept, each
//                 held against the newest at least 10 minutes back
//                 (Update-ChatOverlayLeaks, 2 GB)
//   card tail     the card's chat, read again only when the chat or its
//                 length changed (Update-ChatOverlayCard): the last 256 KB,
//                 four times as much up to 4 MB while it holds no whole line
//                 (Read-ChatOverlayCardTail); Claude's newest reply in it,
//                 cut at 280 characters, handed to the card - never logged
//   snapshot      data/gate-snapshot.json next to the exe, written whole each
//                 pass (its own data, never the overlay's)

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::ProcessStatus::{
    GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

use crate::selflog;

const SHARE_ALL: u32 = 0x1 | 0x2 | 0x4;
/// The collector's own cadence: Update-ChatOverlayRecent's doc, "Cheap on
/// a 2 s pass". Each duty keeps its own limit within it.
pub const PASS: Duration = Duration::from_secs(2);
const KB: u64 = 1024;
const MB: u64 = 1024 * 1024;
/// $ChatOverlayScanBudget: how far back one read of an open chat goes.
const SCAN_BUDGET: u64 = 16 * MB;
/// Get-ChatqExcerpt's cut of the reply on a card.
const REPLY_CHARS: usize = 280;
const RECENT_POOL: usize = 20;
const LEAK_KEEP: usize = 15;
const LEAK_GB: f64 = 2.0;

/// What the UI says to read: the open rows' chats and the card's.
#[derive(Clone, Default)]
pub struct Targets {
    /// (session id, cwd)
    pub open: Vec<(String, String)>,
    pub card: Option<(String, String)>,
}

/// Run totals, for the summary at exit.
#[derive(Default)]
pub struct Totals {
    pub passes: u32,
    pub bytes: u64,
    pub ms_total: u128,
    pub ms_max: u128,
    pub errors: u32,
}

struct OpenChat {
    path: Option<PathBuf>,
    missing_at: Option<Instant>,
    len: u64,
    line_end: u64,
    title_len: usize,
    prompt_len: usize,
}

struct RecentItem {
    sig: (u64, SystemTime),
    keep: bool,
    title_len: usize,
}

struct LeakSample {
    at: Instant,
    bytes: HashMap<(u32, String), u64>,
}

struct Pass {
    bytes: u64,
    reads: u32,
}

impl Pass {
    fn got(&mut self, n: usize) {
        self.bytes += n as u64;
        self.reads += 1;
    }
}

struct Load {
    projects: PathBuf,
    out: PathBuf,
    stat: HashMap<PathBuf, (u64, SystemTime)>,
    open: HashMap<String, OpenChat>,
    listing: Vec<(PathBuf, u64, SystemTime)>,
    listed_at: Option<Instant>,
    recent: HashMap<PathBuf, RecentItem>,
    leaks: VecDeque<LeakSample>,
    leak_at: Option<Instant>,
    growers: usize,
    /// the card's chat and its length when last read, and what that read found
    card_seen: Option<(PathBuf, u64)>,
    card_last: Option<CardTail>,
    totals: Totals,
}

fn open_read(path: &Path) -> std::io::Result<File> {
    std::fs::OpenOptions::new()
        .read(true)
        .share_mode(SHARE_ALL)
        .open(path)
}

/// `n` bytes at `at` (fewer where the file ends first).
fn read_at(f: &mut File, at: u64, n: u64) -> std::io::Result<Vec<u8>> {
    f.seek(SeekFrom::Start(at))?;
    let mut buf = Vec::with_capacity(n as usize);
    f.take(n).read_to_end(&mut buf)?;
    Ok(buf)
}

fn rfind(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    (0..=hay.len() - needle.len())
        .rev()
        .find(|&i| &hay[i..i + needle.len()] == needle)
}

fn count(hay: &[u8], needle: &[u8]) -> usize {
    hay.windows(needle.len()).filter(|w| *w == needle).count()
}

/// The JSON line around byte `at`, parsed, and the string field `field` in it.
fn field_at(text: &[u8], at: usize, field: &str) -> Option<String> {
    let start = text[..at]
        .iter()
        .rposition(|&c| c == b'\n')
        .map_or(0, |p| p + 1);
    let end = text[at..]
        .iter()
        .position(|&c| c == b'\n')
        .map_or(text.len(), |p| at + p);
    let v: serde_json::Value = serde_json::from_slice(&text[start..end]).ok()?;
    v.get(field)?.as_str().map(str::to_string)
}

/// Claude's name for a project folder (Get-ChatSlug).
fn slug(cwd: &str) -> String {
    let p = cwd.trim_end_matches(['\\', '/']);
    let p = if p.is_empty() || (p.len() == 2 && p.ends_with(':')) {
        cwd
    } else {
        p
    };
    p.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

fn is_guid_name(name: &str) -> bool {
    name.len() == 42
        && name.ends_with(".jsonl")
        && name[..36]
            .chars()
            .all(|c| c.is_ascii_hexdigit() || c == '-')
}

impl Load {
    fn new() -> Load {
        let home = std::env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_default();
        Load {
            projects: home.join(".claude").join("projects"),
            out: selflog::data_dir().join("gate-snapshot.json"),
            stat: HashMap::new(),
            open: HashMap::new(),
            listing: Vec::new(),
            listed_at: None,
            recent: HashMap::new(),
            leaks: VecDeque::new(),
            leak_at: None,
            growers: 0,
            card_seen: None,
            card_last: None,
            totals: Totals::default(),
        }
    }

    /// The file's size and time, into the stat cache.
    fn stat(&mut self, path: &Path) -> Option<(u64, SystemTime)> {
        let m = std::fs::metadata(path).ok()?;
        let st = (m.len(), m.modified().ok()?);
        self.stat.insert(path.to_path_buf(), st);
        Some(st)
    }

    fn find_transcript(&self, sid: &str, cwd: &str) -> Option<PathBuf> {
        let name = format!("{sid}.jsonl");
        if !cwd.is_empty() {
            let p = self.projects.join(slug(cwd)).join(&name);
            if p.exists() {
                return Some(p);
            }
        }
        std::fs::read_dir(&self.projects)
            .ok()?
            .flatten()
            .map(|d| d.path().join(&name))
            .find(|p| p.exists())
    }

    /// One open chat's transcript, read only when it grew.
    fn open_chat(&mut self, sid: &str, cwd: &str, pass: &mut Pass) {
        let now = Instant::now();
        let mut chat = self.open.remove(sid).unwrap_or(OpenChat {
            path: None,
            missing_at: None,
            len: 0,
            line_end: 0,
            title_len: 0,
            prompt_len: 0,
        });
        if chat.path.as_ref().is_none_or(|p| !p.exists()) {
            if chat
                .missing_at
                .is_some_and(|t| now.duration_since(t) < Duration::from_secs(30))
            {
                self.open.insert(sid.to_string(), chat);
                return;
            }
            chat.path = self.find_transcript(sid, cwd);
            chat.len = 0;
            chat.missing_at = chat.path.is_none().then_some(now);
        }
        if let Some(path) = chat.path.clone()
            && let Some((len, _)) = self.stat(&path)
            && len != chat.len
        {
            let from = if chat.len > 0 && len > chat.len {
                chat.line_end.max(len.saturating_sub(8 * MB))
            } else {
                0
            };
            // the collector's budget ($ChatOverlayScanBudget); a
            // first sight reads on for the mode too (-Mode)
            match tail_records(&path, from, SCAN_BUDGET, from == 0, pass) {
                Ok(r) => {
                    chat.len = len;
                    chat.line_end = r.line_end;
                    if r.title_len > 0 {
                        chat.title_len = r.title_len;
                    }
                    if r.prompt_len > 0 {
                        chat.prompt_len = r.prompt_len;
                    }
                }
                Err(_) => self.totals.errors += 1,
            }
        }
        self.open.insert(sid.to_string(), chat);
    }

    /// The transcripts straight under projects/<slug>/, newest first; at
    /// most once a minute.
    fn list(&mut self) -> bool {
        if self
            .listed_at
            .is_some_and(|t| t.elapsed() < Duration::from_secs(60))
        {
            return false;
        }
        let mut all = Vec::new();
        if let Ok(dirs) = std::fs::read_dir(&self.projects) {
            for d in dirs.flatten() {
                let Ok(files) = std::fs::read_dir(d.path()) else {
                    continue;
                };
                for f in files.flatten() {
                    let name = f.file_name();
                    if !is_guid_name(&name.to_string_lossy()) {
                        continue;
                    }
                    if let Ok(m) = f.metadata()
                        && let Ok(t) = m.modified()
                    {
                        all.push((f.path(), m.len(), t));
                    }
                }
            }
        }
        all.sort_by_key(|a| std::cmp::Reverse(a.2));
        let seen: HashSet<&PathBuf> = all.iter().map(|e| &e.0).collect();
        self.recent.retain(|k, _| seen.contains(k));
        self.listing = all;
        self.listed_at = Some(Instant::now());
        true
    }

    /// The Recent pool: the 20 newest not open, each read again only once
    /// its size or time moved.
    fn recent_pool(&mut self, skip: &HashSet<String>, pass: &mut Pass) -> (usize, u32) {
        let mut kept = 0;
        let mut reads = 0;
        let listing = std::mem::take(&mut self.listing);
        for (path, len, time) in &listing {
            if kept >= RECENT_POOL {
                break;
            }
            let id = path
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            if skip.contains(&id) {
                continue;
            }
            self.stat.insert(path.clone(), (*len, *time));
            let sig = (*len, *time);
            if self.recent.get(path).is_none_or(|r| r.sig != sig) {
                reads += 1;
                let item = match recent_item(path, *len, pass) {
                    Ok(item) => item,
                    Err(_) => {
                        self.totals.errors += 1;
                        RecentItem {
                            sig,
                            keep: false,
                            title_len: 0,
                        }
                    }
                };
                self.recent.insert(path.clone(), RecentItem { sig, ..item });
            }
            if self.recent[path].keep {
                kept += 1;
            }
        }
        self.listing = listing;
        (kept, reads)
    }

    /// Once a minute, each process's private bytes; 15 samples kept; the
    /// processes grown 2 GB or more since the newest at least 10 min back.
    fn leak_sample(&mut self, procs: &[(u32, String)]) -> bool {
        if self
            .leak_at
            .is_some_and(|t| t.elapsed() < Duration::from_secs(60))
        {
            return false;
        }
        let now = Instant::now();
        self.leak_at = Some(now);
        let mut bytes = HashMap::with_capacity(procs.len());
        for (pid, name) in procs {
            if let Some(b) = private_bytes(*pid) {
                bytes.insert((*pid, name.clone()), b);
            }
        }
        let old = self
            .leaks
            .iter()
            .rev()
            .find(|s| now.duration_since(s.at) >= Duration::from_secs(600));
        self.growers = old.map_or(0, |old| {
            bytes
                .iter()
                .filter(|&(k, &b)| {
                    old.bytes.get(k).is_some_and(|&o| {
                        b.saturating_sub(o) as f64 >= LEAK_GB * (1u64 << 30) as f64
                    })
                })
                .count()
        });
        self.leaks.push_back(LeakSample { at: now, bytes });
        while self.leaks.len() > LEAK_KEEP
            || self
                .leaks
                .front()
                .is_some_and(|s| now.duration_since(s.at) > Duration::from_secs(15 * 60))
        {
            self.leaks.pop_front();
        }
        true
    }

    fn pass(&mut self, targets: &Targets, on_reply: &dyn Fn(String, String)) {
        let start = Instant::now();
        let mut pass = Pass { bytes: 0, reads: 0 };
        let open_ids: HashSet<String> = targets.open.iter().map(|(sid, _)| sid.clone()).collect();
        self.open.retain(|sid, _| open_ids.contains(sid));
        for (sid, cwd) in &targets.open {
            self.open_chat(sid, cwd, &mut pass);
        }
        let open_reads = pass.reads;
        let listed = self.list();
        let (pool, pool_reads) = self.recent_pool(&open_ids, &mut pass);
        let procs = process_table();
        let sampled = self.leak_sample(&procs);
        // the card's chat read again only when it or its length changed
        // (Update-ChatOverlayCard); its reply handed to the card
        let mut card_bytes = 0;
        if let Some((sid, cwd)) = targets.card.as_ref() {
            let path = self
                .open
                .get(sid)
                .and_then(|c| c.path.clone())
                .or_else(|| self.find_transcript(sid, cwd));
            let seen = path.and_then(|p| self.stat(&p).map(|(len, _)| (p, len)));
            if let Some((p, _)) = seen.as_ref().filter(|_| seen != self.card_seen) {
                match card_tail(p, &mut pass) {
                    Ok(c) => {
                        card_bytes = c.read;
                        on_reply(sid.clone(), c.reply.clone());
                        self.card_last = Some(c);
                    }
                    Err(_) => self.totals.errors += 1,
                }
                self.card_seen = seen;
            }
        }
        let card = self.card_last.take();
        let written = self.write_snapshot(procs.len(), &card);
        self.card_last = card;
        let ms = start.elapsed().as_millis();
        let t = &mut self.totals;
        t.passes += 1;
        t.bytes += pass.bytes;
        t.ms_total += ms;
        t.ms_max = t.ms_max.max(ms);
        // at a 2 s pass, logged when it read anything, and once a minute
        if pass.reads == 0 && t.passes > 3 && !t.passes.is_multiple_of(30) {
            return;
        }
        let (card_window, card_tools) = self
            .card_last
            .as_ref()
            .map_or((0, 0), |c| (c.window, c.tools));
        selflog::line(&format!(
            "readload pass {}: open {} (reads {open_reads}); listed {} ({} transcripts); recent pool {pool}/{RECENT_POOL} (reads {pool_reads}); stat cache {}; procs {}; leak samples {}/{LEAK_KEEP}{} growers {}; card tail {card_bytes} bytes (window {card_window}, tool calls {card_tools}); snapshot {written} bytes; read {} bytes in {} reads; {ms} ms",
            t.passes,
            targets.open.len(),
            if listed { "now" } else { "kept" },
            self.listing.len(),
            self.stat.len(),
            procs.len(),
            self.leaks.len(),
            if sampled { " (new)" } else { "" },
            self.growers,
            pass.bytes,
            pass.reads,
        ));
    }

    /// The pass's own snapshot, in the spike's data/: counts and lengths only.
    fn write_snapshot(&mut self, procs: usize, card: &Option<CardTail>) -> usize {
        let open: Vec<serde_json::Value> = self
            .open
            .iter()
            .map(|(sid, c)| serde_json::json!({ "sessionId": sid, "found": c.path.is_some(), "length": c.len, "lineEnd": c.line_end, "titleLen": c.title_len, "promptLen": c.prompt_len }))
            .collect();
        let recent: Vec<serde_json::Value> = self
            .recent
            .iter()
            .filter(|(_, r)| r.keep)
            .map(|(p, r)| serde_json::json!({ "id": p.file_stem().map(|s| s.to_string_lossy().to_string()), "length": r.sig.0, "titleLen": r.title_len }))
            .collect();
        let snap = serde_json::json!({
            "pass": self.totals.passes + 1,
            "at": crate::gate::content::epoch_ms(),
            "open": open,
            "recent": recent,
            "listed": self.listing.len(),
            "statCache": self.stat.len(),
            "procs": procs,
            "leakSamples": self.leaks.len(),
            "growers": self.growers,
            "card": card.as_ref().map(|c| serde_json::json!({ "read": c.read, "window": c.window, "tools": c.tools, "lastPrompt": c.has_last_prompt, "todo": c.has_todo, "replyLen": c.reply.chars().count() })),
        });
        let text = serde_json::to_vec(&snap).unwrap();
        let tmp = self.out.with_extension("json.tmp");
        let ok = std::fs::write(&tmp, &text).and_then(|_| std::fs::rename(&tmp, &self.out));
        if ok.is_err() {
            self.totals.errors += 1;
        }
        text.len()
    }
}

struct TailRecords {
    line_end: u64,
    title_len: usize,
    prompt_len: usize,
}

/// Find-ChatTailRecords: back from the end, 256 KB then 1 MB at a time,
/// down to `from` and `budget` bytes at most, until a prompt (a last-prompt
/// record, a typed prompt or a slash command) and a title (an ai-title or a
/// custom-title) are both found - and, with `mode` (a first sight, -Mode),
/// a permissionMode too. The line end is where the file's last whole line
/// ends. Unlike the real one, a typed prompt is told by its marker alone,
/// not read (Read-ClaudePrompt).
fn tail_records(
    path: &Path,
    from: u64,
    budget: u64,
    mode: bool,
    pass: &mut Pass,
) -> std::io::Result<TailRecords> {
    let mut f = open_read(path)?;
    let len = f.metadata()?.len();
    let mut pos = len;
    let mut block = 256 * KB;
    let mut scanned = 0;
    let mut out = TailRecords {
        line_end: len,
        title_len: 0,
        prompt_len: 0,
    };
    let (mut prompt, mut title, mut mode_found) = (false, false, false);
    let mut first = true;
    while pos > from && scanned < budget {
        let n = block.min(pos - from);
        pos -= n;
        block = MB;
        let buf = read_at(&mut f, pos, n)?;
        pass.got(buf.len());
        scanned += buf.len() as u64;
        if first {
            first = false;
            out.line_end = buf
                .iter()
                .rposition(|&c| c == b'\n')
                .map_or(pos, |i| pos + i as u64 + 1);
        }
        if !title {
            if let Some(at) = rfind(&buf, b"\"type\":\"ai-title\"") {
                out.title_len = field_at(&buf, at, "aiTitle").map_or(0, |t| t.chars().count());
                title = true;
            } else if let Some(at) = rfind(&buf, b"\"type\":\"custom-title\"") {
                out.title_len = field_at(&buf, at, "customTitle").map_or(0, |t| t.chars().count());
                title = true;
            }
        }
        if !prompt {
            if let Some(at) = rfind(&buf, b"\"type\":\"last-prompt\"") {
                out.prompt_len = field_at(&buf, at, "lastPrompt").map_or(0, |t| t.chars().count());
                prompt = true;
            } else {
                prompt = rfind(&buf, b"\"origin\":{\"kind\":\"human\"}").is_some()
                    || rfind(&buf, b"\"content\":\"<command-name>/").is_some();
            }
        }
        if mode && !mode_found {
            mode_found = rfind(&buf, b"\"permissionMode\":\"").is_some();
        }
        if prompt && title && (mode_found || !mode) {
            break;
        }
    }
    Ok(out)
}

/// Read-ChatOverlayRecentItem: the head (64 KB, whole when 128 KB or
/// less), its first line not a side chat's and a cwd in it, then a 256 KB
/// tail for the title.
fn recent_item(path: &Path, len: u64, pass: &mut Pass) -> std::io::Result<RecentItem> {
    let mut f = open_read(path)?;
    let head = if len <= 128 * KB {
        read_at(&mut f, 0, len)?
    } else {
        let h = read_at(&mut f, 0, 64 * KB)?;
        let t = read_at(&mut f, len - 64 * KB, 64 * KB)?;
        pass.got(t.len());
        h
    };
    pass.got(head.len());
    drop(f);
    let first = head
        .iter()
        .position(|&c| c == b'\n')
        .map_or(&head[..], |i| &head[..i]);
    let side = rfind(first, b"\"isSidechain\":true").is_some();
    let said = rfind(&head, b"\"type\":\"user\"").is_some()
        || rfind(&head, b"\"type\":\"assistant\"").is_some();
    let cwd = rfind(&head, b"\"cwd\":").is_some();
    let keep = !side && cwd && (len > 64 * KB || said);
    let mut title_len = 0;
    if keep {
        title_len = tail_records(path, 0, 256 * KB, false, pass)?.title_len;
    }
    Ok(RecentItem {
        sig: (len, SystemTime::UNIX_EPOCH),
        keep,
        title_len,
    })
}

struct CardTail {
    read: usize,
    window: u64,
    tools: usize,
    has_last_prompt: bool,
    has_todo: bool,
    /// Claude's newest reply text, cut at REPLY_CHARS; empty for none
    reply: String,
}

fn has(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// Claude's newest text in the window (Read-ChatOverlayCardTail's Reply):
/// back from the end a line at a time, past a side chat's lines and Claude
/// Code's own words (<synthetic>), the first assistant line that is a text
/// block; its whitespace run together, cut as the card shows it.
fn newest_reply(t: &[u8], stop: usize) -> String {
    let mut end = t.len();
    while end > stop {
        let s = t[stop..end - 1]
            .iter()
            .rposition(|&c| c == b'\n')
            .map_or(stop, |i| stop + i + 1);
        let line = &t[s..end];
        end = s;
        let head = &line[..line.len().min(600)];
        if has(&line[..line.len().min(200)], b"\"isSidechain\":true")
            || !has(head, b"\"role\":\"assistant\"")
            || !has(head, b"\"content\":[{\"type\":\"text\"")
            || has(head, b"\"model\":\"<synthetic>\"")
        {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        let text = v["message"]["content"]
            .as_array()
            .and_then(|c| c.iter().find(|b| b["type"] == "text"))
            .and_then(|b| b["text"].as_str());
        let text = text
            .map(|x| x.split_whitespace().collect::<Vec<_>>().join(" "))
            .unwrap_or_default();
        if !text.is_empty() {
            return if text.chars().count() <= REPLY_CHARS {
                text
            } else {
                text.chars().take(REPLY_CHARS - 1).chain(['…']).collect()
            };
        }
    }
    String::new()
}

/// Read-ChatOverlayCardTail: the last 256 KB, four times as much up to
/// 4 MB while no whole line is in it.
fn card_tail(path: &Path, pass: &mut Pass) -> std::io::Result<CardTail> {
    let mut f = open_read(path)?;
    let len = f.metadata()?.len();
    let mut size = 256 * KB;
    let mut read = 0;
    let (t, n, stop) = loop {
        let n = size.min(len);
        let t = read_at(&mut f, len - n, n)?;
        read += t.len();
        pass.got(t.len());
        let stop = if n < len {
            t.iter().position(|&c| c == b'\n').map_or(0, |i| i + 1)
        } else {
            0
        };
        let whole = stop > 0
            && t.iter()
                .rposition(|&c| c == b'\n')
                .is_some_and(|l| l >= stop);
        if n >= len || whole || size >= 4 * MB {
            break (t, n, stop);
        }
        size = (size * 4).min(4 * MB);
    };
    // a window cut mid-line with no whole line in it says nothing
    let reply = if n < len && stop == 0 {
        String::new()
    } else {
        newest_reply(&t, stop)
    };
    Ok(CardTail {
        read,
        window: n,
        tools: count(&t, b"\"type\":\"tool_use\""),
        has_last_prompt: rfind(&t, b"\"type\":\"last-prompt\"").is_some(),
        has_todo: rfind(&t, b"\"name\":\"TodoWrite\",\"input\":").is_some(),
        reply,
    })
}

/// Every process's pid and name, from one Toolhelp32 snapshot.
fn process_table() -> Vec<(u32, String)> {
    let mut out = Vec::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return out;
        };
        let mut e = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut more = Process32FirstW(snap, &mut e).is_ok();
        while more {
            let len = e
                .szExeFile
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(e.szExeFile.len());
            out.push((
                e.th32ProcessID,
                String::from_utf16_lossy(&e.szExeFile[..len]),
            ));
            more = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    out
}

/// A process's private bytes, read with the least access there is; None
/// where Windows will not say (protected or gone).
fn private_bytes(pid: u32) -> Option<u64> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut mem = PROCESS_MEMORY_COUNTERS_EX {
            cb: size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
            ..Default::default()
        };
        let ok = GetProcessMemoryInfo(
            h,
            &mut mem as *mut _ as *mut PROCESS_MEMORY_COUNTERS,
            mem.cb,
        )
        .is_ok();
        let _ = CloseHandle(h);
        ok.then_some(mem.PrivateUsage as u64)
    }
}

/// The worker: a pass at once, then every PASS until `stop`. `on_reply`:
/// the card's chat (session id) and the reply its tail holds, at each read.
pub fn spawn(
    targets: Arc<Mutex<Targets>>,
    stop: Arc<AtomicBool>,
    on_reply: impl Fn(String, String) + Send + 'static,
) -> std::thread::JoinHandle<Totals> {
    std::thread::Builder::new()
        .name("gate-readload".into())
        .spawn(move || {
            let mut load = Load::new();
            selflog::line(&format!(
                "readload: projects folder found: {}",
                load.projects.is_dir()
            ));
            let mut next = Instant::now() + Duration::from_secs(5);
            while !stop.load(SeqCst) {
                if Instant::now() >= next {
                    next += PASS;
                    let t = targets.lock().unwrap().clone();
                    load.pass(&t, &on_reply);
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            load.totals
        })
        .unwrap()
}
