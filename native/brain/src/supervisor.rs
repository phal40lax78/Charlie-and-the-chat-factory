//! The `local` backend (SPEC.md section 7): RAM guard, model lifecycle state
//! machine (injected clock, memory, llama-server and download source, so
//! every transition is testable), `/install`, `/unload`, the idle kill.
//!
//! No fallback: a model-tier task is answered by the model or not at all
//! (`Unavailable`, a 503). A request never starts a download; only
//! `/install` does.

use crate::api::{Answer, Tail, CONTRACT};
use crate::catalogue::Task;
use crate::config::{self, Layout, Manifest, ModelSpec};
use crate::engine::Unavailable;
use crate::fetch::{self, Pin, Source};
use crate::llm::{self, Fail};
use crate::schema;
use crate::sysinfo::{Mem, MemSource};
use crate::usage;
use chrono::Local as LocalTime;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub const MB: u64 = 1024 * 1024;
/// llama-server is killed after this long with no request.
pub const IDLE_MS: u64 = 10 * 60_000;
pub const DEFER_RETRY_MS: u64 = 60_000;
pub const DEFER_LINE_MS: u64 = 10 * 60_000;
pub const LOAD_BACKOFF_MS: u64 = 10 * 60_000;
pub const LOAD_STRIKES: u32 = 3;
/// Attempts one `/install` makes before it gives up with a note.
pub const DL_STRIKES: u32 = 3;
pub const MIN_DISK: u64 = 3_000_000_000;
/// llama-server context size. Small on purpose: a tail is a few hundred
/// tokens, and the KV cache grows with it (the bakeoff saw 5-8 GB in use).
pub const CTX: u32 = 4096;
/// `-ngl` with `"gpu": true`: every layer the GPU takes.
pub const GPU_LAYERS: u32 = 99;

// ---------------------------------------------------------------- clock

pub trait Clock: Send + Sync {
    fn now_ms(&self) -> u64;
}

pub struct SystemClock(Instant);

impl SystemClock {
    pub fn new() -> Self {
        SystemClock(Instant::now())
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        self.0.elapsed().as_millis() as u64
    }
}

/// A clock the test moves by hand.
#[derive(Default)]
pub struct ManualClock(AtomicU64);

impl ManualClock {
    pub fn advance(&self, ms: u64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

// ---------------------------------------------------------------- RAM guard

#[derive(Debug, PartialEq, Eq)]
pub enum Guard {
    Ok,
    /// `pct` = free / total, for the "Resources available: 12%" line.
    Defer { pct: u8 },
}

/// Free memory kept back after the load, on top of the model's own need.
const RESERVE_AFTER_LOAD: u64 = 1024 * MB;

/// Free bytes the guard asks for before a load.
pub fn ram_need(gguf_bytes: u64) -> u64 {
    (gguf_bytes as f64 * 1.15) as u64 + 300 * MB + RESERVE_AFTER_LOAD
}

/// Free >= gguf * 1.15 + 300 MB + a fixed 1 GiB reserve ([RESERVE_AFTER_LOAD]).
/// No reading (unsupported OS) lets the load through.
pub fn ram_guard(mem: Option<Mem>, gguf_bytes: u64) -> Guard {
    let Some(m) = mem else { return Guard::Ok };
    let need = ram_need(gguf_bytes);
    let pct = if m.total == 0 { 0 } else { (m.free as u128 * 100 / m.total as u128) as u8 };
    if m.free < need {
        Guard::Defer { pct }
    } else {
        Guard::Ok
    }
}

// ---------------------------------------------------------------- lifecycle

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Absent,
    Cold,
    Loading,
    Hot,
    Deferred,
    Downloading,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Absent => "absent",
            State::Cold => "cold",
            State::Loading => "loading",
            State::Hot => "hot",
            State::Deferred => "deferred",
            State::Downloading => "downloading",
        }
    }
}

/// What the engine must do for a request that wants the model.
#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    Serve,
    /// A load is running; wait for it.
    Wait,
    /// Caller starts the load.
    Load,
    /// No GGUF or no llama-server on disk. Only `/install` fetches them.
    Absent,
    Downloading,
    Backoff,
    /// `announce`: the once-per-10-minutes deferral line is due.
    Defer { announce: bool },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Tick {
    Nothing,
    /// Idle limit reached: kill llama-server.
    KillIdle,
}

