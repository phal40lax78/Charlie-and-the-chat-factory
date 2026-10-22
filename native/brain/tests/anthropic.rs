//! Tier 0: the `anthropic` backend (Claude Haiku) against a local mock
//! Messages API (`testutil::MockAnthropic`): request body and headers, the
//! forced tool call, 503 notes, usage lines with cache tokens and cost,
//! `/usage`, `/health`, and the key kept out of every log, line and body.
//! Nothing here leaves 127.0.0.1.

use chatq_brain::anthropic::{self, Usage, DEFAULT_MODEL};
use chatq_brain::api::{Answer, ClassifyReq};
use chatq_brain::catalogue::{self, TASKS};
use chatq_brain::config::Layout;
use chatq_brain::engine::{ClassifyErr, Engine, Remote};
use chatq_brain::server;
use chatq_brain::testutil::{tmpdir, ClaudeMode as Mode, MockAnthropic};
use chatq_brain::usage;
use chrono::{Datelike, Duration as Days, Local, TimeZone};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;

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

const KEY: &str = "sk-ant-test-0123456789abcdef";
const SECRET_TEXT: &str = "the purple elephant refactor";

struct Rig {
    dir: PathBuf,
    engine: Engine,
    api: MockAnthropic,
}

impl Rig {
    fn new(name: &str, mode: Mode, with_key: bool) -> Rig {
        Rig::with_timeout(name, mode, with_key, Duration::from_millis(anthropic::TIMEOUT_MS))
    }
    fn with_timeout(name: &str, mode: Mode, with_key: bool, timeout: Duration) -> Rig {
        let dir = tmpdir(name);
        std::fs::write(dir.join("brain.json"), r#"{"backend":"anthropic"}"#).unwrap();
        if with_key {
            std::fs::write(dir.join("anthropic-key"), format!("{KEY}\n")).unwrap();
        }
        let api = MockAnthropic::start(mode);
        let remote = Remote { base: api.base.clone(), key_env: None, timeout };
        let engine = Engine::anthropic(Layout::new(&dir), remote).unwrap();
        Rig { dir, engine, api }
    }
    fn usage_lines(&self) -> Vec<Value> {
        self.usage_text().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
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

/// 1000 fresh input, 100 out, 200 cache writes, 300 cache reads.
fn tool(input: Value) -> Mode {
    Mode::Tool { input, usage: [1000, 100, 200, 300] }
}

/// (1000 * 1.00 + 100 * 5.00 + 200 * 1.25 + 300 * 0.10) / 1e6 at Haiku 4.5.
const TOOL_COST: f64 = 0.00178;

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
fn a_success_returns_validated_labels_and_one_usage_line_with_cache_tokens_and_cost() {
    let r = Rig::new("claude-ok", tool(valid_unread()), true);
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
        [
            "cache_creation_input_tokens", "cache_read_input_tokens", "cached_tokens", "cost_usd", "input_tokens", "model", "ms",
            "output_tokens", "status", "task", "thought_tokens", "ts"
        ]
    );
    assert_eq!((&l["task"], &l["model"], &l["status"]), (&json!("unread_reply"), &json!(DEFAULT_MODEL), &json!(200)));
    assert_eq!((&l["input_tokens"], &l["output_tokens"]), (&json!(1000), &json!(100)));
    assert_eq!((&l["cache_creation_input_tokens"], &l["cache_read_input_tokens"]), (&json!(200), &json!(300)));
    assert_eq!((&l["thought_tokens"], &l["cached_tokens"]), (&json!(0), &json!(0)));
    assert_eq!(l["cost_usd"], TOOL_COST);
    assert!(chrono::DateTime::parse_from_rfc3339(l["ts"].as_str().unwrap()).is_ok());
}

#[test]
fn the_request_forces_the_task_tool_and_carries_the_key_in_x_api_key_only() {
    assert_eq!(DEFAULT_MODEL, "claude-haiku-4-5-20251001");
    let r = Rig::new("claude-body", tool(valid_unread()), true);
    r.engine.classify(&unread()).unwrap();
    let seen = r.api.seen();
    assert_eq!(seen.len(), 1);
    let s = &seen[0];
    assert_eq!((s.method.as_str(), s.path.as_str()), ("POST", "/v1/messages"));
    assert_eq!(s.api_key.as_deref(), Some(KEY));
    assert_eq!(s.version.as_deref(), Some("2023-06-01"));
    assert_eq!(s.content_type.as_deref(), Some("application/json"));
    let carrying: Vec<&str> = s.headers.iter().filter(|(_, v)| v.contains(KEY)).map(|(n, _)| n.as_str()).collect();
    assert_eq!(carrying.len(), 1);
    assert!(carrying[0].eq_ignore_ascii_case("x-api-key"), "{carrying:?}");
    assert!(!s.path.contains(KEY));
    let t = catalogue::find("unread_reply", "unread_reply@1").unwrap();
    let b = &s.body;
    assert!(!b.to_string().contains(KEY));
    assert_eq!(b["model"], DEFAULT_MODEL);
    assert_eq!(b["max_tokens"], 300);
    assert_eq!(b["temperature"], 0);
    assert_eq!(b["system"], t.system);
    assert_eq!(b["tool_choice"], json!({"type": "tool", "name": "unread_reply"}));
    assert_eq!(b["tools"].as_array().unwrap().len(), 1);
    assert_eq!(b["tools"][0]["name"], "unread_reply");
    assert!(b["tools"][0]["description"].as_str().unwrap().len() > 10);
    assert_eq!(b["tools"][0]["input_schema"], t.schema_value());
    assert_eq!(b["messages"].as_array().unwrap().len(), 1);
    assert_eq!(b["messages"][0]["role"], "user");
    assert_eq!(b["messages"][0]["content"], format!("[assistant] Should I do {SECRET_TEXT}?\n[user] ok\n"));

    // brain.json picks the model: the anthropic section, else the top-level one.
    std::fs::write(r.dir.join("brain.json"), r#"{"backend":"anthropic","model":"claude-haiku-4-5"}"#).unwrap();
    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.api.seen()[1].body["model"], "claude-haiku-4-5");
    assert_eq!(r.usage_lines()[1]["model"], "claude-haiku-4-5");
    assert_eq!(r.usage_lines()[1]["cost_usd"], TOOL_COST, "the undated id has the same price row");
    std::fs::write(r.dir.join("brain.json"), r#"{"backend":"anthropic","model":"x","anthropic":{"model":"claude-haiku-4-5-20251001"}}"#)
        .unwrap();
    r.engine.classify(&unread()).unwrap();
    assert_eq!(r.api.seen()[2].body["model"], "claude-haiku-4-5-20251001");
}

#[test]
fn no_key_is_503_no_key_with_no_call_and_no_usage_line() {
    let r = Rig::new("claude-nokey", tool(valid_unread()), false);
    assert_503(&r.engine, "unconfigured", "no key");
    assert!(r.api.seen().is_empty(), "nothing was sent");
    assert!(!r.dir.join("usage.jsonl").exists());
    for t in TASKS.iter().filter(|t| t.model_tier) {
        let (c, v) = route(&r.engine, "POST", "/classify", req(t.name, &t.schema_id(), "", &[("user", "x")]));
        assert_eq!(c, 503, "{}", t.name);
        assert!(v.get("labels").is_none() && v.get("tier").is_none(), "{}: {v}", t.name);
    }
    // The Gemini key is not the Claude key; a blank file is no key.
    std::fs::write(r.dir.join("gemini-key"), "AIza-not-for-claude").unwrap();
    assert_503(&r.engine, "unconfigured", "no key");
    std::fs::write(r.dir.join("anthropic-key"), " \n").unwrap();
    assert_503(&r.engine, "unconfigured", "no key");
    assert!(r.api.seen().is_empty());
}

#[test]
fn the_key_env_var_is_the_fallback_and_the_file_wins() {
    assert_eq!(anthropic::KEY_ENV, "ANTHROPIC_API_KEY");
    let dir = tmpdir("claude-envkey");
    let api = MockAnthropic::start(tool(valid_unread()));
    let var = "CHATQ_BRAIN_TEST_ANTHROPIC_KEY_FALLBACK";
    std::env::set_var(var, "sk-ant-from-env");
    let remote = Remote { base: api.base.clone(), key_env: Some(var.into()), timeout: Duration::from_secs(2) };
    let engine = Engine::anthropic(Layout::new(&dir), remote).unwrap();
    assert_eq!(engine.classify(&unread()).unwrap().tier, "model");
    assert_eq!(api.seen()[0].api_key.as_deref(), Some("sk-ant-from-env"));
    std::fs::write(dir.join("anthropic-key"), "sk-ant-from-file").unwrap();
    engine.classify(&unread()).unwrap();
    assert_eq!(api.seen()[1].api_key.as_deref(), Some("sk-ant-from-file"));
    std::env::remove_var(var);
}

#[test]
fn http_errors_each_give_their_503_note_and_a_zero_cost_usage_line() {
    let r = Rig::new("claude-status", Mode::Status(401), true);
    let cases = [
        (401, "bad key"),
        (403, "bad key"),
        (429, "rate limited"),
        (529, "overloaded"),
        (503, "overloaded"),
        (500, "overloaded"),
        (400, "remote error"),
        (404, "remote error"),
    ];
    for (status, note) in cases {
        r.api.set(Mode::Status(status));
        assert_503(&r.engine, "ready", note);
        let last = r.usage_lines().pop().unwrap();
        assert_eq!(
            (&last["status"], &last["cost_usd"], &last["input_tokens"]),
            (&json!(status), &json!(0.0), &json!(0)),
            "{status}"
        );
        assert_eq!(route(&r.engine, "GET", "/health", Value::Null).1["note"], note, "{status}");
    }
    assert_eq!(r.usage_lines().len(), cases.len());
}

#[test]
fn a_slow_answer_is_503_timeout_and_writes_no_usage_line() {
    assert_eq!(anthropic::TIMEOUT_MS, 2_300, "under the overlay's 2 500 ms");
    let r = Rig::with_timeout("claude-slow", Mode::Slow(Duration::from_millis(1500), valid_unread()), true, Duration::from_millis(300));
    let t0 = std::time::Instant::now();
    assert_503(&r.engine, "ready", "timeout");
    assert!(t0.elapsed() < Duration::from_millis(1200), "gave up at the timeout, not at the answer");
    assert!(r.usage_lines().is_empty(), "no response, no usage line");
}

#[test]
fn no_tool_block_garbage_or_off_schema_input_is_malformed_and_still_counted() {
    let r = Rig::new("claude-malformed", Mode::NoTool { usage: [500, 20, 0, 0] }, true);
    assert_503(&r.engine, "ready", "malformed");
    let l = r.usage_lines().pop().unwrap();
    // (500 * 1.00 + 20 * 5.00) / 1e6
    assert_eq!((&l["status"], &l["cost_usd"]), (&json!(200), &json!(0.0006)), "billed though unusable");
    r.api.set(tool(json!({"asked": "maybe"})));
    assert_503(&r.engine, "ready", "malformed");
    r.api.set(tool(json!({"asked": true, "answered": true, "question": null, "extra": 1})));
    assert_503(&r.engine, "ready", "malformed");
    r.api.set(Mode::Garbage);
    assert_503(&r.engine, "ready", "malformed");
    let l = r.usage_lines().pop().unwrap();
    assert_eq!((&l["status"], &l["cost_usd"]), (&json!(200), &json!(0.0)));
    assert_eq!(r.usage_lines().len(), 4);
}

#[test]
fn a_refusal_is_blocked_and_still_counted() {
    let r = Rig::new("claude-refusal", Mode::Refusal { usage: [300, 0, 0, 0] }, true);
    assert_503(&r.engine, "ready", "blocked");
    let l = r.usage_lines().pop().unwrap();
    assert_eq!((&l["status"], &l["cost_usd"]), (&json!(200), &json!(0.0003)));
    assert_eq!(route(&r.engine, "GET", "/health", Value::Null).1["note"], "blocked");
}

#[test]
fn a_refused_connection_is_remote_error_with_no_usage_line() {
    let dir = tmpdir("claude-refused");
    std::fs::write(dir.join("anthropic-key"), KEY).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let remote = Remote { base: format!("http://127.0.0.1:{port}"), key_env: None, timeout: Duration::from_secs(2) };
    let engine = Engine::anthropic(Layout::new(&dir), remote).unwrap();
    let u = unavailable(engine.classify(&unread()));
    assert_eq!((u.state, u.note.as_str()), ("ready", "remote error"));
    assert!(!dir.join("usage.jsonl").exists());
}

#[test]
fn usage_lines_the_log_and_every_body_hold_no_transcript_text_labels_or_key() {
    let r = Rig::new("claude-private", tool(valid_unread()), true);
    let mut bodies = Vec::new();
    bodies.push(route(&r.engine, "POST", "/classify", unread_json()).1);
    for mode in [Mode::Status(429), Mode::Status(401), Mode::Garbage, Mode::Refusal { usage: [1, 0, 0, 0] }] {
        r.api.set(mode);
        bodies.push(route(&r.engine, "POST", "/classify", unread_json()).1);
    }
    bodies.push(route(&r.engine, "GET", "/health", Value::Null).1);
    bodies.push(route(&r.engine, "GET", "/usage", Value::Null).1);
    let usage = r.usage_text();
    let log = std::fs::read_to_string(r.dir.join("brain.log")).unwrap_or_default();
    assert!(!log.is_empty(), "the calls were logged");
    for text in [&usage, &log] {
        assert!(!text.contains(SECRET_TEXT) && !text.contains("purple"), "transcript text leaked into a file");
        assert!(!text.contains("Should I go on?") && !text.contains("answered"), "labels leaked into a file");
        assert!(!text.contains(KEY) && !text.contains("sk-ant"), "the key leaked into a file");
    }
    for b in &bodies {
        assert!(!b.to_string().contains(KEY) && !b.to_string().contains("sk-ant"), "the key leaked into a response");
    }
    assert_eq!(r.usage_lines().len(), 5);
}

#[test]
fn fail_kind_escalates_to_haiku_and_keeps_the_regex_answer_when_it_fails() {
    let answer = json!({"kind": "build", "n": null, "file": null, "tool": null, "attempt": null});
    let r = Rig::new("claude-escalate", tool(answer.clone()), true);
    let cue: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "pytest: 3 failed", &[])).unwrap();
    assert_eq!(r.engine.classify(&cue).unwrap().tier, "regex");
    let clean: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "all good", &[])).unwrap();
    assert_eq!(r.engine.classify(&clean).unwrap().tier, "regex");
    assert!(r.api.seen().is_empty(), "a regex hit or a clean run asks nothing");
    let murky: ClassifyReq = serde_json::from_value(req("fail_kind", "fail_kind@1", "something printed Error: odd", &[])).unwrap();
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!((a.tier, &a.labels), ("model", &answer));
    assert_eq!(r.api.seen()[0].body["tool_choice"]["name"], "fail_kind");
    assert_eq!(r.usage_lines()[0]["task"], "fail_kind");
    r.api.set(Mode::Status(529));
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!((a.tier, &a.labels["kind"]), ("regex", &json!("none")), "the regex answer stands");
    std::fs::remove_file(r.dir.join("anthropic-key")).unwrap();
    let a = r.engine.classify(&murky).unwrap();
    assert_eq!(a.tier, "regex");
    let q: ClassifyReq = serde_json::from_value(req("extract", "extract@1", "", &[("user", "go")])).unwrap();
    assert_eq!(r.engine.classify(&q).unwrap().tier, "regex");
    assert_eq!(r.api.seen().len(), 2, "extract never calls");
}

