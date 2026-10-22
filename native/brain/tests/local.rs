//! Tier 0: the `local` backend. Three rigs, none of which leaves 127.0.0.1:
//!
//! - `Rig`: the supervisor over `testutil::FakeLlm` and a `ManualClock`, so
//!   every lifecycle transition (lazy load, idle kill, RAM guard, strikes,
//!   crash, timeout) runs in microseconds.
//! - `Real`: the real `proc::ProcLlama` launching `fake-llama-server` (a
//!   test-only bin of this crate, copied in as `server/llama-server(.exe)`):
//!   flags on its command line, an answer over HTTP, a slow answer that is
//!   not a crash, a process that dies mid-call, the idle kill of a real
//!   process, the RAM guard before a spawn.
//! - `/install` against `testutil::FileServer`, a local HTTP file server,
//!   through the real `fetch::HttpSource`: sha256, three strikes, `.part`
//!   resume over `Range`, zip and tar.gz unpack, zip-slip refused, the swap.
//!
//! The shipped `manifest.json` is only parsed; nothing it pins is fetched.

use chatq_brain::api::{Answer, ClassifyReq};
use chatq_brain::catalogue;
use chatq_brain::config::{self, Layout, Manifest, ModelSpec, Pinned};
use chatq_brain::engine::{ClassifyErr, Engine, Unavailable};
use chatq_brain::fetch::{sha256_bytes, HttpSource};
use chatq_brain::llm;
use chatq_brain::proc::ProcLlama;
use chatq_brain::server;
use chatq_brain::supervisor::{Clock, Local, ManualClock, SystemClock, Tuning, DL_STRIKES, IDLE_MS, MB, MIN_DISK};
use chatq_brain::sysinfo::Mem;
use chatq_brain::testutil::{tmpdir, FakeLlm, FileServer, FixedMem};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ------------------------------------------------------------ shared

struct Live {
    h: server::Handle,
}

impl Live {
    fn new(engine: Engine) -> Live {
        Live { h: server::start(engine, "tok123".into(), 0).unwrap() }
    }
    fn ok(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build();
        let req = agent.request(method, &format!("http://127.0.0.1:{}{path}", self.h.port)).set("Authorization", "Bearer tok123");
        let res = match body {
            Some(b) => req.send_json(b),
            None => req.call(),
        };
        let (c, s) = match res {
            Ok(r) => (r.status(), r.into_string().unwrap()),
            Err(ureq::Error::Status(c, r)) => (c, r.into_string().unwrap()),
            Err(e) => panic!("transport: {e}"),
        };
        (c, serde_json::from_str(&s).unwrap_or(Value::Null))
    }
}

fn req(task: &str, schema_id: &str, tool_out: &str, turns: &[(&str, &str)]) -> Value {
    json!({
        "task": task, "schema_id": schema_id,
        "transcript_tail": {
            "chat": "c1",
            "turns": turns.iter().map(|(r, t)| json!({"role": r, "text": t})).collect::<Vec<_>>(),
            "tool_out": tool_out,
        }
    })
}

fn route(engine: &Engine, method: &str, path: &str, body: Value) -> (u16, Value) {
    let (c, v) = server::route(engine, "t", method, path, Some("Bearer t"), body.to_string().as_bytes());
    (c, v.unwrap_or(Value::Null))
}

const SECRET_TEXT: &str = "the purple elephant refactor";

fn unread() -> ClassifyReq {
    serde_json::from_value(unread_json()).unwrap()
}

fn unread_json() -> Value {
    req("unread_reply", "unread_reply@1", "", &[("assistant", &format!("Should I do {SECRET_TEXT}?")), ("user", "ok")])
}

fn valid_unread() -> Value {
    json!({"asked": true, "answered": true, "question": "Should I go on?"})
}

fn unavailable(r: Result<Answer, ClassifyErr>) -> Unavailable {
    match r {
        Err(ClassifyErr::Unavailable(u)) => u,
        other => panic!("want 503, got {other:?}"),
    }
}

/// The 503 body: `{contract, state, note}` and nothing else, no labels.
fn assert_503(engine: &Engine, state: &str, note: &str) {
    let (c, v) = route(engine, "POST", "/classify", unread_json());
    assert_eq!(c, 503, "{v}");
    assert_eq!(v, json!({"contract": 1, "state": state, "note": note}));
}

fn exe_name() -> &'static str {
    config::server_exe_name()
}

fn log(dir: &Path) -> String {
    std::fs::read_to_string(Layout::new(dir).log_file()).unwrap_or_default()
}