#[derive(Debug)]
pub struct Lifecycle {
    pub state: State,
    last_use: u64,
    load_fails: u32,
    load_backoff_until: u64,
    deferred_until: u64,
    last_announce: Option<u64>,
}

impl Lifecycle {
    pub fn new(model_present: bool) -> Self {
        Lifecycle {
            state: if model_present { State::Cold } else { State::Absent },
            last_use: 0,
            load_fails: 0,
            load_backoff_until: 0,
            deferred_until: 0,
            last_announce: None,
        }
    }

    pub fn on_request(&mut self, now: u64, present: bool, mem: Option<Mem>, gguf: u64) -> Plan {
        match self.state {
            State::Hot => {
                self.last_use = now;
                return Plan::Serve;
            }
            State::Loading => return Plan::Wait,
            State::Downloading => return Plan::Downloading,
            _ => {}
        }
        if !present {
            self.state = State::Absent;
            return Plan::Absent;
        }
        if self.state == State::Absent {
            self.state = State::Cold;
        }
        if now < self.load_backoff_until {
            return Plan::Backoff;
        }
        if self.state == State::Deferred && now < self.deferred_until {
            return Plan::Defer { announce: false };
        }
        match ram_guard(mem, gguf) {
            Guard::Defer { .. } => {
                self.state = State::Deferred;
                self.deferred_until = now + DEFER_RETRY_MS;
                let announce = self.last_announce.is_none_or(|t| now - t >= DEFER_LINE_MS);
                if announce {
                    self.last_announce = Some(now);
                }
                Plan::Defer { announce }
            }
            Guard::Ok => {
                self.state = State::Loading;
                Plan::Load
            }
        }
    }

    pub fn load_ok(&mut self, now: u64) {
        self.state = State::Hot;
        self.last_use = now;
        self.load_fails = 0;
    }

    /// A failed load or a crash: back to Cold; three in a row back off 10 minutes.
    pub fn load_failed(&mut self, now: u64) {
        self.state = State::Cold;
        self.load_fails += 1;
        if self.load_fails >= LOAD_STRIKES {
            self.load_backoff_until = now + LOAD_BACKOFF_MS;
            self.load_fails = 0;
        }
    }

    /// `/install` started its fetch.
    pub fn download_start(&mut self) {
        self.state = State::Downloading;
    }

    /// The fetch ended, after its strikes. `present`: model and server are on disk.
    pub fn download_done(&mut self, present: bool) {
        self.state = if present { State::Cold } else { State::Absent };
    }

    /// `idle_ms`: [IDLE_MS], shorter in tests.
    pub fn tick(&mut self, now: u64, idle_ms: u64) -> Tick {
        if self.state == State::Hot && now.saturating_sub(self.last_use) >= idle_ms {
            self.state = State::Cold;
            return Tick::KillIdle;
        }
        Tick::Nothing
    }

    pub fn idle_ms(&self, now: u64) -> u64 {
        if self.state == State::Hot {
            now.saturating_sub(self.last_use)
        } else {
            0
        }
    }

    /// The model went away (unload, swap). No strike.
    pub fn go_cold(&mut self, present: bool) {
        if matches!(self.state, State::Hot | State::Loading | State::Deferred | State::Cold | State::Absent) {
            self.state = if present { State::Cold } else { State::Absent };
        }
    }
}

// ---------------------------------------------------------------- llama-server

/// The llama-server side. Real: `proc::ProcLlama`. Unit tests: `testutil::FakeLlm`.
pub trait Llm: Send + Sync {
    /// Spawn `exe` with `args` (host and port are the implementation's own)
    /// and wait until healthy.
    fn start(&self, exe: &Path, args: &[String]) -> Result<(), String>;
    /// The process is still running. Only a dead process is a crash.
    fn alive(&self) -> bool;
    fn stop(&self);
    fn ask(&self, system: &str, user: &str, schema: &Value, timeout: Duration) -> llm::Reply;
}

