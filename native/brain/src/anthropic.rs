//! The `anthropic` backend's model call (SPEC.md section 2): Claude Haiku
//! through the Anthropic Messages API, one forced tool call per
//! classification, temperature 0. The tool's
//! input schema is the task's labels schema, so the answer arrives as the
//! `tool_use` block's `input`; the engine validates it before it counts.

use crate::api::Tail;
use serde_json::{json, Value};
use std::io;
use std::sync::Arc;
use std::time::Duration;

/// Where requests go unless [BASE_ENV] says otherwise.
pub const DEFAULT_BASE: &str = "https://api.anthropic.com";
/// TEST-ONLY: points the brain at a local mock Anthropic server. Never set it
/// in a real install; the key would go wherever it points.
pub const BASE_ENV: &str = "CHATQ_BRAIN_API_BASE";
/// The env var read when `data/brain/anthropic-key` is missing.
pub const KEY_ENV: &str = "ANTHROPIC_API_KEY";
/// The model asked when `brain.json` names none for this backend.
pub const DEFAULT_MODEL: &str = "claude-haiku-4-5-20251001";
pub const API_VERSION: &str = "2023-06-01";
/// Whole-request timeout. Under the overlay's 2 500 ms client timeout, so a
/// slow answer comes back as 503 `timeout` before the overlay gives up.
pub const TIMEOUT_MS: u64 = 2_300;
pub const MAX_TOKENS: u32 = 300;

/// `[user] ...` / `[assistant] ...` / `[tool] ...`, newest last.
pub fn render_tail(tail: &Tail) -> String {
    let mut s = String::new();
    for t in &tail.turns {
        s.push_str(&format!("[{}] {}\n", t.role, t.text));
    }
    if !tail.tool_out.is_empty() {
        s.push_str(&format!("[tool] {}\n", tail.tool_out));
    }
    s
}

/// The `/v1/messages` body: the task's definition as `system`, the rendered
/// tail as the one user message, and one tool named after the task whose
/// `input_schema` is the labels schema, forced by `tool_choice`.
pub fn request_body(model: &str, task: &str, system: &str, user: &str, schema: &Value) -> Value {
    json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
        "system": system,
        "messages": [{"role": "user", "content": user}],
        "tools": [{
            "name": task,
            "description": format!("Record the {task} labels for the coding-chat excerpt."),
            "input_schema": schema,
        }],
        "tool_choice": {"type": "tool", "name": task},
    })
}

/// Token counts from the response's `usage`; zero when a field is absent.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_input_tokens: u64,
    pub cache_read_input_tokens: u64,
}

impl Usage {
    pub fn from_response(v: &Value) -> Usage {
        let n = |k: &str| v.pointer(&format!("/usage/{k}")).and_then(Value::as_u64).unwrap_or(0);
        Usage {
            input_tokens: n("input_tokens"),
            output_tokens: n("output_tokens"),
            cache_creation_input_tokens: n("cache_creation_input_tokens"),
            cache_read_input_tokens: n("cache_read_input_tokens"),
        }
    }
}

/// Why a call gave no labels. [Fail::note] is the 503 note.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fail {
    Timeout,
    /// Connection refused, DNS, TLS, a cut body.
    Network,
    Status(u16),
    /// `stop_reason: "refusal"`: the model declined to answer.
    Blocked,
    /// A 200 with no `tool_use` block for the task, or an unreadable body.
    /// The engine also uses it for an input that fails the schema.
    Malformed,
}

impl Fail {
    /// The same notes as Gemini's: 529 `overloaded_error`, 500 `api_error` and
    /// 503 all read "overloaded" (a retry later may work), 401/403 "bad key".
    pub fn note(self) -> &'static str {
        match self {
            Fail::Timeout => "timeout",
            Fail::Network => "remote error",
            Fail::Status(401 | 403) => "bad key",
            Fail::Status(429) => "rate limited",
            Fail::Status(500 | 503 | 529) => "overloaded",
            Fail::Status(_) => "remote error",
            Fail::Blocked => "blocked",
            Fail::Malformed => "malformed",
        }
    }
}

/// One call's outcome. `status` is `Some` when a response arrived (that call
/// gets a usage line), `None` on a timeout or network failure.
#[derive(Debug)]
pub struct Reply {
    pub status: Option<u16>,
    pub usage: Usage,
    pub result: Result<Value, Fail>,
}

/// A TLS-capable agent with the whole-request timeout.
pub fn agent(timeout: Duration) -> Result<ureq::Agent, String> {
    let tls = native_tls::TlsConnector::new().map_err(|e| e.to_string())?;
    Ok(ureq::AgentBuilder::new().tls_connector(Arc::new(tls)).timeout(timeout).build())
}