fn usage_lines(dir: &Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join("usage.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn spec(id: &str, file: &str, url: &str, data: &[u8]) -> ModelSpec {
    ModelSpec {
        id: id.into(),
        file: file.into(),
        url: url.into(),
        sha256: sha256_bytes(data),
        bytes: data.len() as u64,
        ram_mb: None,
        args: Vec::new(),
    }
}

fn pinned(url: String, data: &[u8]) -> Pinned {
    Pinned { url, sha256: sha256_bytes(data), bytes: data.len() as u64 }
}

/// Until `/health` leaves `downloading`; the body it ends on.
fn wait_installed(engine: &Engine) -> Value {
    let t0 = Instant::now();
    loop {
        let h = engine.health();
        if h["state"] != "downloading" {
            return h;
        }
        assert!(t0.elapsed() < Duration::from_secs(20), "install never ended: {h}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

// ------------------------------------------------------------ the shipped pins

#[test]
fn the_shipped_manifest_parses_with_the_real_reader() {
    let m = config::load_manifest(&Layout::new(tmpdir("manifest-builtin")));
    assert_eq!(m.default.as_deref(), Some("phi-4-mini-q4km"), "Phi-4-mini Q4_K_M is the default");
    assert_eq!(config::pick_model(&Layout::new(tmpdir("manifest-pick")), &m).unwrap().id, "phi-4-mini-q4km");
    let ids: Vec<&str> = m.models.iter().map(|s| s.id.as_str()).collect();
    let mut uniq = ids.clone();
    uniq.sort();
    uniq.dedup();
    assert_eq!(uniq.len(), ids.len(), "ids are unique: {ids:?}");
    let hex64 = |s: &str| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase());
    let commit = |url: &str| {
        let c = url.split("/resolve/").nth(1).and_then(|r| r.split('/').next()).unwrap_or("");
        c.len() == 40 && c.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    };
    for s in &m.models {
        assert!(hex64(&s.sha256) && s.bytes > 0 && s.url.starts_with("https://huggingface.co/"), "{}", s.id);
        assert!(commit(&s.url), "{}: pinned to a commit, not a branch", s.id);
        assert!(s.url.ends_with(&s.file) && s.file.ends_with(".gguf"), "{}", s.id);
        assert!(s.ram_mb.unwrap() * MB > s.bytes, "{}: ram_mb under the weights", s.id);
    }
    // The Qwen3 thinking models turn reasoning off; the rest need no flags.
    for s in &m.models {
        let want: &[&str] = if s.id.starts_with("qwen3.5-") || s.id == "qwen3-1.7b-q4km" { &["-rea", "off"] } else { &[] };
        assert_eq!(s.args, want, "{}", s.id);
    }
    let win = m.server.get("windows-x86_64").expect("a Windows server pin");
    assert!(win.url.ends_with(".zip"), "the Windows build is a zip");
    assert!(m.server.contains_key("windows-x86_64-vulkan"), "the GPU opt-in has a pin");
    for (k, p) in &m.server {
        assert!(p.url.ends_with(".zip") || p.url.ends_with(".tar.gz"), "{k}: unpack_server reads .zip and .tar.gz");
        assert!(hex64(&p.sha256) && p.bytes > 0 && p.url.starts_with("https://github.com/ggml-org/llama.cpp/releases/download/b"), "{k}");
    }
    // A data/brain/manifest.json that parses replaces the built-in one; one that does not is ignored.
    let dir = tmpdir("manifest-override");
    std::fs::write(dir.join("manifest.json"), r#"{"default":"x","models":[{"id":"x","file":"x.gguf","url":"u","sha256":"s","bytes":1}]}"#).unwrap();
    assert_eq!(config::load_manifest(&Layout::new(&dir)).models.len(), 1);
    std::fs::write(dir.join("manifest.json"), "not json").unwrap();
    assert_eq!(config::load_manifest(&Layout::new(&dir)).models.len(), m.models.len());
}

// ------------------------------------------------------------ Rig: FakeLlm

const MODEL: &str = "m.gguf";
const DATA: &[u8] = b"gguf bytes";

struct Rig {
    dir: PathBuf,
    engine: Engine,
    llm: Arc<FakeLlm>,
    clock: Arc<ManualClock>,
    mem: Arc<FixedMem>,
    files: FileServer,
}

impl Rig {
    /// Requests the file server saw for `name`, with their `Range` starts.
    fn fetches(&self, name: &str) -> Vec<u64> {
        self.files.requests().into_iter().filter(|(n, _)| n == name).map(|(_, from)| from).collect()
    }
}

/// An empty `llama-server(.exe)`: "installed" for `FakeLlm`, never run.
fn fake_server(dir: &Path, gpu: bool) {
    let d = Layout::new(dir).server_dir(gpu);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join(exe_name()), b"").unwrap();
}

/// The engine over `dir`, whose files must already be in place.
fn build(dir: PathBuf, manifest: Manifest, answer: Value, mem: FixedMem, files: FileServer) -> Rig {
    let llm = Arc::new(FakeLlm::new(answer));
    let clock = Arc::new(ManualClock::default());
    let mem = Arc::new(mem);
    let layout = Layout::new(&dir);
    let local = Local::new(
        layout.clone(),
        manifest,
        clock.clone(),
        mem.clone(),
        llm.clone(),
        Arc::new(HttpSource::new().unwrap()),
        Tuning { load_wait: Duration::from_secs(5), idle_ms: IDLE_MS },
    );
    Rig { dir, engine: Engine::local(layout, local), llm, clock, mem, files }
}

/// Model `m` served by a local file server; llama-server "installed";
/// `with_file`: the GGUF is on disk.
fn rig(name: &str, with_file: bool, answer: Value) -> Rig {
    let dir = tmpdir(name);
    let files = FileServer::start();
    let url = files.put(MODEL, DATA);
    let manifest = Manifest { default: Some("m".into()), models: vec![spec("m", MODEL, &url, DATA)], ..Default::default() };
    fake_server(&dir, false);
    if with_file {
        std::fs::write(dir.join(MODEL), DATA).unwrap();
    }
    build(dir, manifest, answer, FixedMem::new(6000, 16384), files)
}

#[test]
fn health_shape_of_the_local_backend() {
    let r = rig("loc-health", true, valid_unread());
    assert_eq!(
        r.engine.health(),
        json!({"contract": 1, "backend": "local", "model": "m", "state": "cold", "resources_pct": 36,
               "idle_s": 0, "download_pct": null, "note": null})
    );
    r.engine.classify(&unread()).unwrap();
    r.clock.advance(5_000);
    let h = route(&r.engine, "GET", "/health", Value::Null).1;
    assert_eq!((&h["state"], &h["idle_s"]), (&json!("hot"), &json!(5)));
}

#[test]
fn model_tier_loads_lazily_answers_then_idles_out() {
    let r = rig("loc-idle", true, valid_unread());
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 0, "nothing loads at startup");
    let a = r.engine.classify(&unread()).unwrap();
    assert_eq!((a.tier, &a.labels, a.why.as_str()), ("model", &valid_unread(), "model:unread_reply@1"));
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 1);
    assert_eq!(r.engine.health()["state"], "hot");

    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 1, "no second load while hot");

    r.clock.advance(IDLE_MS - 1);
    r.engine.tick();
    assert_eq!(r.engine.health()["state"], "hot");
    r.clock.advance(1);
    r.engine.tick();
    assert_eq!(r.engine.health()["state"], "cold");
    assert!(!r.llm.alive.load(Ordering::SeqCst), "llama-server was killed");
    assert!(log(&r.dir).contains("unload (idle)"));

    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 2, "reloaded on the next request");
}

