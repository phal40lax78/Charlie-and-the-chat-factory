//! Tier 0: `brain.json` `"backend"` picks the engine, an unknown one stops
//! the start, and `/install` and `/unload` exist on the local backend only.
//! Nothing here leaves 127.0.0.1: no request is sent at all.

use chatq_brain::anthropic;
use chatq_brain::config::{Layout, DEFAULT_MODEL};
use chatq_brain::engine::{Engine, Remote};
use chatq_brain::server;
use chatq_brain::testutil::tmpdir;
use serde_json::{json, Value};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn route(engine: &Engine, method: &str, path: &str, body: Value) -> (u16, Value) {
    let (c, v) = server::route(engine, "t", method, path, Some("Bearer t"), body.to_string().as_bytes());
    (c, v.unwrap_or(Value::Null))
}

fn with_brain(name: &str, brain: Option<&str>) -> Layout {
    let dir = tmpdir(name);
    if let Some(b) = brain {
        std::fs::write(dir.join("brain.json"), b).unwrap();
    }
    Layout::new(dir)
}

fn engine(name: &str, brain: Option<&str>) -> Engine {
    match Engine::from_config(with_brain(name, brain)) {
        Ok(e) => e,
        Err(e) => panic!("{name}: {e}"),
    }
}

/// `(backend, model)` as `/health` reports them. The health body is never
/// printed: with a key in the environment it still holds none, but the
/// test does not lean on that.
fn backend_and_model(e: &Engine) -> (String, Value) {
    let h = e.health();
    (h["backend"].as_str().unwrap_or("").to_string(), h["model"].clone())
}

