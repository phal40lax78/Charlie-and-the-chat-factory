//! The `Engine` behind the routes (SPEC.md sections 1-2): `/classify` for the
//! regex tasks by the regex layer and for the model tasks by the backend
//! `brain.json` names (Gemini, Claude Haiku, or a local llama-server),
//! `/health`, `/usage`, and for the local backend `/install` and `/unload`.
//!
//! No fallback: a model-tier task is answered by the backend or not at all
//! (`Unavailable`, a 503). Only the regex-tier tasks answer from the regex layer.

use crate::anthropic;
use crate::api::{Answer, ClassifyReq, Tail, CONTRACT};
use crate::catalogue::{self, Task};
use crate::config::{self, Backend, Layout};
use crate::fetch::HttpSource;
use crate::gemini;
use crate::proc::ProcLlama;
use crate::rules;
use crate::schema;
use crate::supervisor::{self, Local, SystemClock};
use crate::sysinfo::OsMem;
use crate::usage;
use chrono::Local as LocalTime;
use serde_json::{json, Value};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Why there is no model answer: the 503 body `{contract, state, note}`.
/// `state` is `unconfigured` (no key) or `ready` for the API backends, the
/// lifecycle state for the local one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unavailable {
    pub state: &'static str,
    pub note: String,
}

impl Unavailable {
    pub fn to_json(&self) -> Value {
        json!({"contract": CONTRACT, "state": self.state, "note": self.note})
    }
}

#[derive(Debug)]
pub enum ClassifyErr {
    /// Task or schema version not in the catalogue (409).
    Unknown(Vec<String>),
    /// A model-tier task the backend did not answer (503).
    Unavailable(Unavailable),
}

/// Where and how an API backend is called.
#[derive(Debug, Clone)]
pub struct Remote {
    /// The API's base URL; tests point it at a local mock.
    pub base: String,
    /// Env var read when the key file is missing; `None` in tests.
    pub key_env: Option<String>,
    pub timeout: Duration,
}

impl Remote {
    /// Gemini: [gemini::DEFAULT_BASE] unless the test-only [gemini::BASE_ENV]
    /// is set, the `GEMINI_API_KEY` fallback, the 2 300 ms timeout.
    pub fn from_env() -> Remote {
        Remote {
            base: std::env::var(gemini::BASE_ENV).unwrap_or_else(|_| gemini::DEFAULT_BASE.into()),
            key_env: Some(gemini::KEY_ENV.into()),
            timeout: Duration::from_millis(gemini::TIMEOUT_MS),
        }
    }

    /// Anthropic: [anthropic::DEFAULT_BASE] unless the test-only
    /// [anthropic::BASE_ENV] is set, the `ANTHROPIC_API_KEY` fallback, the
    /// 2 300 ms timeout.
    pub fn anthropic_from_env() -> Remote {
        Remote {
            base: std::env::var(anthropic::BASE_ENV).unwrap_or_else(|_| anthropic::DEFAULT_BASE.into()),
            key_env: Some(anthropic::KEY_ENV.into()),
            timeout: Duration::from_millis(anthropic::TIMEOUT_MS),
        }
    }
}

enum Kind {
    Mock,
    Gemini(Remote, ureq::Agent),
    Anthropic(Remote, ureq::Agent),
    Local(Local),
}

struct Shared {
    layout: Layout,
    kind: Kind,
    /// One writer at a time on `usage.jsonl`.
    usage_lock: Mutex<()>,
    /// The last call's 503 note, cleared by the next answer; for `/health`.
    last_note: Mutex<Option<String>>,
}

#[derive(Clone)]
pub struct Engine(Arc<Shared>);

/// `--mock` answers for the model-tier tasks (SPEC.md section 6).
static MOCK_ANSWERS: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../vectors/mock-answers.json")).expect("mock-answers.json parses")
});

fn mock_answer(task: &Task) -> Answer {
    let a = &MOCK_ANSWERS["answers"][task.name];
    Answer {
        contract: CONTRACT,
        labels: a["labels"].clone(),
        confidence: a["confidence"].as_f64().unwrap_or(1.0),
        tier: "model",
        why: format!("mock:{}", task.schema_id()),
    }
}

/// fail_kind asks the model only when the regex found nothing but the tool output holds an error.
fn escalates(task: &Task, labels: &Value, tail: &Tail) -> bool {
    task.name == "fail_kind" && labels["kind"] == "none" && tail.tool_out.to_lowercase().contains("error")
}

impl Engine {
    /// `--mock`: no network. Regex tasks run the regex layer; model tasks
    /// answer canned labels from `vectors/mock-answers.json`.
    pub fn mock(layout: Layout) -> Engine {
        Engine::build(layout, Kind::Mock)
    }

    pub fn gemini(layout: Layout, remote: Remote) -> Result<Engine, String> {
        let agent = gemini::agent(remote.timeout)?;
        Ok(Engine::build(layout, Kind::Gemini(remote, agent)))
    }