#[test]
fn launch_flags_cap_memory_and_gpu_is_opt_in() {
    let r = rig("loc-flags", true, valid_unread());
    r.engine.classify(&unread()).unwrap();
    let (exe, args) = r.llm.last_start.lock().unwrap().clone().unwrap();
    assert_eq!(exe, r.dir.join("server").join(exe_name()));
    let a = args.join(" ");
    assert!(a.starts_with(&format!("-m {}", r.dir.join(MODEL).display())), "{a}");
    for f in ["-c 4096", "-np 1", "--cache-ram 0", "--no-webui", "--jinja"] {
        assert!(a.contains(f), "{f} in {a}");
    }
    assert!(!a.contains("-ngl"), "CPU unless brain.json asks: {a}");

    // "gpu": true wants the GPU build in server-gpu/ and offloads every layer.
    std::fs::write(r.dir.join("brain.json"), r#"{"backend":"local","local":{"gpu":true}}"#).unwrap();
    r.engine.local_backend().unwrap().unload();
    assert_503(&r.engine, "absent", "not installed");
    fake_server(&r.dir, true);
    r.engine.classify(&unread()).unwrap();
    let (exe, args) = r.llm.last_start.lock().unwrap().clone().unwrap();
    assert_eq!(exe, r.dir.join("server-gpu").join(exe_name()));
    assert!(args.join(" ").contains("-ngl 99"), "{args:?}");
}

#[test]
fn unload_kills_llama_and_keeps_the_file() {
    let r = rig("loc-unload", true, valid_unread());
    assert_eq!(route(&r.engine, "POST", "/unload", json!({})), (200, json!({"contract": 1, "state": "cold"})), "a no-op when cold");
    r.engine.classify(&unread()).unwrap();
    assert_eq!(route(&r.engine, "POST", "/unload", json!({})), (200, json!({"contract": 1, "state": "cold"})));
    assert!(!r.llm.alive.load(Ordering::SeqCst));
    assert!(r.dir.join(MODEL).exists());
    assert!(log(&r.dir).contains("unload (explicit)"));
}

#[test]
fn brain_log_gets_a_line_for_a_deferral_a_load_a_503_and_an_unload() {
    let r = rig("loc-log", true, valid_unread());
    r.mem.set_free_mb(200);
    assert_503(&r.engine, "deferred", "announce");
    let text = log(&r.dir);
    assert!(text.contains("defer free=209715200 need="), "{text}");
    assert!(text.contains("503 unread_reply deferred announce"), "{text}");

    r.mem.set_free_mb(9000);
    r.clock.advance(61_000);
    r.engine.classify(&unread()).unwrap();
    let text = log(&r.dir);
    assert!(text.contains("load start") && text.contains("load ready "), "{text}");
    assert!(text.contains("local unread_reply "), "{text}");

    r.engine.local_backend().unwrap().unload();
    let text = log(&r.dir);
    assert!(text.contains("unload (explicit)"), "{text}");
    assert!(!text.contains(SECRET_TEXT) && !text.contains("purple") && !text.contains("Should I go on?"), "no transcript text or labels");
}

#[test]
fn a_dead_llama_server_noticed_by_tick_unloads() {
    let r = rig("loc-tick-dead", true, valid_unread());
    r.engine.classify(&unread()).unwrap();
    r.llm.alive.store(false, Ordering::SeqCst); // died behind our back
    r.clock.advance(1_000);
    r.engine.tick();
    assert_eq!(r.engine.health()["state"], "cold");
    assert!(log(&r.dir).contains("llama-server exited; unloading"));
    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 2);
}

#[test]
fn regex_tasks_never_touch_the_model() {
    let r = rig("loc-regex", true, valid_unread());
    let q: ClassifyReq = serde_json::from_value(req("extract", "extract@1", "", &[("user", "go")])).unwrap();
    assert_eq!(r.engine.classify(&q).unwrap().tier, "regex");
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 0);
}

#[test]
fn fail_kind_escalates_only_when_regex_found_none_but_the_output_has_an_error() {
    let answer = json!({"kind": "build", "n": null, "file": null, "tool": null, "attempt": null});
    let r = rig("loc-escalate", true, answer.clone());
    let cue: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "pytest: 3 failed", &[])).unwrap();
    assert_eq!(r.engine.classify(&cue).unwrap().tier, "regex");
    let clean: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "all good", &[])).unwrap();
    assert_eq!(r.engine.classify(&clean).unwrap().tier, "regex");
    assert_eq!(r.llm.asks.load(Ordering::SeqCst), 0);
    let murky: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "something printed Error: odd", &[])).unwrap();
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!((a.tier, a.labels), ("model", answer));
}

#[test]
fn fail_kind_answers_from_regex_with_no_model_and_starts_no_download() {
    let r = rig("loc-failkind-absent", false, valid_unread());
    assert_eq!(r.engine.health()["state"], "absent");
    let (c, v) = route(&r.engine, "POST", "/classify", req("fail_kind", "fail_kind@1", "pytest: 3 failed", &[]));
    assert_eq!((c, &v["tier"], &v["labels"]["kind"]), (200, &json!("regex"), &json!("tests")));
    // The escalation case: the model cannot run, so the regex answer stands.
    let (c, v) = route(&r.engine, "POST", "/classify", req("fail_kind", "fail_kind@1", "printed Error: odd", &[]));
    assert_eq!((c, &v["tier"], &v["labels"]["kind"]), (200, &json!("regex"), &json!("none")));
    assert!(r.files.requests().is_empty());
    assert_eq!(r.engine.health()["state"], "absent");
}

#[test]
fn every_model_task_on_an_absent_model_is_503_and_starts_no_download() {
    let r = rig("loc-absent", false, valid_unread());
    assert_503(&r.engine, "absent", "not installed");
    for t in catalogue::TASKS.iter().filter(|t| t.model_tier) {
        let (c, v) = route(&r.engine, "POST", "/classify", req(t.name, &t.schema_id(), "", &[("user", "x")]));
        assert_eq!(c, 503, "{}", t.name);
        assert!(v.get("labels").is_none() && v.get("tier").is_none(), "{}: {v}", t.name);
    }
    assert!(r.files.requests().is_empty(), "no download");
    assert!(!r.dir.join(MODEL).exists() && !r.dir.join("m.gguf.part").exists());
    let h = r.engine.health();
    assert_eq!((&h["state"], &h["download_pct"]), (&json!("absent"), &Value::Null));
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 0);
}

