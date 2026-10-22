//! Test helpers shared by unit and integration tests. Not product API.

use crate::fetch::{FetchError, Source};
use crate::llm::{self, Fail};
use crate::supervisor::Llm;
use crate::sysinfo::{Mem, MemSource};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// A fresh directory under `<crate>/target/test-tmp/` (never the system temp dir).
pub fn tmpdir(name: &str) -> PathBuf {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("target").join("test-tmp").join(name);
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).expect("create test dir");
    p
}

/// What the mock Gemini server answers to `POST .../models/{m}:generateContent`.
#[derive(Debug, Clone)]
pub enum Mode {
    /// 200, one candidate whose text is `labels` as JSON, `finishReason: STOP`,
    /// and `usageMetadata` `[promptTokenCount, candidatesTokenCount,
    /// thoughtsTokenCount, cachedContentTokenCount]`.
    Json { labels: Value, usage: [u64; 4] },
    /// 200 with this exact body (no text, a safety stop, a prompt block, ...).
    Raw(Value),
    /// This status with a Google-style error body.
    Status(u16),
    /// 400 `INVALID_ARGUMENT` whose details name `API_KEY_INVALID`.
    KeyInvalid,
    /// Sleep, then answer as `Json`.
    Slow(Duration, Value),
}

/// `usageMetadata` from the four counts.
pub fn usage_json(u: [u64; 4]) -> Value {
    json!({"promptTokenCount": u[0], "candidatesTokenCount": u[1], "thoughtsTokenCount": u[2],
           "cachedContentTokenCount": u[3], "totalTokenCount": u[0] + u[1] + u[2]})
}

/// A `generateContent` 200 body with one candidate.
pub fn reply(parts: Value, finish: &str, usage: [u64; 4]) -> Value {
    json!({"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": finish, "index": 0}],
           "usageMetadata": usage_json(usage), "modelVersion": "mock"})
}

