//! Tier 0: the contract over a real socket against `--mock`, and the
//! Gemini backend against a local mock Gemini API (`testutil::MockGemini`):
//! request body, 503 notes, usage lines and totals, `/health`. Nothing here
//! leaves 127.0.0.1.

use chatq_brain::api::{Answer, ClassifyReq};
use chatq_brain::catalogue::{self, TASKS};
use chatq_brain::config::{Layout, DEFAULT_MODEL};
use chatq_brain::engine::{ClassifyErr, Engine, Remote};
use chatq_brain::gemini::{self, Usage};
use chatq_brain::server;
use chatq_brain::testutil::{reply, tmpdir, usage_json, MockGemini, Mode};
use chatq_brain::usage;
use chrono::{Datelike, Duration as Days, Local, TimeZone};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

// ------------------------------------------------------------ over HTTP

struct Live {
    h: server::Handle,
}

impl Live {
    fn new(engine: Engine) -> Live {
        Live { h: server::start(engine, "tok123".into(), 0).unwrap() }
    }
    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.h.port)
    }
    fn call(&self, method: &str, path: &str, token: Option<&str>, body: Option<Value>) -> (u16, String) {
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build();
        let mut req = agent.request(method, &self.url(path));
        if let Some(t) = token {
            req = req.set("Authorization", &format!("Bearer {t}"));
        }
        let res = match body {
            Some(b) => req.send_json(b),
            None => req.call(),
        };
        match res {
            Ok(r) => (r.status(), r.into_string().unwrap()),
            Err(ureq::Error::Status(c, r)) => (c, r.into_string().unwrap()),
            Err(e) => panic!("transport: {e}"),
        }
    }
    fn ok(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let (c, s) = self.call(method, path, Some("tok123"), body);
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

/// One request through the router, no socket.
fn route(engine: &Engine, method: &str, path: &str, body: Value) -> (u16, Value) {
    let (c, v) = server::route(engine, "t", method, path, Some("Bearer t"), body.to_string().as_bytes());
    (c, v.unwrap_or(Value::Null))
}

fn mock_engine(name: &str) -> Engine {
    Engine::mock(Layout::new(tmpdir(name)))
}

#[test]
fn mock_requires_the_bearer_token() {
    let s = Live::new(mock_engine("mock-token"));
    for path in ["/health", "/classify", "/usage", "/nope"] {
        let (c, body) = s.call("GET", path, None, None);
        assert_eq!((c, body.as_str()), (401, ""), "{path} without a token");
        let (c, body) = s.call("GET", path, Some("wrong"), None);
        assert_eq!((c, body.as_str()), (401, ""), "{path} with a wrong token");
    }
    let (c, _) = s.call("GET", "/health", Some("tok123"), None);
    assert_eq!(c, 200);
    let (c, _) = s.call("GET", "/health", Some("tok12"), None);
    assert_eq!(c, 401, "a prefix of the token is not the token");
}

#[test]
fn mock_health_shape() {
    let s = Live::new(mock_engine("mock-health"));
    let (c, v) = s.ok("GET", "/health", None);
    assert_eq!(c, 200);
    assert_eq!(
        v,
        json!({"contract": 1, "backend": "mock", "model": null, "state": "ready", "key": "missing",
               "month_cost_usd": 0.0, "note": null})
    );
}

#[test]
fn mock_usage_shape_is_all_zero() {
    let s = Live::new(mock_engine("mock-usage"));
    let (c, v) = s.ok("GET", "/usage", None);
    assert_eq!(c, 200);
    assert_eq!(v["contract"], 1);
    assert_eq!(v["model"], DEFAULT_MODEL);
    assert_eq!(v["note"], Value::Null, "the default model has a price");
    for k in ["today", "month", "all"] {
        assert_eq!(
            v[k],
            json!({"calls": 0, "errors": 0, "input_tokens": 0, "output_tokens": 0, "thought_tokens": 0,
                   "cost_usd": 0.0, "by_task": {}})
        );
    }
}

fn mock_answers() -> Value {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("vectors").join("mock-answers.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

#[test]
fn mock_answers_json_covers_exactly_the_model_tasks_with_schema_valid_labels() {
    let file = mock_answers();
    let answers = file["answers"].as_object().unwrap();
    let mut keys: Vec<&str> = answers.keys().map(String::as_str).collect();
    let mut model: Vec<&str> = TASKS.iter().filter(|t| t.model_tier).map(|t| t.name).collect();
    keys.sort();
    model.sort();
    assert_eq!(keys, model);
    for t in TASKS.iter().filter(|t| t.model_tier) {
        chatq_brain::schema::validate(&t.schema_value(), &answers[t.name]["labels"])
            .unwrap_or_else(|e| panic!("{}: {e}", t.name));
    }
}

#[test]
fn the_mock_answers_model_tasks_from_mock_answers_json_and_regex_tasks_by_regex() {
    let s = Live::new(mock_engine("mock-classify"));
    let file = mock_answers();
    for t in TASKS.iter().filter(|t| t.model_tier) {
        // Any tail: the canned labels do not depend on it.
        let (c, v) = s.ok("POST", "/classify", Some(req(t.name, &t.schema_id(), "", &[("user", "anything")])));
        assert_eq!(c, 200, "{}: {v}", t.name);
        assert_eq!(v["contract"], 1);
        assert_eq!(v["tier"], "model", "{}", t.name);
        assert_eq!(v["labels"], file["answers"][t.name]["labels"], "{}", t.name);
        assert_eq!(v["why"], format!("mock:{}", t.schema_id()));
    }
    let regex_cases = [
        ("fail_kind", "pytest: 3 failed, 12 passed", vec![("user", "run the tests")], json!({"kind": "tests", "n": 3})),
        ("extract", "", vec![("user", "update src/a.rs")], json!({"task": "update src/a.rs"})),
    ];
    for (task, tool_out, turns, want) in regex_cases {
        let (c, v) = s.ok("POST", "/classify", Some(req(task, &format!("{task}@1"), tool_out, &turns)));
        assert_eq!(c, 200, "{task}: {v}");
        assert_eq!(v["tier"], "regex", "{task}");
        assert!(v["confidence"].as_f64().unwrap() > 0.0 && v["confidence"].as_f64().unwrap() <= 1.0);
        for (k, w) in want.as_object().unwrap() {
            assert_eq!(&v["labels"][k], w, "{task}.{k}");
        }
    }
}

#[test]
fn unknown_schema_id_is_409_with_the_known_list() {
    let s = Live::new(mock_engine("mock-409"));
    let (c, v) = s.ok("POST", "/classify", Some(req("fail_kind", "fail_kind@2", "", &[])));
    assert_eq!(c, 409);
    assert_eq!(v["known"].as_array().unwrap().len(), 6);
    assert!(v["known"].as_array().unwrap().contains(&json!("fail_kind@1")));
    let (c, _) = s.ok("POST", "/classify", Some(req("nope", "nope@1", "", &[])));
    assert_eq!(c, 409);
    let (c, _) = s.ok("POST", "/classify", Some(req("fail_kind", "extract@1", "", &[])));
    assert_eq!(c, 409, "task and schema_id must agree");
}

#[test]
fn bad_requests_and_the_routes_that_are_gone() {
    let s = Live::new(mock_engine("mock-bad"));
    let (c, _) = s.ok("POST", "/classify", Some(json!({"nonsense": true})));
    assert_eq!(c, 400);
    let (c, _) = s.ok("GET", "/nowhere", None);
    assert_eq!(c, 404);
    for gone in ["/install", "/unload"] {
        let (c, _) = s.ok("POST", gone, Some(json!({})));
        assert_eq!(c, 404, "{gone} went with the local model");
    }
    let (c, _) = s.ok("GET", "/classify", None);
    assert_eq!(c, 405);
    let (c, _) = s.ok("POST", "/health", None);
    assert_eq!(c, 405);
    let (c, _) = s.ok("POST", "/usage", Some(json!({})));
    assert_eq!(c, 405);
}

// ------------------------------------------------------------ Gemini backend

const KEY: &str = "AIzaSy-test-0123456789abcdef";
const SECRET_TEXT: &str = "the purple elephant refactor";

struct Rig {
    dir: PathBuf,
    engine: Engine,
    api: MockGemini,
}

impl Rig {
    fn new(name: &str, mode: Mode, with_key: bool) -> Rig {
        Rig::with_timeout(name, mode, with_key, Duration::from_millis(gemini::TIMEOUT_MS))
    }
    fn with_timeout(name: &str, mode: Mode, with_key: bool, timeout: Duration) -> Rig {
        let dir = tmpdir(name);
        if with_key {
            std::fs::write(dir.join("gemini-key"), format!("{KEY}\n")).unwrap();
        }
        let api = MockGemini::start(mode);
        let remote = Remote { base: api.base.clone(), key_env: None, timeout };
        let engine = Engine::gemini(Layout::new(&dir), remote).unwrap();
        Rig { dir, engine, api }
    }
    fn usage_lines(&self) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join("usage.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }
    fn usage_text(&self) -> String {
        std::fs::read_to_string(self.dir.join("usage.jsonl")).unwrap_or_default()
    }
}

fn unread() -> ClassifyReq {
    serde_json::from_value(unread_json()).unwrap()
}

fn unread_json() -> Value {
    req("unread_reply", "unread_reply@1", "", &[("assistant", &format!("Should I do {SECRET_TEXT}?")), ("user", "ok")])
}

fn valid_unread() -> Value {
    json!({"asked": true, "answered": true, "question": "Should I go on?"})
}

/// 1000 prompt tokens (200 of them cached), 100 out, 50 thought.
fn json_answer(labels: Value) -> Mode {
    Mode::Json { labels, usage: [1000, 100, 50, 200] }
}

/// (800 * 0.25 + 200 * 0.025 + (100 + 50) * 1.50) / 1e6 at gemini-3.1-flash-lite.
const JSON_ANSWER_COST: f64 = 0.00043;

fn unavailable(r: Result<Answer, ClassifyErr>) -> chatq_brain::engine::Unavailable {
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

#[test]
fn a_success_returns_validated_labels_and_one_usage_line_costed_with_thought_tokens() {
    let r = Rig::new("api-ok", json_answer(valid_unread()), true);
    let (c, v) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(c, 200, "{v}");
    assert_eq!(
        v,
        json!({"contract": 1, "labels": valid_unread(), "confidence": 0.8, "tier": "model", "why": "model:unread_reply@1"})
    );
    let lines = r.usage_lines();
    assert_eq!(lines.len(), 1);
    let l = &lines[0];
    let mut keys: Vec<&str> = l.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(
        keys,
        ["cached_tokens", "cost_usd", "input_tokens", "model", "ms", "output_tokens", "status", "task", "thought_tokens", "ts"]
    );
    assert_eq!((&l["task"], &l["model"], &l["status"]), (&json!("unread_reply"), &json!(DEFAULT_MODEL), &json!(200)));
    assert_eq!((&l["input_tokens"], &l["output_tokens"]), (&json!(1000), &json!(100)));
    assert_eq!((&l["thought_tokens"], &l["cached_tokens"]), (&json!(50), &json!(200)));
    assert_eq!(l["cost_usd"], JSON_ANSWER_COST);
    assert!(chrono::DateTime::parse_from_rfc3339(l["ts"].as_str().unwrap()).is_ok());
}

#[test]
fn the_request_carries_the_schema_thinking_and_the_key_in_its_header_only() {
    let r = Rig::new("api-body", json_answer(valid_unread()), true);
    r.engine.classify(&unread()).unwrap();
    let seen = r.api.seen();
    assert_eq!(seen.len(), 1);
    let s = &seen[0];
    assert_eq!((s.method.as_str(), s.url.as_str()), ("POST", "/v1beta/models/gemini-3.1-flash-lite:generateContent"));
    assert_eq!(s.api_key.as_deref(), Some(KEY));
    assert!(!s.url.contains(KEY) && !s.url.contains("key="), "the key is never in the URL: {}", s.url);
    let carrying: Vec<&str> = s.headers.iter().filter(|(_, v)| v.contains(KEY)).map(|(n, _)| n.as_str()).collect();
    assert_eq!(carrying.len(), 1);
    assert!(carrying[0].eq_ignore_ascii_case("x-goog-api-key"), "{carrying:?}");
    assert_eq!(s.content_type.as_deref(), Some("application/json"));
    let t = catalogue::find("unread_reply", "unread_reply@1").unwrap();
    let b = &s.body;
    assert!(!b.to_string().contains(KEY));
    assert!(b.get("model").is_none(), "the model is in the URL");
    assert_eq!(b["systemInstruction"], json!({"parts": [{"text": t.system}]}));
    assert_eq!(b["contents"].as_array().unwrap().len(), 1);
    assert_eq!(b["contents"][0]["role"], "user");
    assert_eq!(b["contents"][0]["parts"][0]["text"], format!("[assistant] Should I do {SECRET_TEXT}?\n[user] ok\n"));
    let g = &b["generationConfig"];
    assert_eq!(g["temperature"], 0);
    assert_eq!(g["maxOutputTokens"], 300);
    assert_eq!(g["responseMimeType"], "application/json");
    assert_eq!(g["responseJsonSchema"], gemini::json_schema(&t.schema_value()));
    assert_eq!(g["responseJsonSchema"], t.schema_value(), "unread_reply needs no conversion");
    assert_eq!(g["thinkingConfig"], json!({"thinkingLevel": "minimal"}));

    // fail_kind's untyped enum is sent typed.
    r.api.set(json_answer(json!({"kind": "build", "n": null, "file": null, "tool": null, "attempt": null})));
    let murky: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "Error: odd", &[])).unwrap();
    r.engine.classify(&murky).unwrap();
    let fk = &r.api.seen()[1].body["generationConfig"]["responseJsonSchema"];
    assert_eq!(fk["properties"]["kind"]["type"], "string");

    // brain.json picks the model, and with it the URL and the thinking setting.
    std::fs::write(r.dir.join("brain.json"), r#"{"model":"gemini-2.5-flash-lite"}"#).unwrap();
    r.api.set(json_answer(valid_unread()));
    r.engine.classify(&unread()).unwrap();
    let s = &r.api.seen()[2];
    assert_eq!(s.url, "/v1beta/models/gemini-2.5-flash-lite:generateContent");
    assert_eq!(s.body["generationConfig"]["thinkingConfig"], json!({"thinkingBudget": 0}));
    assert_eq!(r.usage_lines()[2]["model"], "gemini-2.5-flash-lite");
    // (800 * 0.10 + 200 * 0.01 + 150 * 0.40) / 1e6
    assert_eq!(r.usage_lines()[2]["cost_usd"], 0.000142);
}

#[test]
fn no_key_is_503_no_key_with_no_call_and_no_usage_line() {
    let r = Rig::new("api-nokey", json_answer(valid_unread()), false);
    assert_503(&r.engine, "unconfigured", "no key");
    assert!(r.api.seen().is_empty(), "nothing was sent");
    assert!(!r.dir.join("usage.jsonl").exists());
    for t in TASKS.iter().filter(|t| t.model_tier) {
        let (c, v) = route(&r.engine, "POST", "/classify", req(t.name, &t.schema_id(), "", &[("user", "x")]));
        assert_eq!(c, 503, "{}", t.name);
        assert!(v.get("labels").is_none() && v.get("tier").is_none(), "{}: {v}", t.name);
    }
    // The old key file is not read.
    std::fs::write(r.dir.join("anthropic-key"), KEY).unwrap();
    assert_503(&r.engine, "unconfigured", "no key");
}

#[test]
fn the_key_env_var_is_the_fallback() {
    assert_eq!(gemini::KEY_ENV, "GEMINI_API_KEY");
    let dir = tmpdir("api-envkey");
    let api = MockGemini::start(json_answer(valid_unread()));
    let var = "CHATQ_BRAIN_TEST_KEY_ENV_FALLBACK";
    std::env::set_var(var, "AIza-from-env");
    let remote = Remote { base: api.base.clone(), key_env: Some(var.into()), timeout: Duration::from_secs(2) };
    let engine = Engine::gemini(Layout::new(&dir), remote).unwrap();
    assert_eq!(engine.classify(&unread()).unwrap().tier, "model");
    assert_eq!(api.seen()[0].api_key.as_deref(), Some("AIza-from-env"));
    // The file wins over the env var.
    std::fs::write(dir.join("gemini-key"), "AIza-from-file").unwrap();
    engine.classify(&unread()).unwrap();
    assert_eq!(api.seen()[1].api_key.as_deref(), Some("AIza-from-file"));
    std::env::remove_var(var);
}

#[test]
fn http_errors_each_give_their_503_note_and_a_zero_cost_usage_line() {
    let r = Rig::new("api-status", Mode::Status(401), true);
    let cases = [
        (Mode::KeyInvalid, 400, "bad key"),
        (Mode::Status(401), 401, "bad key"),
        (Mode::Status(403), 403, "bad key"),
        (Mode::Status(429), 429, "rate limited"),
        (Mode::Status(503), 503, "overloaded"),
        (Mode::Status(500), 500, "overloaded"),
        (Mode::Status(400), 400, "remote error"),
        (Mode::Status(404), 404, "remote error"),
    ];
    for (mode, status, note) in cases.clone() {
        r.api.set(mode);
        assert_503(&r.engine, "ready", note);
        let last = r.usage_lines().pop().unwrap();
        assert_eq!((&last["status"], &last["cost_usd"], &last["input_tokens"]), (&json!(status), &json!(0.0), &json!(0)), "{note}");
    }
    assert_eq!(r.usage_lines().len(), cases.len());
}

#[test]
fn a_slow_answer_is_503_timeout_and_writes_no_usage_line() {
    assert_eq!(gemini::TIMEOUT_MS, 2_300, "under the overlay's 2 500 ms");
    let r = Rig::with_timeout("api-slow", Mode::Slow(Duration::from_millis(1500), valid_unread()), true, Duration::from_millis(300));
    let t0 = std::time::Instant::now();
    assert_503(&r.engine, "ready", "timeout");
    assert!(t0.elapsed() < Duration::from_millis(1200), "gave up at the timeout, not at the answer");
    assert!(r.usage_lines().is_empty(), "no response, no usage line");
}

#[test]
fn no_json_text_unparseable_text_or_off_schema_is_malformed_and_still_counted() {
    let r = Rig::new("api-malformed", Mode::Raw(reply(json!([]), "STOP", [500, 20, 0, 0])), true);
    assert_503(&r.engine, "ready", "malformed");
    let l = r.usage_lines().pop().unwrap();
    // (500 * 0.25 + 20 * 1.50) / 1e6
    assert_eq!((&l["status"], &l["cost_usd"]), (&json!(200), &json!(0.000155)), "billed though unusable");
    r.api.set(Mode::Raw(reply(json!([{"text": "I think it drifted."}]), "STOP", [500, 20, 0, 0])));
    assert_503(&r.engine, "ready", "malformed");
    r.api.set(Mode::Raw(reply(json!([{"text": "{\"asked\": tr"}]), "MAX_TOKENS", [500, 300, 0, 0])));
    assert_503(&r.engine, "ready", "malformed");
    r.api.set(json_answer(json!({"asked": "maybe"})));
    assert_503(&r.engine, "ready", "malformed");
    r.api.set(json_answer(json!({"asked": true, "answered": true, "question": null, "extra": 1})));
    assert_503(&r.engine, "ready", "malformed");
    assert_eq!(r.usage_lines().len(), 5);
}

#[test]
fn a_safety_stop_or_a_blocked_prompt_is_blocked_and_still_counted() {
    let r = Rig::new("api-blocked", Mode::Raw(reply(json!([{"text": "{}"}]), "SAFETY", [300, 0, 0, 0])), true);
    assert_503(&r.engine, "ready", "blocked");
    r.api.set(Mode::Raw(json!({"promptFeedback": {"blockReason": "SAFETY"}, "usageMetadata": usage_json([300, 0, 0, 0])})));
    assert_503(&r.engine, "ready", "blocked");
    r.api.set(Mode::Raw(reply(json!([{"text": "{}"}]), "PROHIBITED_CONTENT", [300, 0, 0, 0])));
    assert_503(&r.engine, "ready", "blocked");
    let lines = r.usage_lines();
    assert_eq!(lines.len(), 3);
    assert!(lines.iter().all(|l| l["status"] == 200 && l["cost_usd"] == json!(0.000075)), "{lines:?}");
    assert_eq!(route(&r.engine, "GET", "/health", Value::Null).1["note"], "blocked");
}

#[test]
fn a_refused_connection_is_remote_error_with_no_usage_line() {
    let dir = tmpdir("api-refused");
    std::fs::write(dir.join("gemini-key"), KEY).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let remote = Remote { base: format!("http://127.0.0.1:{port}"), key_env: None, timeout: Duration::from_secs(2) };
    let engine = Engine::gemini(Layout::new(&dir), remote).unwrap();
    let u = unavailable(engine.classify(&unread()));
    assert_eq!((u.state, u.note.as_str()), ("ready", "remote error"));
    assert!(!dir.join("usage.jsonl").exists());
}

#[test]
fn usage_lines_and_the_log_hold_no_transcript_text_labels_or_key() {
    let r = Rig::new("api-private", json_answer(valid_unread()), true);
    r.engine.classify(&unread()).unwrap();
    r.api.set(Mode::Status(429));
    let _ = r.engine.classify(&unread());
    r.api.set(Mode::KeyInvalid);
    let _ = r.engine.classify(&unread());
    let usage = r.usage_text();
    let log = std::fs::read_to_string(r.dir.join("brain.log")).unwrap_or_default();
    for text in [&usage, &log] {
        assert!(!text.contains(SECRET_TEXT) && !text.contains("purple"), "transcript text leaked: {text}");
        assert!(!text.contains("Should I go on?") && !text.contains("answered"), "labels leaked: {text}");
        assert!(!text.contains(KEY) && !text.contains("AIza"), "the key leaked");
    }
    assert_eq!(r.usage_lines().len(), 3);
}

#[test]
fn fail_kind_escalates_to_gemini_and_keeps_the_regex_answer_when_it_fails() {
    let answer = json!({"kind": "build", "n": null, "file": null, "tool": null, "attempt": null});
    let r = Rig::new("api-escalate", json_answer(answer.clone()), true);
    let cue: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "pytest: 3 failed", &[])).unwrap();
    assert_eq!(r.engine.classify(&cue).unwrap().tier, "regex");
    let clean: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "all good", &[])).unwrap();
    assert_eq!(r.engine.classify(&clean).unwrap().tier, "regex");
    assert!(r.api.seen().is_empty(), "a regex hit or a clean run asks nothing");
    let murky: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "something printed Error: odd", &[])).unwrap();
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!((a.tier, &a.labels), ("model", &answer));
    assert_eq!(r.usage_lines()[0]["task"], "fail_kind");
    r.api.set(Mode::Status(503));
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!((a.tier, &a.labels["kind"]), ("regex", &json!("none")), "the regex answer stands");
    std::fs::remove_file(r.dir.join("gemini-key")).unwrap();
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!(a.tier, "regex");
    let q: ClassifyReq = serde_json::from_value(req("extract", "extract@1", "", &[("user", "go")])).unwrap();
    assert_eq!(r.engine.classify(&q).unwrap().tier, "regex");
    assert_eq!(r.api.seen().len(), 2, "extract never calls");
}