/// llama-server flags after `--host`/`--port`: the model, a small context, one
/// slot, no prompt cache (memory), the chat template, then `-ngl` for the
/// GPU and the model's own flags.
pub fn launch_args(gguf: &Path, spec: &ModelSpec, gpu: bool, threads: usize) -> Vec<String> {
    let mut a: Vec<String> = vec!["-m".into(), gguf.display().to_string()];
    for s in ["-c", &CTX.to_string(), "-np", "1", "--cache-ram", "0", "-t", &threads.to_string(), "--no-webui", "--jinja"] {
        a.push(s.to_string());
    }
    if gpu {
        a.extend(["-ngl".to_string(), GPU_LAYERS.to_string()]);
    }
    a.extend(spec.args.iter().cloned());
    a
}

/// Half the cores, at least one.
fn threads() -> usize {
    std::thread::available_parallelism().map_or(2, |n| (n.get() / 2).max(1))
}

// ---------------------------------------------------------------- the backend

#[derive(Debug, PartialEq, Eq)]
pub enum Install {
    /// A fetch started (202).
    Started(String),
    /// A fetch was already running; this call joins it (202). Its model id.
    Joined(String),
    /// Server and model already on disk; nothing to fetch (200).
    Present { model: String, state: &'static str },
}

#[derive(Debug, PartialEq, Eq)]
pub enum InstallErr {
    /// Not a catalogue model id (400), with the ids that are.
    Unknown(Vec<String>),
    /// No fetch started: `disk` (under 3 GB free) or `busy` (a load owns the old model).
    Refused(Unavailable),
}

/// Knobs a test turns; [Default] is the shipped behaviour.
#[derive(Debug, Clone)]
pub struct Tuning {
    /// How long a request waits on a load before it answers 503 `loading`.
    pub load_wait: Duration,
    /// [IDLE_MS].
    pub idle_ms: u64,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning { load_wait: Duration::from_millis(2000), idle_ms: IDLE_MS }
    }
}

struct Inner {
    life: Lifecycle,
    spec: Option<ModelSpec>,
    malformed: u32,
    /// The model id `/install` is fetching.
    installing: Option<String>,
    /// While a fetch runs, server archive and GGUF together.
    dl_pct: Option<u8>,
    /// Set when a fetch gave up after `DL_STRIKES`; cleared by the next `/install`.
    dl_note: Option<String>,
}

struct Shared {
    layout: Layout,
    manifest: Manifest,
    clock: Arc<dyn Clock>,
    mem: Arc<dyn MemSource>,
    llm: Arc<dyn Llm>,
    source: Arc<dyn Source>,
    tuning: Tuning,
    inner: Mutex<Inner>,
    cv: Condvar,
    usage_lock: Mutex<()>,
}

#[derive(Clone)]
pub struct Local(Arc<Shared>);