#[test]
fn a_malformed_model_answer_is_503_with_no_labels() {
    let r = rig("loc-malformed", true, json!({"asked": "maybe"}));
    assert_503(&r.engine, "hot", "malformed");
    assert!(log(&r.dir).contains("malformed model answer for unread_reply (total 1)"));
}

#[test]
fn a_ram_guard_deferral_is_503_then_loads_when_memory_returns() {
    let r = rig("loc-guard", true, valid_unread());
    r.mem.set_free_mb(200);
    assert_503(&r.engine, "deferred", "announce");
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 0);
    assert_503(&r.engine, "deferred", "quiet"); // one line per 10 minutes
    assert_eq!(r.engine.health()["resources_pct"], 1, "the percentage for the line is on /health");
    r.mem.set_free_mb(9000);
    assert_503(&r.engine, "deferred", "quiet"); // the retry waits a minute
    r.clock.advance(61_000);
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
}

#[test]
fn three_failed_loads_then_ten_minutes_of_503() {
    let r = rig("loc-strikes", true, valid_unread());
    r.llm.fail_start.store(true, Ordering::SeqCst);
    for _ in 0..3 {
        let u = unavailable(r.engine.classify(&unread()));
        assert_eq!((u.state, u.note.as_str()), ("cold", "load failed"));
    }
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 3);
    let u = unavailable(r.engine.classify(&unread()));
    assert_eq!((u.state, u.note.as_str()), ("cold", "backoff"));
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 3, "no fourth attempt inside the backoff");
    r.llm.fail_start.store(false, Ordering::SeqCst);
    r.clock.advance(10 * 60_000);
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
}

#[test]
fn a_killed_llama_server_is_503_crash_then_reloads() {
    let r = rig("loc-crash", true, valid_unread());
    r.engine.classify(&unread()).unwrap();
    r.llm.alive.store(false, Ordering::SeqCst); // killed between the tick and the call
    assert_503(&r.engine, "cold", "crash");
    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 2);
}

#[test]
fn a_slow_answer_is_503_timeout_and_the_model_stays_loaded() {
    let r = rig("loc-slow", true, valid_unread());
    r.llm.slow.store(true, Ordering::SeqCst);
    assert_503(&r.engine, "hot", "timeout");
    assert_503(&r.engine, "hot", "timeout");
    assert_eq!((r.llm.starts.load(Ordering::SeqCst), r.llm.stops.load(Ordering::SeqCst)), (1, 0), "slow is not a crash");
    r.llm.slow.store(false, Ordering::SeqCst);
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
    assert_eq!(r.llm.starts.load(Ordering::SeqCst), 1);
    assert!(usage_lines(&r.dir).len() == 1, "a timeout has no response, so no usage line");
}

#[test]
fn local_usage_lines_carry_tokens_at_zero_cost_and_usage_totals_them() {
    let r = rig("loc-usage", true, valid_unread());
    r.engine.classify(&unread()).unwrap();
    r.engine.classify(&unread()).unwrap();
    let lines = usage_lines(&r.dir);
    assert_eq!(lines.len(), 2);
    let l = &lines[0];
    let mut keys: Vec<&str> = l.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(
        keys,
        ["cached_tokens", "cost_usd", "input_tokens", "model", "ms", "output_tokens", "status", "task", "thought_tokens", "ts"],
        "the Gemini line's keys: the overlay reads one shape"
    );
    assert_eq!((&l["task"], &l["model"], &l["status"]), (&json!("unread_reply"), &json!("m"), &json!(200)));
    assert_eq!((&l["input_tokens"], &l["output_tokens"], &l["cost_usd"]), (&json!(100), &json!(10), &json!(0.0)));
    let text = std::fs::read_to_string(r.dir.join("usage.jsonl")).unwrap();
    assert!(!text.contains(SECRET_TEXT) && !text.contains("Should I go on?"));
    let (c, v) = route(&r.engine, "GET", "/usage", Value::Null);
    assert_eq!(c, 200);
    assert_eq!((&v["contract"], &v["model"], &v["note"]), (&json!(1), &json!("m"), &Value::Null), "a local model is never unpriced");
    assert_eq!(
        v["today"],
        json!({"calls": 2, "errors": 0, "input_tokens": 200, "output_tokens": 20, "thought_tokens": 0, "cost_usd": 0.0,
               "by_task": {"unread_reply": {"calls": 2, "cost_usd": 0.0}}})
    );
}

// ------------------------------------------------------------ Real: fake-llama-server

const TINY: &str = "tiny.gguf";

/// The GGUF is the fake server's script; rewritten between calls to change what it does.
fn script(dir: &Path, v: Value) {
    std::fs::write(dir.join(TINY), v.to_string()).unwrap();
}

/// The fake's own record of its command line.
fn launched_args(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join(format!("{TINY}.args"))).unwrap_or_default().lines().map(str::to_string).collect()
}

fn launched_base(dir: &Path) -> Option<String> {
    std::fs::read_to_string(dir.join(format!("{TINY}.port"))).ok().map(|p| format!("http://127.0.0.1:{}", p.trim()))
}

fn loads(dir: &Path) -> usize {
    log(dir).matches("load start").count()
}

struct Real {
    dir: PathBuf,
    engine: Engine,
    mem: Arc<FixedMem>,
}

impl Drop for Real {
    fn drop(&mut self) {
        self.engine.shutdown();
    }
}