    pub fn anthropic(layout: Layout, remote: Remote) -> Result<Engine, String> {
        let agent = anthropic::agent(remote.timeout)?;
        Ok(Engine::build(layout, Kind::Anthropic(remote, agent)))
    }

    /// The local backend over its parts (tests pass fakes).
    pub fn local(layout: Layout, local: Local) -> Engine {
        Engine::build(layout, Kind::Local(local))
    }

    /// The backend `brain.json` names, with the real network, process and
    /// clock. An unknown backend is an error, not a fallback.
    pub fn from_config(layout: Layout) -> Result<Engine, String> {
        match config::backend(&layout)? {
            Backend::Gemini => Engine::gemini(layout, Remote::from_env()),
            Backend::Anthropic => Engine::anthropic(layout, Remote::anthropic_from_env()),
            Backend::Local => {
                let local = Local::new(
                    layout.clone(),
                    config::load_manifest(&layout),
                    Arc::new(SystemClock::new()),
                    Arc::new(OsMem),
                    Arc::new(ProcLlama::new()),
                    Arc::new(HttpSource::new().map_err(|e| e.to_string())?),
                    supervisor::Tuning::default(),
                );
                Ok(Engine::local(layout, local))
            }
        }
    }

    fn build(layout: Layout, kind: Kind) -> Engine {
        Engine(Arc::new(Shared { layout, kind, usage_lock: Mutex::new(()), last_note: Mutex::new(None) }))
    }

    pub fn is_mock(&self) -> bool {
        matches!(self.0.kind, Kind::Mock)
    }