/// One request the mock saw.
#[derive(Debug, Clone)]
pub struct Seen {
    pub method: String,
    /// Path and query, as sent.
    pub url: String,
    pub api_key: Option<String>,
    pub content_type: Option<String>,
    /// Every header, name and value.
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

/// A local stand-in for the Gemini API: one thread per request, so a slow
/// answer does not hold the next one up. Stops when dropped.
pub struct MockGemini {
    pub base: String,
    mode: Arc<Mutex<Mode>>,
    seen: Arc<Mutex<Vec<Seen>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

fn header(req: &tiny_http::Request, name: &'static str) -> Option<String> {
    req.headers().iter().find(|h| h.field.equiv(name)).map(|h| h.value.as_str().to_string())
}

fn error(code: u16, status: &str, details: Value) -> Value {
    json!({"error": {"code": code, "message": "mock", "status": status, "details": details}})
}

fn answer(mode: &Mode) -> (u16, Value) {
    match mode {
        Mode::Json { labels, usage } => (200, reply(json!([{"text": labels.to_string()}]), "STOP", *usage)),
        Mode::Raw(v) => (200, v.clone()),
        Mode::Status(s) => {
            let status = match s {
                400 => "INVALID_ARGUMENT",
                401 => "UNAUTHENTICATED",
                403 => "PERMISSION_DENIED",
                404 => "NOT_FOUND",
                429 => "RESOURCE_EXHAUSTED",
                503 => "UNAVAILABLE",
                _ => "INTERNAL",
            };
            (*s, error(*s, status, json!([])))
        }
        Mode::KeyInvalid => (
            400,
            error(400, "INVALID_ARGUMENT", json!([{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID"}])),
        ),
        Mode::Slow(d, labels) => {
            std::thread::sleep(*d);
            answer(&Mode::Json { labels: labels.clone(), usage: [10, 5, 0, 0] })
        }
    }
}

impl MockGemini {
    pub fn start(mode: Mode) -> MockGemini {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind mock"));
        let base = format!("http://{}", server.server_addr().to_ip().expect("ip"));
        let mode = Arc::new(Mutex::new(mode));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (m, s, st) = (mode.clone(), seen.clone(), stop.clone());
        let thread = std::thread::spawn(move || {
            while !st.load(Ordering::SeqCst) {
                let Ok(Some(mut req)) = server.recv_timeout(Duration::from_millis(50)) else { continue };
                let mut raw = String::new();
                let _ = req.as_reader().read_to_string(&mut raw);
                let body: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
                s.lock().unwrap().push(Seen {
                    method: req.method().as_str().to_string(),
                    url: req.url().to_string(),
                    api_key: header(&req, "x-goog-api-key"),
                    content_type: header(&req, "content-type"),
                    headers: req.headers().iter().map(|h| (h.field.to_string(), h.value.to_string())).collect(),
                    body,
                });
                let mode = m.lock().unwrap().clone();
                std::thread::spawn(move || {
                    let (status, out) = answer(&mode);
                    let ct = tiny_http::Header::from_bytes("content-type", "application/json").unwrap();
                    let _ = req.respond(tiny_http::Response::from_string(out.to_string()).with_status_code(status).with_header(ct));
                });
            }
        });
        MockGemini { base, mode, seen, stop, thread: Some(thread) }
    }

    pub fn set(&self, mode: Mode) {
        *self.mode.lock().unwrap() = mode;
    }

    pub fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

impl Drop for MockGemini {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ------------------------------------------------------------ Anthropic

/// What the mock Anthropic server answers to `POST /v1/messages`.
#[derive(Debug, Clone)]
pub enum ClaudeMode {
    /// 200 with one `tool_use` block named after the forced tool, this
    /// `input`, and `usage` `[input_tokens, output_tokens,
    /// cache_creation_input_tokens, cache_read_input_tokens]`.
    Tool { input: Value, usage: [u64; 4] },
    /// 200 with a text block only, no `tool_use`.
    NoTool { usage: [u64; 4] },
    /// 200, `stop_reason: "refusal"`.
    Refusal { usage: [u64; 4] },
    /// 200 with a body that is not JSON.
    Garbage,
    /// This status with an Anthropic-style error body.
    Status(u16),
    /// Sleep, then answer as `Tool`.
    Slow(Duration, Value),
}

/// One request the Anthropic mock saw.
#[derive(Debug, Clone)]
pub struct ClaudeSeen {
    pub method: String,
    pub path: String,
    pub api_key: Option<String>,
    pub version: Option<String>,
    pub content_type: Option<String>,
    /// Every header, name and value.
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

fn claude_usage(u: [u64; 4]) -> Value {
    json!({"input_tokens": u[0], "output_tokens": u[1], "cache_creation_input_tokens": u[2], "cache_read_input_tokens": u[3]})
}

fn claude_answer(mode: &ClaudeMode, body: &Value) -> (u16, String) {
    let tool = body.pointer("/tool_choice/name").cloned().unwrap_or(Value::Null);
    let model = body["model"].clone();
    let msg = |content: Value, usage: [u64; 4], stop: &str| {
        json!({"id": "msg_mock", "type": "message", "role": "assistant", "model": model,
               "content": content, "stop_reason": stop, "stop_sequence": null, "usage": claude_usage(usage)})
        .to_string()
    };
    match mode {
        ClaudeMode::Tool { input, usage } => (
            200,
            msg(json!([{"type": "tool_use", "id": "toolu_mock", "name": tool, "input": input}]), *usage, "tool_use"),
        ),
        ClaudeMode::NoTool { usage } => (200, msg(json!([{"type": "text", "text": "I think it drifted."}]), *usage, "end_turn")),
        ClaudeMode::Refusal { usage } => (200, msg(json!([]), *usage, "refusal")),
        ClaudeMode::Garbage => (200, "<html>oops".into()),
        ClaudeMode::Status(s) => {
            let kind = match s {
                401 => "authentication_error",
                403 => "permission_error",
                429 => "rate_limit_error",
                529 => "overloaded_error",
                400 => "invalid_request_error",
                404 => "not_found_error",
                _ => "api_error",
            };
            (*s, json!({"type": "error", "error": {"type": kind, "message": "mock"}}).to_string())
        }
        ClaudeMode::Slow(d, input) => {
            std::thread::sleep(*d);
            claude_answer(&ClaudeMode::Tool { input: input.clone(), usage: [10, 5, 0, 0] }, body)
        }
    }
}

/// A local stand-in for the Messages API: one thread per request. Stops when dropped.
pub struct MockAnthropic {
    pub base: String,
    mode: Arc<Mutex<ClaudeMode>>,
    seen: Arc<Mutex<Vec<ClaudeSeen>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl MockAnthropic {
    pub fn start(mode: ClaudeMode) -> MockAnthropic {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind mock"));
        let base = format!("http://{}", server.server_addr().to_ip().expect("ip"));
        let mode = Arc::new(Mutex::new(mode));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (m, s, st) = (mode.clone(), seen.clone(), stop.clone());
        let thread = std::thread::spawn(move || {
            while !st.load(Ordering::SeqCst) {
                let Ok(Some(mut req)) = server.recv_timeout(Duration::from_millis(50)) else { continue };
                let mut raw = String::new();
                let _ = req.as_reader().read_to_string(&mut raw);
                let body: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
                s.lock().unwrap().push(ClaudeSeen {
                    method: req.method().as_str().to_string(),
                    path: req.url().to_string(),
                    api_key: header(&req, "x-api-key"),
                    version: header(&req, "anthropic-version"),
                    content_type: header(&req, "content-type"),
                    headers: req.headers().iter().map(|h| (h.field.to_string(), h.value.to_string())).collect(),
                    body: body.clone(),
                });
                let mode = m.lock().unwrap().clone();
                std::thread::spawn(move || {
                    let (status, out) = claude_answer(&mode, &body);
                    let ct = tiny_http::Header::from_bytes("content-type", "application/json").unwrap();
                    let _ = req.respond(tiny_http::Response::from_string(out).with_status_code(status).with_header(ct));
                });
            }
        });
        MockAnthropic { base, mode, seen, stop, thread: Some(thread) }
    }

    pub fn set(&self, mode: ClaudeMode) {
        *self.mode.lock().unwrap() = mode;
    }

    pub fn seen(&self) -> Vec<ClaudeSeen> {
        self.seen.lock().unwrap().clone()
    }
}

impl Drop for MockAnthropic {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ------------------------------------------------------------ local backend

/// An in-process llama-server stand-in: counts calls, answers a fixed JSON.
pub struct FakeLlm {
    pub starts: AtomicU32,
    pub stops: AtomicU32,
    pub asks: AtomicU32,
    pub fail_start: AtomicBool,
    pub alive: AtomicBool,
    /// `ask` answers `Timeout` and the process stays up.
    pub slow: AtomicBool,
    pub answer: Mutex<Value>,
    /// The exe and flags of the last start.
    pub last_start: Mutex<Option<(PathBuf, Vec<String>)>>,
}

impl FakeLlm {
    pub fn new(answer: Value) -> Self {
        FakeLlm {
            starts: AtomicU32::new(0),
            stops: AtomicU32::new(0),
            asks: AtomicU32::new(0),
            fail_start: AtomicBool::new(false),
            alive: AtomicBool::new(false),
            slow: AtomicBool::new(false),
            answer: Mutex::new(answer),
            last_start: Mutex::new(None),
        }
    }
}

impl Llm for FakeLlm {
    fn start(&self, exe: &Path, args: &[String]) -> Result<(), String> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        *self.last_start.lock().unwrap() = Some((exe.to_path_buf(), args.to_vec()));
        let gguf = args.iter().skip_while(|a| *a != "-m").nth(1).map(PathBuf::from);
        if self.fail_start.load(Ordering::SeqCst) || !gguf.is_some_and(|g| g.is_file()) {
            return Err("fake start failure".into());
        }
        self.alive.store(true, Ordering::SeqCst);
        Ok(())
    }
    fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }
    fn stop(&self) {
        self.stops.fetch_add(1, Ordering::SeqCst);
        self.alive.store(false, Ordering::SeqCst);
    }
    fn ask(&self, _: &str, _: &str, _: &Value, _: Duration) -> llm::Reply {
        self.asks.fetch_add(1, Ordering::SeqCst);
        let r = |status, result| llm::Reply { status, input_tokens: 0, output_tokens: 0, result };
        if !self.alive.load(Ordering::SeqCst) {
            return r(None, Err(Fail::Other("fake llama is down".into())));
        }
        if self.slow.load(Ordering::SeqCst) {
            return r(None, Err(Fail::Timeout));
        }
        llm::Reply { status: Some(200), input_tokens: 100, output_tokens: 10, result: Ok(self.answer.lock().unwrap().clone()) }
    }
}

/// Memory and disk readings a test sets.
pub struct FixedMem(pub Mutex<Option<Mem>>, pub Option<u64>);

impl FixedMem {
    pub fn new(free_mb: u64, total_mb: u64) -> Self {
        let mb = 1024 * 1024;
        FixedMem(Mutex::new(Some(Mem { free: free_mb * mb, total: total_mb * mb })), None)
    }
    pub fn set_free_mb(&self, free_mb: u64) {
        self.0.lock().unwrap().as_mut().unwrap().free = free_mb * 1024 * 1024;
    }
}

impl MemSource for FixedMem {
    fn read(&self) -> Option<Mem> {
        *self.0.lock().unwrap()
    }
    fn disk_free(&self, _: &Path) -> Option<u64> {
        self.1
    }
}

/// An in-memory download source. `range`: honour `from` (206) or ignore it (200).
pub struct BytesSource {
    data: Vec<u8>,
    range: bool,
    froms: Mutex<Vec<u64>>,
}

impl BytesSource {
    pub fn new(data: Vec<u8>, range: bool) -> Self {
        BytesSource { data, range, froms: Mutex::new(Vec::new()) }
    }
    pub fn opened_from(&self) -> Vec<u64> {
        self.froms.lock().unwrap().clone()
    }
}

impl Source for BytesSource {
    fn open(&self, _: &str, from: u64) -> Result<(Box<dyn Read + Send>, u64), FetchError> {
        self.froms.lock().unwrap().push(from);
        let start = if self.range { from } else { 0 };
        Ok((Box::new(Cursor::new(self.data[start as usize..].to_vec())), start))
    }
}

/// A local HTTP file server for `/install` tests: `GET /<name>` serves the
/// bytes put there, honouring `Range: bytes=N-` with a 206. `hold()` parks
/// every request until `release()`; `cut(name, n)` sends only the first `n`
/// bytes on the next request for `name`, as a dropped connection would.
pub struct FileServer {
    pub base: String,
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    /// Every request: path and the `Range` start it asked for.
    log: Arc<Mutex<Vec<(String, u64)>>>,
    cuts: Arc<Mutex<HashMap<String, usize>>>,
    held: Arc<(Mutex<bool>, Condvar)>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl FileServer {
    pub fn start() -> FileServer {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind file server"));
        let base = format!("http://{}", server.server_addr().to_ip().expect("ip"));
        let files: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
        let log: Arc<Mutex<Vec<(String, u64)>>> = Arc::default();
        let cuts: Arc<Mutex<HashMap<String, usize>>> = Arc::default();
        let held: Arc<(Mutex<bool>, Condvar)> = Arc::default();
        let stop = Arc::new(AtomicBool::new(false));
        let (f, lg, c, h, st) = (files.clone(), log.clone(), cuts.clone(), held.clone(), stop.clone());
        let thread = std::thread::spawn(move || {
            while !st.load(Ordering::SeqCst) {
                let Ok(Some(req)) = server.recv_timeout(Duration::from_millis(50)) else { continue };
                let (f, lg, c, h) = (f.clone(), lg.clone(), c.clone(), h.clone());
                std::thread::spawn(move || {
                    {
                        let mut g = h.0.lock().unwrap();
                        while *g {
                            g = h.1.wait(g).unwrap();
                        }
                    }
                    let name = req.url().trim_start_matches('/').to_string();
                    let from = header(&req, "Range")
                        .and_then(|r| r.strip_prefix("bytes=").and_then(|s| s.trim_end_matches('-').parse::<u64>().ok()))
                        .unwrap_or(0);
                    lg.lock().unwrap().push((name.clone(), from));
                    let Some(data) = f.lock().unwrap().get(&name).cloned() else {
                        let _ = req.respond(tiny_http::Response::empty(404));
                        return;
                    };
                    let mut body = data[(from as usize).min(data.len())..].to_vec();
                    if let Some(n) = c.lock().unwrap().remove(&name) {
                        body.truncate(n);
                    }
                    let status = if from > 0 { 206 } else { 200 };
                    let _ = req.respond(tiny_http::Response::from_data(body).with_status_code(status));
                });
            }
        });
        FileServer { base, files, log, cuts, held, stop, thread: Some(thread) }
    }

    /// Serve `bytes` at `/<name>`; returns its URL.
    pub fn put(&self, name: &str, bytes: &[u8]) -> String {
        self.files.lock().unwrap().insert(name.to_string(), bytes.to_vec());
        format!("{}/{name}", self.base)
    }

    pub fn cut(&self, name: &str, n: usize) {
        self.cuts.lock().unwrap().insert(name.to_string(), n);
    }

    /// `(name, range start)` of every request so far.
    pub fn requests(&self) -> Vec<(String, u64)> {
        self.log.lock().unwrap().clone()
    }

    pub fn hold(&self) {
        *self.held.0.lock().unwrap() = true;
    }

    pub fn release(&self) {
        *self.held.0.lock().unwrap() = false;
        self.held.1.notify_all();
    }
}

impl Drop for FileServer {
    fn drop(&mut self) {
        self.release();
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