/// The real supervisor and `ProcLlama` over a copy of `fake-llama-server`.
fn real(name: &str, brain: Value, first: Value, clock: Arc<dyn Clock>, idle_ms: u64) -> Real {
    let dir = tmpdir(name);
    std::fs::write(dir.join("brain.json"), brain.to_string()).unwrap();
    let layout = Layout::new(&dir);
    let server = layout.server_dir(config::local_opts(&layout).gpu);
    std::fs::create_dir_all(&server).unwrap();
    std::fs::copy(env!("CARGO_BIN_EXE_fake-llama-server"), server.join(exe_name())).unwrap();
    script(&dir, first);
    let data = std::fs::read(dir.join(TINY)).unwrap();
    let manifest = Manifest {
        default: Some("tiny".into()),
        models: vec![spec("tiny", TINY, "http://127.0.0.1:9/never-fetched", &data)],
        ..Default::default()
    };
    let mem = Arc::new(FixedMem::new(64000, 128000));
    let local = Local::new(
        layout.clone(),
        manifest,
        clock,
        mem.clone(),
        Arc::new(ProcLlama::new()),
        Arc::new(HttpSource::new().unwrap()),
        Tuning { load_wait: Duration::from_secs(30), idle_ms },
    );
    Real { dir, engine: Engine::local(layout, local), mem }
}

fn answers(a: Value) -> Value {
    json!({"answer": a})
}

#[test]
fn real_lazy_load_answers_with_the_memory_capped_flags_and_logs_zero_cost_usage() {
    let r = real("real-answer", json!({"backend": "local"}), answers(valid_unread()), Arc::new(SystemClock::new()), IDLE_MS);
    assert_eq!(r.engine.health()["state"], "cold");
    assert!(launched_base(&r.dir).is_none(), "no process before the first model request");
    let (c, v) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!((c, &v["labels"], &v["tier"]), (200, &valid_unread(), &json!("model")), "{v}");
    assert_eq!(r.engine.health()["state"], "hot");
    let args = launched_args(&r.dir);
    let pair = |flag: &str, val: &str| args.windows(2).any(|w| w[0] == flag && w[1] == val);
    assert!(pair("--host", "127.0.0.1"), "{args:?}");
    assert!(pair("-m", &r.dir.join(TINY).display().to_string()), "{args:?}");
    assert!(pair("-c", "4096") && pair("-np", "1") && pair("--cache-ram", "0"), "{args:?}");
    assert!(args.contains(&"--jinja".to_string()) && !args.contains(&"-ngl".to_string()), "{args:?}");

    route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(loads(&r.dir), 1, "one process serves every call");
    let lines = usage_lines(&r.dir);
    assert_eq!(lines.len(), 2);
    for l in &lines {
        assert_eq!((&l["model"], &l["status"], &l["cost_usd"]), (&json!("tiny"), &json!(200), &json!(0.0)));
        assert_eq!((&l["input_tokens"], &l["output_tokens"]), (&json!(123), &json!(9)), "the server's own usage counts");
    }
    let u = route(&r.engine, "GET", "/usage", Value::Null).1;
    assert_eq!((&u["today"]["calls"], &u["today"]["input_tokens"], &u["today"]["cost_usd"]), (&json!(2), &json!(246), &json!(0.0)));
}

#[test]
fn real_gpu_opt_in_launches_the_gpu_build_with_ngl() {
    let r = real("real-gpu", json!({"backend": "local", "local": {"gpu": true}}), answers(valid_unread()), Arc::new(SystemClock::new()), IDLE_MS);
    assert!(r.dir.join("server-gpu").join(exe_name()).is_file() && !r.dir.join("server").exists());
    let (c, v) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(c, 200, "{v}");
    let args = launched_args(&r.dir);
    assert!(args.windows(2).any(|w| w[0] == "-ngl" && w[1] == "99"), "{args:?}");
}

#[test]
fn real_a_slow_answer_is_503_timeout_not_a_crash() {
    let brain = json!({"backend": "local", "local": {"timeout_ms": 300}});
    let r = real("real-slow", brain, answers(valid_unread()), Arc::new(SystemClock::new()), IDLE_MS);
    // Load first so the timing below is the call alone.
    assert_eq!(route(&r.engine, "POST", "/classify", unread_json()).0, 200);
    let base = launched_base(&r.dir).unwrap();
    script(&r.dir, json!({"answer": valid_unread(), "delay_ms": 3000}));
    let t0 = Instant::now();
    assert_503(&r.engine, "hot", "timeout");
    assert!(t0.elapsed() < Duration::from_millis(2800), "gave up at local.timeout_ms, not at the answer");
    assert!(llm::health(&base, Duration::from_secs(1)), "the server was left running");
    assert!(log(&r.dir).contains("local unread_reply timeout after"), "{}", log(&r.dir));
    assert_eq!(usage_lines(&r.dir).len(), 1, "no response, no usage line");
    script(&r.dir, answers(valid_unread()));
    let (c, _) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(c, 200);
    assert_eq!(loads(&r.dir), 1, "the same process answered");
    assert_eq!(launched_base(&r.dir).unwrap(), base);
}

#[test]
fn real_a_process_that_dies_mid_call_is_503_crash_then_reloads() {
    let r = real("real-crash", json!({"backend": "local"}), json!({"die_on_ask": true}), Arc::new(SystemClock::new()), IDLE_MS);
    assert_503(&r.engine, "cold", "crash");
    assert!(log(&r.dir).contains("llama-server died"), "{}", log(&r.dir));
    script(&r.dir, answers(valid_unread()));
    let (c, v) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(c, 200, "{v}");
    assert_eq!(loads(&r.dir), 2, "a fresh process");
}