#[test]
fn usage_totals_for_today_month_and_all_by_task() {
    let r = Rig::new("claude-totals", Mode::Tool { input: valid_unread(), usage: [1000, 100, 0, 0] }, true);
    let path = r.dir.join("usage.jsonl");
    // Faked earlier dates, written as the engine writes them.
    let now = Local::now();
    let old = usage::Line::anthropic(now - Days::days(400), "scope_drift", DEFAULT_MODEL, 200, 900, &Usage { input_tokens: 2000, ..Default::default() });
    usage::append(&path, &old).unwrap();
    let earlier_this_month = now.day() > 1;
    if earlier_this_month {
        let noon_on_the_first = now.date_naive().with_day(1).unwrap().and_hms_opt(12, 0, 0).unwrap();
        let first = Local.from_local_datetime(&noon_on_the_first).earliest().unwrap();
        let line = usage::Line::anthropic(first, "contradiction", DEFAULT_MODEL, 200, 900, &Usage { output_tokens: 1000, ..Default::default() });
        usage::append(&path, &line).unwrap();
    }
    // Today: 2 x unread_reply, 1 x contradiction, 1 rate-limited.
    r.engine.classify(&unread()).unwrap();
    r.engine.classify(&unread()).unwrap();
    let contra: ClassifyReq = serde_json::from_value(req("contradiction", "contradiction@1", "", &[("user", "a"), ("user", "b")])).unwrap();
    r.api.set(Mode::Tool { input: json!({"contradicts": false, "earlier": null, "later": null}), usage: [1000, 100, 0, 0] });
    r.engine.classify(&contra).unwrap();
    r.api.set(Mode::Status(429));
    let _ = r.engine.classify(&unread());

    let (c, v) = route(&r.engine, "GET", "/usage", Value::Null);
    assert_eq!(c, 200);
    assert_eq!((&v["contract"], &v["model"], &v["note"]), (&json!(1), &json!(DEFAULT_MODEL), &Value::Null));
    // Each success: 1000 * 1.00 + 100 * 5.00 = 1500 per million = 0.0015.
    assert_eq!(
        v["today"],
        json!({"calls": 4, "errors": 1, "input_tokens": 3000, "output_tokens": 300, "thought_tokens": 0, "cost_usd": 0.0045,
               "by_task": {"contradiction": {"calls": 1, "cost_usd": 0.0015}, "unread_reply": {"calls": 3, "cost_usd": 0.003}}})
    );
    // The first of the month: 1000 output tokens = 0.005. 400 days ago: 2000 input = 0.002.
    let (m_calls, m_cost, all_cost, m_contra) = if earlier_this_month {
        (5, 0.0095, 0.0115, json!({"calls": 2, "cost_usd": 0.0065}))
    } else {
        (4, 0.0045, 0.0065, json!({"calls": 1, "cost_usd": 0.0015}))
    };
    assert_eq!((&v["month"]["calls"], &v["month"]["cost_usd"]), (&json!(m_calls), &json!(m_cost)));
    assert_eq!(v["month"]["by_task"]["contradiction"], m_contra);
    assert!(v["month"]["by_task"].get("scope_drift").is_none(), "400 days ago is not this month");
    assert_eq!(v["all"]["calls"], m_calls + 1);
    assert_eq!(v["all"]["errors"], 1);
    assert_eq!(v["all"]["input_tokens"], 5000);
    assert_eq!(v["all"]["by_task"]["scope_drift"], json!({"calls": 1, "cost_usd": 0.002}));
    assert_eq!(v["all"]["cost_usd"], json!(all_cost));
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(h["month_cost_usd"], json!(m_cost));
    assert_eq!(server::route(&r.engine, "t", "GET", "/usage", None, b"").0, 401);
}