#[test]
fn brain_json_backend_picks_the_engine_and_each_backend_its_own_model() {
    let cases: [(&str, Option<&str>, &str, Value); 9] = [
        ("sel-none", None, "gemini", json!(DEFAULT_MODEL)),
        ("sel-empty", Some("{}"), "gemini", json!(DEFAULT_MODEL)),
        ("sel-gemini", Some(r#"{"backend":"gemini","model":"gemini-2.5-flash-lite"}"#), "gemini", json!("gemini-2.5-flash-lite")),
        ("sel-claude", Some(r#"{"backend":"anthropic"}"#), "anthropic", json!(anthropic::DEFAULT_MODEL)),
        // The top-level model belongs to the configured backend only.
        (
            "sel-claude-top",
            Some(r#"{"backend":"anthropic","model":"claude-haiku-4-5","gemini":{"model":"gemini-2.5-flash"}}"#),
            "anthropic",
            json!("claude-haiku-4-5"),
        ),
        ("sel-claude-section", Some(r#"{"backend":"anthropic","anthropic":{"model":"claude-x-1"}}"#), "anthropic", json!("claude-x-1")),
        ("sel-gemini-ignores-claude", Some(r#"{"anthropic":{"model":"claude-x-1"}}"#), "gemini", json!(DEFAULT_MODEL)),
        ("sel-local", Some(r#"{"backend":"local"}"#), "local", json!("phi-4-mini-q4km")),
        ("sel-local-model", Some(r#"{"backend":"local","local":{"model":"llama-3.2-1b-q4km"}}"#), "local", json!("llama-3.2-1b-q4km")),
    ];
    for (name, brain, want_backend, want_model) in cases {
        let e = engine(name, brain);
        assert_eq!(e.backend(), want_backend, "{name}");
        assert_eq!(backend_and_model(&e), (want_backend.to_string(), want_model.clone()), "{name}");
        assert_eq!(route(&e, "GET", "/usage", Value::Null).1["model"], want_model, "{name}: /usage names it too");
        e.shutdown();
    }
}

#[test]
fn a_local_engine_from_config_starts_absent_and_fetches_nothing() {
    let e = engine("sel-local-health", Some(r#"{"backend":"local","local":{"model":"llama-3.2-1b-q4km"}}"#));
    let h = e.health();
    assert_eq!((&h["contract"], &h["backend"], &h["state"]), (&json!(1), &json!("local"), &json!("absent")));
    assert_eq!((&h["download_pct"], &h["note"], &h["idle_s"]), (&Value::Null, &Value::Null, &json!(0)));
    let u = route(&e, "GET", "/usage", Value::Null).1;
    assert_eq!((&u["note"], &u["today"]["calls"]), (&Value::Null, &json!(0)), "a local model is never unpriced");
    // A model task with nothing on disk: 503, and no download starts.
    let (c, v) = route(
        &e,
        "POST",
        "/classify",
        json!({"task": "unread_reply", "schema_id": "unread_reply@1", "transcript_tail": {"turns": [{"role": "user", "text": "x"}], "tool_out": ""}}),
    );
    assert_eq!((c, v), (503, json!({"contract": 1, "state": "absent", "note": "not installed"})));
    assert_eq!(e.health()["state"], "absent");
}

fn start_error(name: &str, brain: &str) -> String {
    match Engine::from_config(with_brain(name, Some(brain))) {
        Ok(e) => panic!("{name}: started as {}", e.backend()),
        Err(e) => e,
    }
}

#[test]
fn an_unknown_backend_is_an_error_not_a_fallback() {
    for (i, b) in [r#"{"backend":"openai"}"#, r#"{"backend":"Gemini"}"#, r#"{"backend":""}"#, r#"{"backend":5}"#].iter().enumerate() {
        let e = start_error(&format!("sel-unknown-{i}"), b);
        assert!(e.contains("unknown backend"), "{b}: {e}");
        for name in ["\"gemini\"", "\"anthropic\"", "\"local\""] {
            assert!(e.contains(name), "{b}: the message lists {name}: {e}");
        }
    }
    assert!(start_error("sel-unknown-name", r#"{"backend":"openai"}"#).contains("openai"), "and names what it read");
}

#[test]
fn the_exe_refuses_to_start_on_an_unknown_backend() {
    let dir = tmpdir("sel-exe");
    std::fs::write(dir.join("brain.json"), r#"{"backend":"llamafile"}"#).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_chatq-brain"))
        .args(["--data".as_ref(), dir.as_os_str()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let t0 = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        if t0.elapsed() > Duration::from_secs(20) {
            let _ = child.kill();
            panic!("chatq-brain started on an unknown backend");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("unknown backend") && stderr.contains("llamafile"), "{stderr}");
    assert!(!Path::new(&dir.join("port")).exists() && !dir.join("token").exists(), "never listened");
    let log = std::fs::read_to_string(dir.join("brain.log")).unwrap_or_default();
    assert!(log.contains("not started: brain.json: unknown backend"), "{log}");
}

#[test]
fn install_and_unload_exist_on_the_local_backend_only() {
    let dead = Remote { base: "http://127.0.0.1:9".into(), key_env: None, timeout: Duration::from_millis(200) };
    let gemini = Engine::gemini(Layout::new(tmpdir("sel-routes-g")), dead.clone()).unwrap();
    let claude = Engine::anthropic(Layout::new(tmpdir("sel-routes-a")), dead).unwrap();
    for e in [&gemini, &claude] {
        for path in ["/install", "/unload"] {
            assert_eq!(route(e, "POST", path, json!({"model": "phi-4-mini-q4km"})).0, 404, "{} {path}", e.backend());
            assert_eq!(route(e, "GET", path, Value::Null).0, 404, "{} {path}", e.backend());
        }
    }
    let local = engine("sel-routes-l", Some(r#"{"backend":"local"}"#));
    assert_eq!(route(&local, "POST", "/unload", json!({})), (200, json!({"contract": 1, "state": "absent"})));
    assert_eq!(route(&local, "GET", "/install", Value::Null).0, 405);
    assert_eq!(route(&local, "GET", "/unload", Value::Null).0, 405);
    assert_eq!(route(&local, "POST", "/install", json!({"nonsense": true})).0, 400);
    // Same token auth as every route.
    assert_eq!(server::route(&local, "t", "POST", "/install", None, b"{}").0, 401);
    assert_eq!(server::route(&local, "t", "POST", "/unload", Some("Bearer x"), b"{}").0, 401);
}