#[test]
fn real_a_process_that_dies_between_calls_is_unloaded_by_tick() {
    let r = real("real-dies-idle", json!({"backend": "local"}), answers(valid_unread()), Arc::new(SystemClock::new()), IDLE_MS);
    assert_eq!(route(&r.engine, "POST", "/classify", unread_json()).0, 200);
    // The next call kills it; tick, not the call, has to notice when nobody asks.
    script(&r.dir, json!({"die_on_ask": true}));
    let base = launched_base(&r.dir).unwrap();
    let _ = ureq::post(&format!("{base}/v1/chat/completions")).timeout(Duration::from_secs(2)).send_string("{}");
    let t0 = Instant::now();
    while r.engine.health()["state"] == "hot" {
        assert!(t0.elapsed() < Duration::from_secs(10), "tick never noticed");
        r.engine.tick();
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(r.engine.health()["state"], "cold");
    assert!(log(&r.dir).contains("llama-server exited; unloading"));
}

#[test]
fn real_idle_unload_kills_the_process_and_the_next_call_reloads() {
    let r = real("real-idle", json!({"backend": "local"}), answers(valid_unread()), Arc::new(SystemClock::new()), 300);
    assert_eq!(route(&r.engine, "POST", "/classify", unread_json()).0, 200);
    let base = launched_base(&r.dir).unwrap();
    assert!(llm::health(&base, Duration::from_secs(1)));
    r.engine.tick();
    assert_eq!(r.engine.health()["state"], "hot", "not idle yet");
    std::thread::sleep(Duration::from_millis(500));
    r.engine.tick();
    assert_eq!(r.engine.health()["state"], "cold");
    assert!(log(&r.dir).contains("unload (idle)"));
    assert!(!llm::health(&base, Duration::from_millis(500)), "the process is gone");
    assert_eq!(route(&r.engine, "POST", "/classify", unread_json()).0, 200);
    assert_eq!(loads(&r.dir), 2);
}

#[test]
fn real_the_ram_guard_defers_before_any_spawn() {
    let clock = Arc::new(ManualClock::default());
    let r = real("real-guard", json!({"backend": "local"}), answers(valid_unread()), clock.clone(), IDLE_MS);
    r.mem.set_free_mb(500); // under the 300 MB + 1 GiB floor
    assert_503(&r.engine, "deferred", "announce");
    assert_503(&r.engine, "deferred", "quiet");
    assert!(launched_base(&r.dir).is_none(), "nothing was spawned");
    assert!(log(&r.dir).contains("defer free=524288000 need="));
    r.mem.set_free_mb(9000);
    clock.advance(60_001);
    assert_eq!(route(&r.engine, "POST", "/classify", unread_json()).0, 200);
    assert!(launched_base(&r.dir).is_some());
}

// ------------------------------------------------------------ /install over HTTP

fn zip_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut w = zip::ZipWriter::new(std::io::Cursor::new(&mut out));
        let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, body) in entries {
            w.start_file(*name, o).unwrap();
            w.write_all(body).unwrap();
        }
        w.finish().unwrap();
    }
    out
}

fn targz_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut gz = Vec::new();
    {
        let mut b = tar::Builder::new(flate2::write::GzEncoder::new(&mut gz, flate2::Compression::fast()));
        for (name, body) in entries {
            let mut h = tar::Header::new_gnu();
            h.set_size(body.len() as u64);
            h.set_mode(0o755);
            b.append_data(&mut h, name, *body).unwrap();
        }
        b.into_inner().unwrap().finish().unwrap();
    }
    gz
}

/// Model `m` and, with `server`, a llama-server archive under `name`, both
/// served by a fresh file server. No llama-server on disk.
fn install_rig(name: &str, server: Option<(&str, Vec<u8>)>) -> Rig {
    let dir = tmpdir(name);
    let files = FileServer::start();
    let url = files.put(MODEL, DATA);
    let mut manifest = Manifest { default: Some("m".into()), models: vec![spec("m", MODEL, &url, DATA)], ..Default::default() };
    match server {
        Some((archive, bytes)) => {
            manifest.server.insert(config::server_target(), pinned(files.put(archive, &bytes), &bytes));
        }
        None => fake_server(&dir, false),
    }
    build(dir, manifest, valid_unread(), FixedMem::new(6000, 16384), files)
}

#[test]
fn install_downloads_in_the_background_and_health_shows_it() {
    let r = install_rig("inst-bg", None);
    r.files.hold();
    let s = Live::new(r.engine.clone());
    let (c, v) = s.ok("POST", "/install", Some(json!({"model": "m"})));
    assert_eq!((c, v), (202, json!({"contract": 1, "state": "downloading", "model": "m"})));
    let (_, h) = s.ok("GET", "/health", None);
    assert_eq!((&h["state"], &h["download_pct"], &h["note"]), (&json!("downloading"), &json!(0), &Value::Null));
    let (c, v) = s.ok("POST", "/install", Some(json!({"model": "m"})));
    assert_eq!((c, &v["model"]), (202, &json!("m")), "a second /install joins the first");
    let (c, v) = s.ok("POST", "/classify", Some(unread_json()));
    assert_eq!((c, v), (503, json!({"contract": 1, "state": "downloading", "note": "downloading"})));

    r.files.release();
    let h = wait_installed(&r.engine);
    assert_eq!((&h["state"], &h["download_pct"], &h["note"]), (&json!("cold"), &Value::Null, &Value::Null));
    assert_eq!(r.fetches(MODEL), [0], "one fetch for both calls");
    assert_eq!(std::fs::read(r.dir.join(MODEL)).unwrap(), DATA);
    assert!(!r.dir.join("m.gguf.part").exists());
    let (c, v) = s.ok("POST", "/classify", Some(unread_json()));
    assert_eq!((c, &v["tier"]), (200, &json!("model")));
    let (c, v) = s.ok("POST", "/install", Some(json!({"model": "m"})));
    assert_eq!((c, v), (200, json!({"contract": 1, "state": "hot", "model": "m"})), "already installed");
    assert_eq!(r.fetches(MODEL).len(), 1);
}

#[test]
fn install_fetches_the_server_zip_and_flattens_its_folder() {
    let exe = format!("llama-b9999-bin-win-cpu-x64/{}", exe_name());
    let zip = zip_bytes(&[(exe.as_str(), b"MZ"), ("llama-b9999-bin-win-cpu-x64/ggml.dll", b"dll"), ("llama-b9999-bin-win-cpu-x64/LICENSE", b"MIT")]);
    let r = install_rig("inst-zip", Some(("llama.zip", zip)));
    assert_503(&r.engine, "absent", "not installed");
    let (c, _) = route(&r.engine, "POST", "/install", json!({"model": "m"}));
    assert_eq!(c, 202);
    let h = wait_installed(&r.engine);
    assert_eq!((&h["state"], &h["note"]), (&json!("cold"), &Value::Null));
    let server = r.dir.join("server");
    assert_eq!(std::fs::read(server.join(exe_name())).unwrap(), b"MZ");
    assert_eq!(std::fs::read(server.join("ggml.dll")).unwrap(), b"dll", "the dlls sit beside the exe");
    assert!(!server.join("llama-b9999-bin-win-cpu-x64").exists(), "the wrapper folder is gone");
    assert!(!r.dir.join("server.zip").exists() && !r.dir.join(".server-stage").exists());
    assert_eq!(std::fs::read(r.dir.join(MODEL)).unwrap(), DATA);
    assert_eq!(r.files.requests().len(), 2, "archive then model");
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
}