#[test]
fn usage_totals_for_today_month_and_all_by_task_with_thought_tokens() {
    // Each success: (1000 * 0.25 + (100 + 20) * 1.50) / 1e6 = 0.00043.
    let r = Rig::new("api-totals", Mode::Json { labels: valid_unread(), usage: [1000, 100, 20, 0] }, true);
    let path = r.dir.join("usage.jsonl");
    // Faked earlier dates, written as the engine writes them.
    let now = Local::now();
    let old = usage::Line::new(now - Days::days(400), "scope_drift", DEFAULT_MODEL, 200, 900, &Usage { input_tokens: 2000, ..Default::default() });
    usage::append(&path, &old).unwrap();
    let earlier_this_month = now.day() > 1;
    if earlier_this_month {
        let noon_on_the_first = now.date_naive().with_day(1).unwrap().and_hms_opt(12, 0, 0).unwrap();
        let first = Local.from_local_datetime(&noon_on_the_first).earliest().unwrap();
        let line = usage::Line::new(first, "contradiction", DEFAULT_MODEL, 200, 900, &Usage { output_tokens: 1000, ..Default::default() });
        usage::append(&path, &line).unwrap();
    }
    // Today: 2 x unread_reply, 1 x contradiction, 1 rate-limited.
    r.engine.classify(&unread()).unwrap();
    r.engine.classify(&unread()).unwrap();
    let contra: ClassifyReq = serde_json::from_value(req("contradiction", "contradiction@1", "", &[("user", "a"), ("user", "b")])).unwrap();
    r.api.set(Mode::Json { labels: json!({"contradicts": false, "earlier": null, "later": null}), usage: [1000, 100, 20, 0] });
    r.engine.classify(&contra).unwrap();
    r.api.set(Mode::Status(429));
    let _ = r.engine.classify(&unread());

    let (c, v) = route(&r.engine, "GET", "/usage", Value::Null);
    assert_eq!(c, 200);
    assert_eq!((&v["contract"], &v["model"], &v["note"]), (&json!(1), &json!(DEFAULT_MODEL), &Value::Null));
    assert_eq!(
        v["today"],
        json!({"calls": 4, "errors": 1, "input_tokens": 3000, "output_tokens": 300, "thought_tokens": 60, "cost_usd": 0.00129,
               "by_task": {"contradiction": {"calls": 1, "cost_usd": 0.00043}, "unread_reply": {"calls": 3, "cost_usd": 0.00086}}})
    );
    // The first of the month: 1000 output tokens = 0.0015. 400 days ago: 2000 input = 0.0005.
    let (m_calls, m_cost, all_cost, m_contra) = if earlier_this_month {
        (5, 0.00279, 0.00329, json!({"calls": 2, "cost_usd": 0.00193}))
    } else {
        (4, 0.00129, 0.00179, json!({"calls": 1, "cost_usd": 0.00043}))
    };
    assert_eq!((&v["month"]["calls"], &v["month"]["cost_usd"]), (&json!(m_calls), &json!(m_cost)));
    assert_eq!(v["month"]["by_task"]["contradiction"], m_contra);
    assert_eq!(v["month"]["thought_tokens"], 60);
    assert!(v["month"]["by_task"].get("scope_drift").is_none(), "400 days ago is not this month");
    assert_eq!(v["all"]["calls"], m_calls + 1);
    assert_eq!(v["all"]["errors"], 1);
    assert_eq!(v["all"]["input_tokens"], 5000);
    assert_eq!(v["all"]["thought_tokens"], 60);
    assert_eq!(v["all"]["by_task"]["scope_drift"], json!({"calls": 1, "cost_usd": 0.0005}));
    assert_eq!(v["all"]["cost_usd"], json!(all_cost));
    // /health carries the month.
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(h["month_cost_usd"], json!(m_cost));
    // Same token auth as every route.
    assert_eq!(server::route(&r.engine, "t", "GET", "/usage", None, b"").0, 401);
}