fn timed_out(e: &(dyn std::error::Error + 'static)) -> bool {
    let mut cur = Some(e);
    while let Some(e) = cur {
        if let Some(io) = e.downcast_ref::<io::Error>() {
            if matches!(io.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) {
                return true;
            }
        }
        cur = e.source();
    }
    false
}

/// The `input` of the `tool_use` block named `task`.
pub fn tool_input(v: &Value, task: &str) -> Option<Value> {
    v.get("content")?
        .as_array()?
        .iter()
        .find(|b| b["type"] == "tool_use" && b["name"] == task)
        .map(|b| b["input"].clone())
}

/// The labels from a 200 body: a refusal is `Blocked`, else the task's
/// `tool_use` input or `Malformed`.
pub fn answer_json(v: &Value, task: &str) -> Result<Value, Fail> {
    if v["stop_reason"] == "refusal" {
        return Err(Fail::Blocked);
    }
    tool_input(v, task).ok_or(Fail::Malformed)
}

/// POST `{base}/v1/messages`. The key goes in `x-api-key` and nowhere else.
pub fn call(agent: &ureq::Agent, base: &str, key: &str, body: &Value, task: &str) -> Reply {
    let resp = agent
        .post(&format!("{}/v1/messages", base.trim_end_matches('/')))
        .set("x-api-key", key)
        .set("anthropic-version", API_VERSION)
        .set("content-type", "application/json")
        .send_string(&body.to_string());
    let resp = match resp {
        Ok(r) => r,
        Err(ureq::Error::Status(code, _)) => {
            return Reply { status: Some(code), usage: Usage::default(), result: Err(Fail::Status(code)) }
        }
        Err(ureq::Error::Transport(t)) => {
            let fail = if timed_out(&t) { Fail::Timeout } else { Fail::Network };
            return Reply { status: None, usage: Usage::default(), result: Err(fail) };
        }
    };
    let status = resp.status();
    let text = match resp.into_string() {
        Ok(s) => s,
        Err(e) => {
            let fail = if timed_out(&e) { Fail::Timeout } else { Fail::Network };
            return Reply { status: Some(status), usage: Usage::default(), result: Err(fail) };
        }
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return Reply { status: Some(status), usage: Usage::default(), result: Err(Fail::Malformed) };
    };
    let usage = Usage::from_response(&v);
    Reply { status: Some(status), usage, result: answer_json(&v, task) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Turn;

    #[test]
    fn render_lines() {
        let t = Tail {
            chat: None,
            turns: vec![
                Turn { role: "user".into(), text: "hi".into() },
                Turn { role: "assistant".into(), text: "yo".into() },
            ],
            tool_out: "boom".into(),
        };
        assert_eq!(render_tail(&t), "[user] hi\n[assistant] yo\n[tool] boom\n");
    }

    #[test]
    fn body_forces_the_task_tool_with_the_schema() {
        let schema = json!({"type": "object"});
        let b = request_body("claude-m", "scope_drift", "sys", "usr", &schema);
        assert_eq!(b["model"], "claude-m");
        assert_eq!(b["max_tokens"], 300);
        assert_eq!(b["temperature"], 0);
        assert_eq!(b["system"], "sys");
        assert_eq!(b["messages"], json!([{"role": "user", "content": "usr"}]));
        assert_eq!(b["tools"][0]["name"], "scope_drift");
        assert_eq!(b["tools"][0]["input_schema"], schema);
        assert_eq!(b["tool_choice"], json!({"type": "tool", "name": "scope_drift"}));
    }

    #[test]
    fn notes_per_failure() {
        let n = |f: Fail| f.note();
        assert_eq!(n(Fail::Status(401)), "bad key");
        assert_eq!(n(Fail::Status(403)), "bad key");
        assert_eq!(n(Fail::Status(429)), "rate limited");
        assert_eq!(n(Fail::Status(529)), "overloaded");
        assert_eq!(n(Fail::Status(500)), "overloaded");
        assert_eq!(n(Fail::Status(503)), "overloaded");
        assert_eq!(n(Fail::Status(400)), "remote error");
        assert_eq!(n(Fail::Status(404)), "remote error");
        assert_eq!(n(Fail::Network), "remote error");
        assert_eq!(n(Fail::Timeout), "timeout");
        assert_eq!(n(Fail::Blocked), "blocked");
        assert_eq!(n(Fail::Malformed), "malformed");
    }

    #[test]
    fn a_refusal_is_blocked_even_with_a_tool_block() {
        let tool = json!({"type": "tool_use", "name": "t", "input": {"a": 1}});
        assert_eq!(answer_json(&json!({"stop_reason": "refusal", "content": [tool.clone()]}), "t"), Err(Fail::Blocked));
        assert_eq!(answer_json(&json!({"stop_reason": "tool_use", "content": [tool]}), "t"), Ok(json!({"a": 1})));
        assert_eq!(answer_json(&json!({"stop_reason": "end_turn", "content": []}), "t"), Err(Fail::Malformed));
    }

    #[test]
    fn tool_input_picks_the_named_tool_use_block() {
        let v = json!({"content": [
            {"type": "text", "text": "x"},
            {"type": "tool_use", "name": "other", "input": {"a": 1}},
            {"type": "tool_use", "name": "t", "input": {"a": 2}},
        ]});
        assert_eq!(tool_input(&v, "t"), Some(json!({"a": 2})));
        assert_eq!(tool_input(&json!({"content": [{"type": "text", "text": "x"}]}), "t"), None);
        assert_eq!(tool_input(&json!({}), "t"), None);
    }

    #[test]
    fn usage_fields_default_to_zero() {
        let u = Usage::from_response(&json!({"usage": {"input_tokens": 12, "output_tokens": 3}}));
        assert_eq!(u, Usage { input_tokens: 12, output_tokens: 3, ..Default::default() });
    }
}