#[test]
fn an_unpriced_claude_model_logs_a_null_cost_and_usage_says_so() {
    let r = Rig::new("claude-unpriced", tool(valid_unread()), true);
    std::fs::write(r.dir.join("brain.json"), r#"{"backend":"anthropic","anthropic":{"model":"claude-mystery-9"}}"#).unwrap();
    assert_eq!(r.engine.classify(&unread()).unwrap().tier, "model");
    let l = r.usage_lines().pop().unwrap();
    assert_eq!((&l["model"], &l["cost_usd"]), (&json!("claude-mystery-9"), &Value::Null));
    let (_, v) = route(&r.engine, "GET", "/usage", Value::Null);
    assert!(v["note"].as_str().unwrap().contains("no price for claude-mystery-9"), "{v}");
}

#[test]
fn health_says_whether_a_key_is_there_and_never_what_it_is() {
    let r = Rig::new("claude-health", tool(valid_unread()), false);
    let (c, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(c, 200);
    assert_eq!(
        h,
        json!({"contract": 1, "backend": "anthropic", "model": DEFAULT_MODEL, "state": "unconfigured",
               "key": "missing", "month_cost_usd": 0.0, "note": null})
    );
    std::fs::write(r.dir.join("anthropic-key"), KEY).unwrap();
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!((&h["state"], &h["key"]), (&json!("ready"), &json!("present")));
    assert!(!h.to_string().contains(KEY) && !h.to_string().contains("sk-"));
    // The last failure's note, cleared by the next answer.
    r.api.set(Mode::Status(429));
    let _ = r.engine.classify(&unread());
    assert_eq!(route(&r.engine, "GET", "/health", Value::Null).1["note"], "rate limited");
    r.api.set(tool(valid_unread()));
    r.engine.classify(&unread()).unwrap();
    let (_, h) = route(&r.engine, "GET", "/health", Value::Null);
    assert_eq!(h["note"], Value::Null);
    assert_eq!(h["month_cost_usd"], TOOL_COST);
}