    /// `"mock"`, `"gemini"`, `"anthropic"` or `"local"`.
    pub fn backend(&self) -> &'static str {
        match self.0.kind {
            Kind::Mock => "mock",
            Kind::Gemini(..) => "gemini",
            Kind::Anthropic(..) => "anthropic",
            Kind::Local(_) => "local",
        }
    }

    /// The local backend, which alone has `/install` and `/unload`.
    pub fn local_backend(&self) -> Option<&Local> {
        match &self.0.kind {
            Kind::Local(l) => Some(l),
            _ => None,
        }
    }

    /// The API key of an API backend; `None` for the others.
    fn key(&self) -> Option<String> {
        let l = &self.0.layout;
        match &self.0.kind {
            Kind::Gemini(r, _) => config::api_key(l, r.key_env.as_deref()),
            Kind::Anthropic(r, _) => config::anthropic_key(l, r.key_env.as_deref()),
            // The mock reports on the Gemini key, as it always has.
            Kind::Mock => config::api_key(l, None),
            Kind::Local(_) => None,
        }
    }

    /// The model the backend asks.
    fn model(&self) -> String {
        match &self.0.kind {
            Kind::Anthropic(..) => config::anthropic_model(&self.0.layout),
            Kind::Local(l) => l.model_id().unwrap_or_default(),
            Kind::Mock | Kind::Gemini(..) => config::model(&self.0.layout),
        }
    }

    fn set_note(&self, note: Option<&str>) {
        *self.0.last_note.lock().unwrap_or_else(|e| e.into_inner()) = note.map(str::to_string);
    }

    pub fn classify(&self, req: &ClassifyReq) -> Result<Answer, ClassifyErr> {
        let task = catalogue::find(&req.task, &req.schema_id).map_err(ClassifyErr::Unknown)?;
        let tail = &req.transcript_tail;
        if task.model_tier {
            if self.is_mock() {
                return Ok(mock_answer(task));
            }
            return self.ask_model(task, tail).map_err(|u| {
                config::diag(&self.0.layout, &format!("503 {} {} {}", task.name, u.state, u.note));
                ClassifyErr::Unavailable(u)
            });
        }
        let v = rules::classify(task.name, tail).expect("regex-tier task has a rule");
        let regex = Answer { contract: CONTRACT, labels: v.labels, confidence: v.confidence, tier: "regex", why: v.why };
        if self.is_mock() || !escalates(task, &regex.labels, tail) {
            return Ok(regex);
        }
        // The escalation is a second opinion: when the backend cannot give it, the regex answer stands.
        Ok(self.ask_model(task, tail).unwrap_or(regex))
    }

    fn ask_model(&self, task: &Task, tail: &Tail) -> Result<Answer, Unavailable> {
        match &self.0.kind {
            Kind::Mock => Ok(mock_answer(task)),
            Kind::Gemini(r, a) => self.ask_gemini(r, a, task, tail),
            Kind::Anthropic(r, a) => self.ask_anthropic(r, a, task, tail),
            Kind::Local(l) => l.ask(task, tail),
        }
    }

    fn append_usage(&self, line: &usage::Line) {
        let _g = self.0.usage_lock.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = usage::append(&self.0.layout.usage_file(), line) {
            config::diag(&self.0.layout, &format!("usage.jsonl: {e}"));
        }
    }

    /// The labels, validated against the full original schema (not the one
    /// sent), or the note; `/health`'s note and the log follow.
    fn finish(
        &self,
        task: &Task,
        schema: &Value,
        status: Option<u16>,
        ms: u64,
        result: Result<Value, &'static str>,
    ) -> Result<Answer, Unavailable> {
        let result = result.and_then(|labels| match schema::validate(schema, &labels) {
            Ok(()) => Ok(labels),
            Err(_) => Err("malformed"),
        });
        let status = status.map_or("-".to_string(), |s| s.to_string());
        match result {
            Ok(labels) => {
                self.set_note(None);
                config::diag(&self.0.layout, &format!("api {} {status} {ms} ms", task.name));
                Ok(Answer { contract: CONTRACT, labels, confidence: 0.8, tier: "model", why: format!("model:{}", task.schema_id()) })
            }
            Err(note) => {
                self.set_note(Some(note));
                config::diag(&self.0.layout, &format!("api {} {status} {ms} ms {note}", task.name));
                Err(Unavailable { state: "ready", note: note.into() })
            }
        }
    }

    fn no_key(&self) -> Unavailable {
        self.set_note(Some("no key"));
        Unavailable { state: "unconfigured", note: "no key".into() }
    }

    /// Gemini's answer, or why there is none. Every call that got a response
    /// leaves one line in `usage.jsonl`.
    fn ask_gemini(&self, remote: &Remote, agent: &ureq::Agent, task: &Task, tail: &Tail) -> Result<Answer, Unavailable> {
        let Some(key) = self.key() else { return Err(self.no_key()) };
        let model = config::model(&self.0.layout);
        let schema = task.schema_value();
        let body = gemini::request_body(&model, task.system, &gemini::render_tail(tail), &schema);
        let t0 = Instant::now();
        let reply = gemini::call(agent, &remote.base, &key, &model, &body);
        let ms = t0.elapsed().as_millis() as u64;
        if let Some(status) = reply.status {
            self.append_usage(&usage::Line::new(LocalTime::now(), task.name, &model, status, ms, &reply.usage));
        }
        self.finish(task, &schema, reply.status, ms, reply.result.map_err(gemini::Fail::note))
    }

    /// Claude's answer through a forced tool call, or why there is none.
    /// Every call that got a response leaves one line in `usage.jsonl`.
    fn ask_anthropic(&self, remote: &Remote, agent: &ureq::Agent, task: &Task, tail: &Tail) -> Result<Answer, Unavailable> {
        let Some(key) = self.key() else { return Err(self.no_key()) };
        let model = config::anthropic_model(&self.0.layout);
        let schema = task.schema_value();
        let body = anthropic::request_body(&model, task.name, task.system, &anthropic::render_tail(tail), &schema);
        let t0 = Instant::now();
        let reply = anthropic::call(agent, &remote.base, &key, &body, task.name);
        let ms = t0.elapsed().as_millis() as u64;
        if let Some(status) = reply.status {
            self.append_usage(&usage::Line::anthropic(LocalTime::now(), task.name, &model, status, ms, &reply.usage));
        }
        self.finish(task, &schema, reply.status, ms, reply.result.map_err(anthropic::Fail::note))
    }

    /// API backends and the mock: `{contract, backend, model, state, key,
    /// month_cost_usd, note}`, saying whether a key is there, never what it
    /// is. Local: `{contract, backend, model, state, resources_pct, idle_s,
    /// download_pct, note}`.
    pub fn health(&self) -> Value {
        if let Kind::Local(l) = &self.0.kind {
            return l.health();
        }
        let present = self.key().is_some();
        let model = self.model();
        json!({
            "contract": CONTRACT,
            "backend": self.backend(),
            "model": if self.is_mock() { Value::Null } else { json!(model) },
            "state": if self.is_mock() || present { "ready" } else { "unconfigured" },
            "key": if present { "present" } else { "missing" },
            "month_cost_usd": usage::month_cost(&self.0.layout.usage_file(), LocalTime::now(), &model),
            "note": self.0.last_note.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        })
    }

    /// `{contract, model, note, today, month, all}` from `usage.jsonl`, local
    /// dates; `note` names a model with no price row, else null. A local
    /// model costs 0 and is never unpriced.
    pub fn usage(&self) -> Value {
        let model = self.model();
        let path = self.0.layout.usage_file();
        let mut v = match &self.0.kind {
            Kind::Local(_) => usage::summary_with(&path, LocalTime::now(), None),
            _ => usage::summary(&path, LocalTime::now(), &model),
        };
        v["contract"] = json!(CONTRACT);
        v["model"] = json!(model);
        v
    }

    /// Once a second from `main`: the local backend's idle kill and crash check.
    pub fn tick(&self) {
        if let Kind::Local(l) = &self.0.kind {
            l.tick();
        }
    }

    /// Stops a local llama-server; nothing to do for the others.
    pub fn shutdown(&self) {
        if let Kind::Local(l) = &self.0.kind {
            l.shutdown();
        }
    }
}