#[test]
fn install_unpacks_a_nested_tar_gz_server_and_a_bad_archive_strikes_out() {
    let exe = format!("build/bin/{}", exe_name());
    let tgz = targz_bytes(&[(exe.as_str(), b"ELF"), ("build/bin/libggml.so", b"so")]);
    let r = install_rig("inst-targz", Some(("llama.tar.gz", tgz)));
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    let h = wait_installed(&r.engine);
    assert_eq!(h["state"], "cold", "{h}");
    assert_eq!(std::fs::read(r.dir.join("server").join(exe_name())).unwrap(), b"ELF");
    assert_eq!(std::fs::read(r.dir.join("server").join("libggml.so")).unwrap(), b"so");
    assert!(!r.dir.join("server").join("build").exists() && !r.dir.join("server.tar.gz").exists());

    // Not an archive at all: every strike fails and the note says why.
    let r = install_rig("inst-badtgz", Some(("llama.tar.gz", b"this is not gzip".to_vec())));
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    let h = wait_installed(&r.engine);
    assert_eq!(h["state"], "absent");
    assert!(h["note"].as_str().unwrap_or("").starts_with("download failed:"), "{h}");
    assert_eq!(r.fetches("llama.tar.gz").len() as u32, DL_STRIKES);
    assert!(!r.dir.join("server.tar.gz").exists(), "a bad archive is not kept for the next strike");
    assert!(r.fetches(MODEL).is_empty(), "no model without a server");
}

#[test]
fn install_refuses_an_archive_that_climbs_out_and_unpacks_nothing() {
    let zip = zip_bytes(&[(exe_name(), b"MZ"), ("../evil.txt", b"pwned"), ("ok/../../evil2.txt", b"pwned")]);
    let r = install_rig("inst-zipslip", Some(("llama.zip", zip)));
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    let h = wait_installed(&r.engine);
    assert_eq!(h["state"], "absent");
    let note = h["note"].as_str().unwrap_or("");
    assert!(note.starts_with("download failed: unsafe path in archive"), "{note}");
    for p in [r.dir.join("evil.txt"), r.dir.parent().unwrap().join("evil.txt"), r.dir.parent().unwrap().join("evil2.txt")] {
        assert!(!p.exists(), "{} was written", p.display());
    }
    assert!(!r.dir.join("server").exists(), "the server folder is replaced only by a whole, safe archive");
    assert!(!r.dir.join(".server-stage").exists() && !r.dir.join("server.zip").exists());
    assert!(r.fetches(MODEL).is_empty());

    // The same through a tar.gz: an absolute or `..` entry refuses it.
    let tgz = {
        let mut gz = Vec::new();
        {
            let mut b = tar::Builder::new(flate2::write::GzEncoder::new(&mut gz, flate2::Compression::fast()));
            let mut h = tar::Header::new_gnu();
            h.set_size(2);
            h.set_mode(0o755);
            b.append_data(&mut h, exe_name(), &b"EL"[..]).unwrap();
            // `append_data` refuses `..`; write the raw name the way a hostile archive would.
            let mut h = tar::Header::new_old();
            h.as_old_mut().name[..10].copy_from_slice(b"../up.txt\0");
            h.set_size(2);
            h.set_mode(0o644);
            h.set_entry_type(tar::EntryType::Regular);
            h.set_cksum();
            b.append(&h, &b"up"[..]).unwrap();
            b.into_inner().unwrap().finish().unwrap();
        }
        gz
    };
    let r = install_rig("inst-tarslip", Some(("llama.tar.gz", tgz)));
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    let h = wait_installed(&r.engine);
    assert!(h["note"].as_str().unwrap_or("").contains("unsafe path in archive"), "{h}");
    assert!(!r.dir.join("up.txt").exists() && !r.dir.join("server").exists());
}