#[test]
fn an_unknown_model_logs_a_null_cost_and_usage_says_so() {
    let r = Rig::new("api-unpriced", json_answer(valid_unread()), true);
    std::fs::write(r.dir.join("brain.json"), r#"{"model":"gemini-9-mystery"}"#).unwrap();
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
    assert_eq!(r.api.seen()[0].url, "/v1beta/models/gemini-9-mystery:generateContent");
    let l = r.usage_lines().pop().unwrap();
    assert_eq!((&l["model"], &l["cost_usd"], &l["input_tokens"]), (&json!("gemini-9-mystery"), &Value::Null, &json!(1000)));
    let (_, v) = route(&r.engine, "GET", "/usage", Value::Null);
    assert_eq!(v["model"], "gemini-9-mystery");
    assert_eq!((&v["today"]["calls"], &v["today"]["cost_usd"]), (&json!(1), &json!(0.0)));
    assert!(v["note"].as_str().unwrap().contains("no price for gemini-9-mystery"), "{v}");
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!((&h["model"], &h["month_cost_usd"]), (&json!("gemini-9-mystery"), &json!(0.0)));
}

#[test]
fn health_says_whether_a_key_is_there_and_never_what_it_is() {
    let r = Rig::new("api-health", json_answer(valid_unread()), false);
    let (c, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(c, 200);
    assert_eq!(
        h,
        json!({"contract": 1, "backend": "gemini", "model": DEFAULT_MODEL, "state": "unconfigured",
               "key": "missing", "month_cost_usd": 0.0, "note": null})
    );
    std::fs::write(r.dir.join("gemini-key"), KEY).unwrap();
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!((&h["state"], &h["key"]), (&json!("ready"), &json!("present")));
    assert!(!h.to_string().contains(KEY) && !h.to_string().contains("AIza"), "{h}");
    // The last failure's note, cleared by the next answer.
    r.api.set(Mode::Status(429));
    let _ = r.engine.classify(&unread());
    assert_eq!(route(&r.engine, "GET", "/health", Value::Null).1["note"], "rate limited");
    r.api.set(json_answer(valid_unread()));
    r.engine.classify(&unread()).unwrap();
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(h["note"], Value::Null);
    assert_eq!(h["month_cost_usd"], JSON_ANSWER_COST);
    // No route echoes the key: a 503 neither.
    r.api.set(Mode::KeyInvalid);
    let (_, v) = route(&r.engine, "POST", "/classify", unread_json());
    assert_eq!(v["note"], "bad key");
    assert!(!v.to_string().contains(KEY));
}
