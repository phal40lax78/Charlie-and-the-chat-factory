//! TEST-ONLY stand-in for llama-server, launched by the real supervisor in
//! tests/contract.rs. Speaks the two routes the brain uses: `GET /health`
//! and `POST /v1/chat/completions`.
//!
//! The "model" file (`-m <path>`) is its script, re-read on every request:
//! `{"answer": <labels>, "raw": "<content text>", "delay_ms": n,
//!   "die_on_ask": bool, "start_ms": n}`. Beside it, it writes
//! `<path>.args` (its flags, one per line) and `<path>.port`.

use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;

fn script(path: &PathBuf) -> Value {
    std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let after = |flag: &str| args.iter().skip_while(|a| *a != flag).nth(1).cloned();
    let port: u16 = after("--port").and_then(|p| p.parse().ok()).expect("--port");
    let host = after("--host").unwrap_or_else(|| "127.0.0.1".into());
    let model = PathBuf::from(after("-m").expect("-m"));
    let side = |ext: &str| {
        let mut p = model.clone().into_os_string();
        p.push(ext);
        PathBuf::from(p)
    };
    let _ = std::fs::write(side(".args"), args.join("\n"));
    let _ = std::fs::write(side(".port"), port.to_string());
    if let Some(ms) = script(&model)["start_ms"].as_u64() {
        std::thread::sleep(Duration::from_millis(ms));
    }
    let server = tiny_http::Server::http((host.as_str(), port)).expect("bind");
    for mut req in server.incoming_requests() {
        let model = model.clone();
        std::thread::spawn(move || {
            let mut body = String::new();
            let _ = req.as_reader().read_to_string(&mut body);
            let ct = tiny_http::Header::from_bytes("content-type", "application/json").unwrap();
            if req.url() == "/health" {
                let _ = req.respond(tiny_http::Response::from_string(r#"{"status":"ok"}"#).with_header(ct));
                return;
            }
            let s = script(&model);
            if s["die_on_ask"] == true {
                std::process::exit(3);
            }
            if let Some(ms) = s["delay_ms"].as_u64() {
                std::thread::sleep(Duration::from_millis(ms));
            }
            let content = match s["raw"].as_str() {
                Some(raw) => raw.to_string(),
                None => s["answer"].to_string(),
            };
            let out = json!({
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 123, "completion_tokens": 9, "total_tokens": 132},
            });
            let _ = req.respond(tiny_http::Response::from_string(out.to_string()).with_header(ct));
        });
    }
}