impl Local {
    pub fn new(
        layout: Layout,
        manifest: Manifest,
        clock: Arc<dyn Clock>,
        mem: Arc<dyn MemSource>,
        llm: Arc<dyn Llm>,
        source: Arc<dyn Source>,
        tuning: Tuning,
    ) -> Local {
        let spec = config::pick_model(&layout, &manifest);
        if let Some(s) = &spec {
            config::swap_models(&layout.dir, &s.file);
        }
        let me = Local(Arc::new(Shared {
            layout,
            manifest,
            clock,
            mem,
            llm,
            source,
            tuning,
            inner: Mutex::new(Inner {
                life: Lifecycle::new(false),
                spec: spec.clone(),
                malformed: 0,
                installing: None,
                dl_pct: None,
                dl_note: None,
            }),
            cv: Condvar::new(),
            usage_lock: Mutex::new(()),
        }));
        let present = spec.as_ref().is_some_and(|s| me.present(s));
        me.lock().life = Lifecycle::new(present);
        me
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.0.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn log(&self, msg: &str) {
        config::diag(&self.0.layout, msg);
    }

    fn gpu(&self) -> bool {
        config::local_opts(&self.0.layout).gpu
    }

    fn model_path(&self, spec: &ModelSpec) -> PathBuf {
        self.0.layout.dir.join(&spec.file)
    }

    /// The GGUF and the llama-server build `brain.json` asks for are both on disk.
    fn present(&self, spec: &ModelSpec) -> bool {
        self.model_path(spec).is_file() && self.0.layout.llama_exe(self.gpu()).is_some()
    }

    /// The configured model id, for `/usage`.
    pub fn model_id(&self) -> Option<String> {
        self.lock().spec.as_ref().map(|s| s.id.clone())
    }

    /// A 503 reason with the lifecycle state as it is now.
    fn unavailable(&self, note: &str) -> Unavailable {
        Unavailable { state: self.lock().life.state.name(), note: note.into() }
    }

    /// A changed `brain.json` swaps the model: unload, delete the old file.
    fn refresh_model(&self) {
        let want = config::pick_model(&self.0.layout, &self.0.manifest);
        let mut g = self.lock();
        let same = match (&g.spec, &want) {
            (Some(a), Some(b)) => a.id == b.id,
            (None, None) => true,
            _ => false,
        };
        // A running load or download owns the files; the swap waits for it.
        if same || matches!(g.life.state, State::Loading | State::Downloading) {
            return;
        }
        if g.life.state == State::Hot {
            self.0.llm.stop();
        }
        if let Some(w) = &want {
            let gone = config::swap_models(&self.0.layout.dir, &w.file);
            self.log(&format!("model swap to {}, removed {gone:?}", w.id));
        }
        let present = want.as_ref().is_some_and(|s| self.present(s));
        g.life.go_cold(present);
        g.spec = want;
    }

    /// The model's answer, or why there is none. Never starts a download.
    pub fn ask(&self, task: &Task, tail: &Tail) -> Result<Answer, Unavailable> {
        self.refresh_model();
        let now = self.0.clock.now_ms();
        let (plan, mem, gguf, spec) = {
            let mut g = self.lock();
            let Some(spec) = g.spec.clone() else {
                return Err(Unavailable { state: g.life.state.name(), note: "no model".into() });
            };
            let size = std::fs::metadata(self.model_path(&spec)).ok().filter(|m| m.is_file()).map(|m| m.len());
            let present = size.is_some() && self.0.layout.llama_exe(self.gpu()).is_some();
            let (mem, gguf) = (self.0.mem.read(), size.unwrap_or(spec.bytes));
            (g.life.on_request(now, present, mem, gguf), mem, gguf, spec)
        };
        match plan {
            Plan::Serve => {}
            Plan::Wait => self.wait_hot()?,
            Plan::Load => {
                let me = self.clone();
                std::thread::spawn(move || me.do_load());
                self.wait_hot()?;
            }
            Plan::Absent => return Err(self.unavailable("not installed")),
            Plan::Downloading => return Err(self.unavailable("downloading")),
            Plan::Backoff => return Err(self.unavailable("backoff")),
            Plan::Defer { announce } => {
                if announce {
                    let free = mem.map_or(0, |m| m.free);
                    self.log(&format!("defer free={free} need={}", ram_need(gguf)));
                }
                return Err(self.unavailable(if announce { "announce" } else { "quiet" }));
            }
        }
        let user = llm::render_tail(tail);
        let schema = task.schema_value();
        let timeout = Duration::from_millis(config::local_opts(&self.0.layout).timeout_ms);
        let t0 = Instant::now();
        let reply = self.0.llm.ask(task.system, &user, &schema, timeout);
        let ms = t0.elapsed().as_millis() as u64;
        if let Some(status) = reply.status {
            let line = usage::Line::local(LocalTime::now(), task.name, &spec.id, status, ms, reply.input_tokens, reply.output_tokens);
            let _g = self.0.usage_lock.lock().unwrap_or_else(|e| e.into_inner());
            if let Err(e) = usage::append(&self.0.layout.usage_file(), &line) {
                self.log(&format!("usage.jsonl: {e}"));
            }
        }
        let result = reply.result.and_then(|labels| match schema::validate(&schema, &labels) {
            Ok(()) => Ok(labels),
            Err(_) => Err(Fail::Malformed),
        });
        match result {
            Ok(labels) => {
                self.log(&format!("local {} {ms} ms", task.name));
                Ok(Answer { contract: CONTRACT, labels, confidence: 0.8, tier: "model", why: format!("model:{}", task.schema_id()) })
            }
            Err(Fail::Malformed) => {
                let n = {
                    let mut g = self.lock();
                    g.malformed += 1;
                    g.malformed
                };
                self.log(&format!("malformed model answer for {} (total {n})", task.name));
                Err(self.unavailable("malformed"))
            }
            // Slow is not dead: the server keeps its slot and stays loaded.
            Err(Fail::Timeout) => {
                self.log(&format!("local {} timeout after {ms} ms", task.name));
                Err(self.unavailable("timeout"))
            }
            Err(Fail::Other(e)) if !self.dead_soon() => {
                self.log(&format!("local {} error: {e}", task.name));
                Err(self.unavailable("remote error"))
            }
            Err(Fail::Other(e)) => {
                let now = self.0.clock.now_ms();
                self.0.llm.stop();
                self.lock().life.load_failed(now);
                self.log(&format!("llama-server died: {e}"));
                Err(self.unavailable("crash"))
            }
        }
    }

    /// After a failed call: is llama-server gone? A process that dropped the
    /// connection may take a moment to be reaped, so ask for up to 200 ms.
    fn dead_soon(&self) -> bool {
        for _ in 0..10 {
            if !self.0.llm.alive() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }

    /// Wait (bounded) for a running load. `Ok` when the model is Hot.
    fn wait_hot(&self) -> Result<(), Unavailable> {
        let deadline = Instant::now() + self.0.tuning.load_wait;
        let mut g = self.lock();
        while g.life.state == State::Loading {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            g = self.0.cv.wait_timeout(g, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        let note = match g.life.state {
            State::Hot => return Ok(()),
            State::Loading => "loading",
            _ => "load failed",
        };
        Err(Unavailable { state: g.life.state.name(), note: note.into() })
    }

    fn do_load(&self) {
        let spec = self.lock().spec.clone();
        let gpu = self.gpu();
        self.log(&format!("load start{}", if gpu { " (gpu)" } else { "" }));
        let t0 = Instant::now();
        let r = match (spec, self.0.layout.llama_exe(gpu)) {
            (Some(s), Some(exe)) => self.0.llm.start(&exe, &launch_args(&self.model_path(&s), &s, gpu, threads())),
            (None, _) => Err("no model".into()),
            (_, None) => Err("llama-server is not installed".into()),
        };
        let now = self.0.clock.now_ms();
        let mut g = self.lock();
        match r {
            Ok(()) => {
                self.log(&format!("load ready {} ms", t0.elapsed().as_millis()));
                g.life.load_ok(now);
            }
            Err(e) => {
                self.log(&format!("load failed: {e}"));
                g.life.load_failed(now);
            }
        }
        self.0.cv.notify_all();
    }

    /// `/install {model}`: make `id` the choice (writes `brain.json`
    /// `local.model`, which swaps out any other GGUF), then fetch the pinned
    /// llama-server and GGUF in a thread. Returns at once; `/health` shows
    /// the progress.
    pub fn install(&self, id: &str) -> Result<Install, InstallErr> {
        let Some(spec) = self.0.manifest.models.iter().find(|m| m.id == id).cloned() else {
            return Err(InstallErr::Unknown(self.0.manifest.models.iter().map(|m| m.id.clone()).collect()));
        };
        if let Some(running) = self.lock().installing.clone() {
            return Ok(Install::Joined(running));
        }
        if config::pick_model(&self.0.layout, &self.0.manifest).map(|s| s.id) != Some(spec.id.clone()) {
            config::set_local_model(&self.0.layout, &spec.id)
                .map_err(|e| InstallErr::Refused(self.unavailable(&format!("brain.json: {e}"))))?;
        }
        self.refresh_model();
        let gpu = self.gpu();
        let mut g = self.lock();
        if let Some(running) = &g.installing {
            return Ok(Install::Joined(running.clone()));
        }
        let refused = |g: &Inner, note: &str| InstallErr::Refused(Unavailable { state: g.life.state.name(), note: note.into() });
        if g.spec.as_ref().map(|s| s.id.as_str()) != Some(id) {
            // A load still holds the old model; the swap runs once it ends.
            return Err(refused(&g, "busy"));
        }
        if self.present(&spec) {
            if g.life.state == State::Absent {
                g.life.go_cold(true);
            }
            return Ok(Install::Present { model: spec.id, state: g.life.state.name() });
        }
        if self.0.mem.disk_free(&self.0.layout.dir).is_some_and(|d| d < MIN_DISK) {
            return Err(refused(&g, "disk"));
        }
        g.installing = Some(spec.id.clone());
        g.dl_pct = Some(0);
        g.dl_note = None;
        g.life.download_start();
        drop(g);
        let me = self.clone();
        std::thread::spawn(move || me.do_install(spec, gpu));
        Ok(Install::Started(id.to_string()))
    }

    /// Up to `DL_STRIKES` attempts; a `.part` left by a short read resumes, a
    /// hash mismatch deletes it and starts over.
    fn do_install(&self, spec: ModelSpec, gpu: bool) {
        let mut last = String::new();
        let mut ok = false;
        for strike in 1..=DL_STRIKES {
            match self.install_files(&spec, gpu) {
                Ok(()) => {
                    ok = true;
                    break;
                }
                Err(e) => {
                    self.log(&format!("install {} strike {strike}: {e}", spec.id));
                    last = e;
                }
            }
        }
        if ok {
            self.log(&format!("install {} done", spec.id));
        }
        let present = self.present(&spec);
        let mut g = self.lock();
        g.installing = None;
        g.dl_pct = None;
        g.dl_note = (!ok).then(|| format!("download failed: {last}"));
        g.life.download_done(present);
        self.0.cv.notify_all();
    }

    /// The server pin for this target: `<target>-vulkan` with `gpu` when the
    /// catalogue has one (else the plain build, which on macOS already uses Metal).
    fn server_pin(&self, gpu: bool) -> Option<config::Pinned> {
        let t = config::server_target();
        let s = &self.0.manifest.server;
        gpu.then(|| s.get(&format!("{t}-vulkan"))).flatten().or_else(|| s.get(&t)).cloned()
    }

    /// llama-server archive (when that build is not installed) then the GGUF,
    /// both pinned. The archive unpacks into a staging folder that replaces
    /// the server folder only when the whole archive was safe and held the exe.
    fn install_files(&self, spec: &ModelSpec, gpu: bool) -> Result<(), String> {
        let l = &self.0.layout;
        let model = self.model_path(spec);
        let server = match l.llama_exe(gpu) {
            Some(_) => None,
            None => Some(self.server_pin(gpu).ok_or("no server pin for this target")?),
        };
        let total = server.as_ref().map_or(0, |p| p.bytes) + if model.is_file() { 0 } else { spec.bytes };
        let mut base = 0;
        if let Some(pin) = server {
            // Windows ships .zip, macOS and Linux .tar.gz; `unpack_server` picks by suffix.
            let name = if pin.url.ends_with(".zip") { "server.zip" } else { "server.tar.gz" };
            let archive = l.dir.join(name);
            let p = Pin { url: &pin.url, sha256: &pin.sha256, bytes: pin.bytes };
            fetch::get_pinned(&*self.0.source, &p, &archive, &mut |done, _| self.set_pct(done, total))
                .map_err(|e| e.to_string())?;
            let dest = l.server_dir(gpu);
            let stage = l.dir.join(".server-stage");
            let _ = std::fs::remove_dir_all(&stage);
            let unpacked = fetch::unpack_server(&archive, &pin.url, &stage).and_then(|()| {
                let _ = std::fs::remove_dir_all(&dest);
                std::fs::rename(&stage, &dest).map_err(|e| e.to_string())
            });
            // Kept on failure it would be "present" for the next strike and fail the same way.
            let _ = std::fs::remove_file(&archive);
            let _ = std::fs::remove_dir_all(&stage);
            unpacked?;
            base = pin.bytes;
        }
        let p = Pin { url: &spec.url, sha256: &spec.sha256, bytes: spec.bytes };
        fetch::get_pinned(&*self.0.source, &p, &model, &mut |done, _| self.set_pct(base + done, total))
            .map_err(|e| e.to_string())
    }

    fn set_pct(&self, done: u64, total: u64) {
        self.lock().dl_pct = Some((done as u128 * 100 / total.max(1) as u128).min(100) as u8);
    }

    /// `{contract, backend, model, state, resources_pct, idle_s, download_pct, note}`.
    pub fn health(&self) -> Value {
        let now = self.0.clock.now_ms();
        let pct = self.0.mem.read().map(|m| if m.total == 0 { 0 } else { (m.free as u128 * 100 / m.total as u128) as u8 });
        let g = self.lock();
        json!({
            "contract": CONTRACT, "backend": "local",
            "model": g.spec.as_ref().map(|s| s.id.clone()),
            "state": g.life.state.name(), "resources_pct": pct,
            "idle_s": g.life.idle_ms(now) / 1000,
            "download_pct": g.dl_pct, "note": g.dl_note,
        })
    }

    /// `/unload`: kill llama-server now, keep the file. No-op unless Hot.
    pub fn unload(&self) -> &'static str {
        let mut g = self.lock();
        if g.life.state == State::Hot {
            self.log("unload (explicit)");
            self.0.llm.stop();
            g.life.go_cold(true);
        }
        g.life.state.name()
    }

    /// Call about once a second: the idle kill, and a dead llama-server
    /// noticed between requests (a crash: one strike).
    pub fn tick(&self) {
        let now = self.0.clock.now_ms();
        let mut g = self.lock();
        if g.life.tick(now, self.0.tuning.idle_ms) == Tick::KillIdle {
            self.log("unload (idle)");
            self.0.llm.stop();
            return;
        }
        if g.life.state == State::Hot && !self.0.llm.alive() {
            self.log("llama-server exited; unloading");
            self.0.llm.stop();
            g.life.load_failed(now);
        }
    }

    pub fn shutdown(&self) {
        self.0.llm.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem(free_mb: u64, total_mb: u64) -> Option<Mem> {
        Some(Mem { free: free_mb * MB, total: total_mb * MB })
    }
    const GB: u64 = 1024 * MB;

    #[test]
    fn guard_needs_gguf_times_1_15_plus_300mb_plus_reserve() {
        // 1 GiB model: need = 1.15 GiB + 300 MiB + 1 GiB reserve = 2501.6 MiB.
        assert_eq!(ram_guard(mem(4000, 16384), GB), Guard::Ok);
        // The same on a small box: the reserve is fixed, not a share of total.
        assert_eq!(ram_guard(mem(2600, 4096), GB), Guard::Ok);
        // Below the raw need.
        assert_eq!(ram_guard(mem(1400, 16384), GB), Guard::Defer { pct: 8 });
    }

    #[test]
    fn guard_keeps_a_fixed_gib_free_after_load() {
        // Enough to load (1478 MiB) but under the 1 GiB reserve on top: 2400 < 2502.
        assert_eq!(ram_guard(mem(2400, 8192), GB), Guard::Defer { pct: 29 });
        // Just over the line: 2510 free leaves >= 1 GiB.
        assert_eq!(ram_guard(mem(2510, 8192), GB), Guard::Ok);
    }

    #[test]
    fn guard_thresholds_of_the_pinned_models() {
        // Phi-4-mini Q4_K_M, 2,491,874,272 bytes: about 4.0 GiB free.
        assert_eq!(ram_need(2_491_874_272), 4_253_970_036);
        // Llama 3.2 1B, 807,694,464 bytes: about 2.2 GiB free.
        assert_eq!(ram_need(807_694_464), 2_317_163_257);
    }

    #[test]
    fn guard_reports_the_percentage_for_the_line() {
        match ram_guard(mem(1000, 8192), 2 * GB) {
            Guard::Defer { pct } => assert_eq!(pct, 12),
            g => panic!("{g:?}"),
        }
    }

    #[test]
    fn guard_without_a_reading_allows() {
        assert_eq!(ram_guard(None, 10 * GB), Guard::Ok);
    }

    fn spec(args: &[&str]) -> ModelSpec {
        ModelSpec {
            id: "m".into(),
            file: "m.gguf".into(),
            url: "u".into(),
            sha256: "0".into(),
            bytes: 1,
            ram_mb: None,
            args: args.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn launch_args_cap_memory_and_add_gpu_layers_only_on_request() {
        let g = Path::new("m.gguf");
        let cpu = launch_args(g, &spec(&[]), false, 4).join(" ");
        assert_eq!(cpu, "-m m.gguf -c 4096 -np 1 --cache-ram 0 -t 4 --no-webui --jinja");
        let gpu = launch_args(g, &spec(&["-rea", "off"]), true, 4).join(" ");
        assert_eq!(gpu, "-m m.gguf -c 4096 -np 1 --cache-ram 0 -t 4 --no-webui --jinja -ngl 99 -rea off");
    }

    const BIG: Option<Mem> = Some(Mem { free: 32 * GB, total: 64 * GB });

    fn hot(l: &mut Lifecycle, at: u64) {
        assert_eq!(l.on_request(at, true, BIG, GB), Plan::Load);
        l.load_ok(at);
    }

    #[test]
    fn cold_load_then_serve_then_idle_kill_at_ten_minutes() {
        let mut l = Lifecycle::new(true);
        hot(&mut l, 1_000);
        assert_eq!(l.on_request(5_000, true, BIG, GB), Plan::Serve);
        // last_use is now 5_000: 10 min later minus 1 ms is still alive.
        assert_eq!(l.tick(5_000 + IDLE_MS - 1, IDLE_MS), Tick::Nothing);
        assert_eq!(l.state, State::Hot);
        assert_eq!(l.tick(5_000 + IDLE_MS, IDLE_MS), Tick::KillIdle);
        assert_eq!(l.state, State::Cold);
        assert_eq!(l.tick(5_000 + IDLE_MS + 1, IDLE_MS), Tick::Nothing, "already cold");
    }

    #[test]
    fn use_resets_the_idle_timer() {
        let mut l = Lifecycle::new(true);
        hot(&mut l, 0);
        for k in 1..=5u64 {
            let t = k * (IDLE_MS - 1000);
            assert_eq!(l.tick(t, IDLE_MS), Tick::Nothing);
            assert_eq!(l.on_request(t, true, BIG, GB), Plan::Serve);
        }
    }

    #[test]
    fn deferral_announces_once_per_ten_minutes_and_retries_after_a_minute() {
        let mut l = Lifecycle::new(true);
        let low = mem(500, 8192);
        assert_eq!(l.on_request(0, true, low, GB), Plan::Defer { announce: true });
        assert_eq!(l.state, State::Deferred);
        // Inside the 60 s window: no re-check, silent.
        assert_eq!(l.on_request(30_000, true, low, GB), Plan::Defer { announce: false });
        // After 60 s the guard is asked again; still low, but the line is not due.
        assert_eq!(l.on_request(61_000, true, low, GB), Plan::Defer { announce: false });
        // After 10 min the line is due again.
        assert_eq!(l.on_request(DEFER_LINE_MS + 1, true, low, GB), Plan::Defer { announce: true });
        // Memory comes back: load.
        assert_eq!(l.on_request(DEFER_LINE_MS + 200_000, true, BIG, GB), Plan::Load);
    }

    #[test]
    fn three_failed_loads_back_off_ten_minutes() {
        let mut l = Lifecycle::new(true);
        for i in 0..3u64 {
            assert_eq!(l.on_request(i * 1000, true, BIG, GB), Plan::Load);
            l.load_failed(i * 1000);
            assert_eq!(l.state, State::Cold);
        }
        assert_eq!(l.on_request(3_000, true, BIG, GB), Plan::Backoff);
        assert_eq!(l.on_request(2_000 + LOAD_BACKOFF_MS - 1, true, BIG, GB), Plan::Backoff);
        assert_eq!(l.on_request(2_000 + LOAD_BACKOFF_MS, true, BIG, GB), Plan::Load);
    }

    #[test]
    fn a_success_clears_the_strikes() {
        let mut l = Lifecycle::new(true);
        for _ in 0..2 {
            assert_eq!(l.on_request(0, true, BIG, GB), Plan::Load);
            l.load_failed(0);
        }
        assert_eq!(l.on_request(0, true, BIG, GB), Plan::Load);
        l.load_ok(0);
        l.go_cold(true);
        assert_eq!(l.on_request(1, true, BIG, GB), Plan::Load);
        l.load_failed(1);
        assert_eq!(l.on_request(2, true, BIG, GB), Plan::Load, "one strike, not three");
    }

    #[test]
    fn requests_during_loading_wait() {
        let mut l = Lifecycle::new(true);
        assert_eq!(l.on_request(0, true, BIG, GB), Plan::Load);
        assert_eq!(l.on_request(1, true, BIG, GB), Plan::Wait);
    }

    #[test]
    fn an_absent_model_is_absent_until_an_install_fetches_it() {
        let mut l = Lifecycle::new(false);
        assert_eq!(l.state, State::Absent);
        assert_eq!(l.on_request(0, false, BIG, GB), Plan::Absent);
        assert_eq!(l.on_request(1, false, BIG, GB), Plan::Absent, "a request never starts a download");
        l.download_start();
        assert_eq!(l.on_request(2, false, BIG, GB), Plan::Downloading);
        l.download_done(false);
        assert_eq!(l.state, State::Absent);
        l.download_start();
        l.download_done(true);
        assert_eq!(l.state, State::Cold);
        assert_eq!(l.on_request(3, true, BIG, GB), Plan::Load);
    }
}