#[test]
fn install_takes_the_vulkan_pin_into_server_gpu_when_gpu_is_on() {
    let dir = tmpdir("inst-gpu");
    std::fs::write(dir.join("brain.json"), r#"{"backend":"local","local":{"gpu":true}}"#).unwrap();
    let files = FileServer::start();
    let url = files.put(MODEL, DATA);
    let cpu = zip_bytes(&[(exe_name(), b"cpu")]);
    let gpu = zip_bytes(&[(exe_name(), b"gpu"), ("ggml-vulkan.dll", b"vk")]);
    let mut manifest = Manifest { default: Some("m".into()), models: vec![spec("m", MODEL, &url, DATA)], ..Default::default() };
    manifest.server.insert(config::server_target(), pinned(files.put("cpu.zip", &cpu), &cpu));
    manifest.server.insert(format!("{}-vulkan", config::server_target()), pinned(files.put("vulkan.zip", &gpu), &gpu));
    let r = build(dir, manifest, valid_unread(), FixedMem::new(6000, 16384), files);
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    assert_eq!(wait_installed(&r.engine)["state"], "cold");
    assert_eq!(std::fs::read(r.dir.join("server-gpu").join(exe_name())).unwrap(), b"gpu");
    assert!(!r.dir.join("server").exists() && r.fetches("cpu.zip").is_empty());
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
    let (exe, args) = r.llm.last_start.lock().unwrap().clone().unwrap();
    assert_eq!(exe, r.dir.join("server-gpu").join(exe_name()));
    assert!(args.join(" ").contains("-ngl 99"));
}

#[test]
fn a_hash_mismatch_strikes_three_times_then_health_carries_the_note() {
    let dir = tmpdir("inst-badhash");
    let files = FileServer::start();
    let url = files.put(MODEL, DATA);
    let mut s = spec("m", MODEL, &url, DATA);
    s.sha256 = "0".repeat(64);
    let manifest = Manifest { default: Some("m".into()), models: vec![s], ..Default::default() };
    fake_server(&dir, false);
    let r = build(dir, manifest, valid_unread(), FixedMem::new(6000, 16384), files);
    let (c, _) = route(&r.engine, "POST", "/install", json!({"model": "m"}));
    assert_eq!(c, 202);
    let h = wait_installed(&r.engine);
    assert_eq!((&h["state"], &h["download_pct"]), (&json!("absent"), &Value::Null));
    assert_eq!(r.fetches(MODEL), [0, 0, 0], "one whole fetch per strike: a bad hash is not resumed");
    assert_eq!(DL_STRIKES, 3);
    assert_eq!(h["note"], "download failed: sha256 mismatch");
    assert!(!r.dir.join(MODEL).exists() && !r.dir.join("m.gguf.part").exists());
    assert!(log(&r.dir).contains("install m strike 3: sha256 mismatch"));
    assert_503(&r.engine, "absent", "not installed");
    // The next /install is a fresh try and clears the note.
    r.files.hold();
    assert_eq!(route(&r.engine, "POST", "/install", json!({"model": "m"})).0, 202);
    assert_eq!(r.engine.health()["note"], Value::Null);
    r.files.release();
    wait_installed(&r.engine);
}

#[test]
fn a_cut_download_resumes_from_its_part_file() {
    let r = install_rig("inst-resume", None);
    r.files.cut(MODEL, 4);
    route(&r.engine, "POST", "/install", json!({"model": "m"}));
    let h = wait_installed(&r.engine);
    assert_eq!((&h["state"], &h["note"]), (&json!("cold"), &Value::Null));
    assert_eq!(r.fetches(MODEL), [0, 4], "the second strike asked for the rest");
    assert_eq!(std::fs::read(r.dir.join(MODEL)).unwrap(), DATA);
    assert!(!r.dir.join("m.gguf.part").exists());
    assert!(log(&r.dir).contains("install m strike 1: size 4 != pinned 10"), "{}", log(&r.dir));
}

#[test]
fn an_unknown_model_id_on_install_is_400_with_the_known_ids() {
    let r = rig("inst-unknown", false, valid_unread());
    let (c, v) = route(&r.engine, "POST", "/install", json!({"model": "llama-9000"}));
    assert_eq!((c, v), (400, json!({"error": "unknown model", "known": ["m"]})));
    assert_eq!(r.engine.health()["state"], "absent");
    assert!(r.files.requests().is_empty());
    assert!(!r.dir.join("brain.json").exists(), "an unknown id changes nothing");
}

#[test]
fn install_refuses_under_three_gb_of_free_disk() {
    let dir = tmpdir("inst-disk");
    let files = FileServer::start();
    let url = files.put(MODEL, DATA);
    let manifest = Manifest { default: Some("m".into()), models: vec![spec("m", MODEL, &url, DATA)], ..Default::default() };
    fake_server(&dir, false);
    let mem = FixedMem(Mutex::new(Some(Mem { free: 6000 * MB, total: 16384 * MB })), Some(MIN_DISK - 1));
    let r = build(dir, manifest, valid_unread(), mem, files);
    let (c, v) = route(&r.engine, "POST", "/install", json!({"model": "m"}));
    assert_eq!((c, v), (503, json!({"contract": 1, "state": "absent", "note": "disk"})));
    assert!(r.files.requests().is_empty());
}

#[test]
fn picking_another_model_deletes_the_old_gguf_and_install_fetches_the_new_one() {
    let dir = tmpdir("inst-swap");
    let files = FileServer::start();
    let (a_bytes, b_bytes) = (b"model a".to_vec(), b"model b!".to_vec());
    let a_url = files.put("a.gguf", &a_bytes);
    let b_url = files.put("b.gguf", &b_bytes);
    let manifest = Manifest {
        default: Some("a".into()),
        models: vec![spec("a", "a.gguf", &a_url, &a_bytes), spec("b", "b.gguf", &b_url, &b_bytes)],
        ..Default::default()
    };
    fake_server(&dir, false);
    std::fs::write(dir.join("a.gguf"), &a_bytes).unwrap();
    std::fs::write(dir.join("stray.gguf.part"), b"half").unwrap();
    let r = build(dir.clone(), manifest, valid_unread(), FixedMem::new(6000, 16384), files);
    assert!(!dir.join("stray.gguf.part").exists(), "one model on disk, from the start");
    assert_eq!(r.engine.health()["model"], "a");
    r.engine.classify(&unread()).unwrap();
    // The picker writes brain.json: the old model goes, and nothing downloads on its own.
    std::fs::write(dir.join("brain.json"), r#"{"backend":"local","local":{"model":"b"}}"#).unwrap();
    assert_503(&r.engine, "absent", "not installed");
    assert!(!dir.join("a.gguf").exists(), "the old model is gone before the new one arrives");
    assert!(!r.llm.alive.load(Ordering::SeqCst), "and its llama-server with it");
    assert_eq!(r.engine.health()["model"], "b");
    assert!(r.files.requests().is_empty());
    assert!(log(&dir).contains("model swap to b, removed [\"a.gguf\"]"));
    assert_eq!(route(&r.engine, "POST", "/install", json!({"model": "b"})).0, 202);
    wait_installed(&r.engine);
    assert_eq!(std::fs::read(dir.join("b.gguf")).unwrap(), b_bytes);
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");

    // /install of the other id makes it the choice itself: brain.json, swap, fetch.
    assert_eq!(route(&r.engine, "POST", "/install", json!({"model": "a"})).0, 202);
    wait_installed(&r.engine);
    assert!(!dir.join("b.gguf").exists() && dir.join("a.gguf").exists(), "never two models on disk");
    let chosen: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("brain.json")).unwrap()).unwrap();
    assert_eq!(chosen, json!({"backend": "local", "local": {"model": "a"}}), "other fields kept");
    assert_eq!(r.engine.health()["model"], "a");
}
