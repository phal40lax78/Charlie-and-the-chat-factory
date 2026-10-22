//! The model call (SPEC.md section 2): Gemini through the Gemini API
//! `generateContent`, one structured-output answer per classification,
//! temperature 0. The task's labels schema goes in
//! `generationConfig.responseJsonSchema`, so the answer arrives as JSON text in
//! the first candidate; the engine validates it against the full schema
//! before it counts.

use crate::api::Tail;
use serde_json::{json, Map, Value};
use std::io;
use std::sync::Arc;
use std::time::Duration;

/// Where requests go unless [BASE_ENV] says otherwise.
pub const DEFAULT_BASE: &str = "https://generativelanguage.googleapis.com";
/// TEST-ONLY: points the brain at a local mock Gemini server. Never set it
/// in a real install; the key would go wherever it points.
pub const BASE_ENV: &str = "CHATQ_BRAIN_API_BASE";
/// The env var read when `data/brain/gemini-key` is missing.
pub const KEY_ENV: &str = "GEMINI_API_KEY";
/// Whole-request timeout. Under the overlay's 2 500 ms client timeout, so a
/// slow answer comes back as 503 `timeout` before the overlay gives up.
pub const TIMEOUT_MS: u64 = 2_300;
/// Thought tokens count toward this cap too; a label object is about 60
/// tokens, so 300 leaves room for minimal thinking.
pub const MAX_OUTPUT_TOKENS: u32 = 300;

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

/// The keywords the structured-output page lists as supported. Anything
/// else is dropped before sending; the engine still validates the answer
/// against the full original schema.
const SCHEMA_KEYWORDS: &[&str] = &[
    "type", "properties", "required", "additionalProperties", "enum", "format", "minimum", "maximum", "items",
    "prefixItems", "minItems", "maxItems", "title", "description",
];

/// The task schema as sent in `responseJsonSchema`: unsupported keywords
/// stripped, and `"type": "string"` added to an untyped all-string `enum`
/// (`fail_kind.kind`, `prompt_quality.issues.items`).
pub fn json_schema(schema: &Value) -> Value {
    let Value::Object(obj) = schema else { return schema.clone() };
    let mut out = Map::new();
    for (k, v) in obj {
        if !SCHEMA_KEYWORDS.contains(&k.as_str()) {
            continue;
        }
        let v = match k.as_str() {
            "properties" => match v {
                Value::Object(p) => Value::Object(p.iter().map(|(n, s)| (n.clone(), json_schema(s))).collect()),
                other => other.clone(),
            },
            "items" => json_schema(v),
            "prefixItems" => match v {
                Value::Array(a) => Value::Array(a.iter().map(json_schema).collect()),
                other => other.clone(),
            },
            "additionalProperties" if v.is_object() => json_schema(v),
            _ => v.clone(),
        };
        out.insert(k.clone(), v);
    }
    if !out.contains_key("type") {
        if let Some(Value::Array(e)) = out.get("enum") {
            if !e.is_empty() && e.iter().all(Value::is_string) {
                out.insert("type".into(), json!("string"));
            }
        }
    }
    Value::Object(out)
}

/// Thinking as low as the model allows: the 2.5 generation takes
/// `thinkingBudget: 0` (off); the 3.x models take `thinkingLevel: "minimal"`.
/// `thinkingLevel: "minimal"` confirmed live 2026-10-22 on gemini-3.5-flash-lite
/// and gemini-3.1-flash-lite (accepted, 0 thought tokens); `thinkingBudget`
/// unverified, since gemini-2.5-flash-lite answered 404 to a new key.
pub fn thinking_config(model: &str) -> Value {
    if model.starts_with("gemini-2.") {
        json!({"thinkingBudget": 0})
    } else {
        json!({"thinkingLevel": "minimal"})
    }
}

/// The `generateContent` body: the task's definition as `systemInstruction`,
/// the rendered tail as the one user turn, JSON output constrained by the
/// task's schema. The model goes in the URL, not the body.
pub fn request_body(model: &str, system: &str, user: &str, schema: &Value) -> Value {
    json!({
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": MAX_OUTPUT_TOKENS,
            "responseMimeType": "application/json",
            "responseJsonSchema": json_schema(schema),
            "thinkingConfig": thinking_config(model),
        },
    })
}

/// Token counts from the response's `usageMetadata`; zero when a field is
/// absent. `input_tokens` includes `cached_tokens`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Usage {
    /// `promptTokenCount`.
    pub input_tokens: u64,
    /// `candidatesTokenCount`.
    pub output_tokens: u64,
    /// `thoughtsTokenCount`, billed as output.
    pub thought_tokens: u64,
    /// `cachedContentTokenCount`, the part of the input read from cache.
    pub cached_tokens: u64,
}

impl Usage {
    pub fn from_response(v: &Value) -> Usage {
        let n = |k: &str| v.pointer(&format!("/usageMetadata/{k}")).and_then(Value::as_u64).unwrap_or(0);
        Usage {
            input_tokens: n("promptTokenCount"),
            output_tokens: n("candidatesTokenCount"),
            thought_tokens: n("thoughtsTokenCount"),
            cached_tokens: n("cachedContentTokenCount"),
        }
    }
}

/// Why a call gave no labels. [Fail::note] is the 503 note.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fail {
    Timeout,
    /// Connection refused, DNS, TLS, a cut body.
    Network,
    /// A 400 whose error names `API_KEY_INVALID`.
    KeyInvalid,
    Status(u16),
    /// A safety `finishReason`, or `promptFeedback.blockReason`.
    Blocked,
    /// A 200 with no JSON text in the first candidate, or an unreadable
    /// body. The engine also uses it for an answer that fails the schema.
    Malformed,
}

impl Fail {
    /// An error status, with its body read for the bad-key case.
    pub fn from_status(code: u16, body: &str) -> Fail {
        if code == 400 && body.contains("API_KEY_INVALID") {
            Fail::KeyInvalid
        } else {
            Fail::Status(code)
        }
    }

    pub fn note(self) -> &'static str {
        match self {
            Fail::Timeout => "timeout",
            Fail::Network => "remote error",
            Fail::KeyInvalid | Fail::Status(401 | 403) => "bad key",
            Fail::Status(429) => "rate limited",
            Fail::Status(500 | 503) => "overloaded",
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

/// `finishReason` values that mean the answer was withheld.
const BLOCKED_FINISH: &[&str] = &["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"];

/// The labels from a 200 body: the first candidate's non-thought text parts,
/// joined and parsed as JSON.
pub fn answer_json(v: &Value) -> Result<Value, Fail> {
    if v.pointer("/promptFeedback/blockReason").is_some_and(|r| !r.is_null()) {
        return Err(Fail::Blocked);
    }
    let cand = v.pointer("/candidates/0").ok_or(Fail::Malformed)?;
    if cand["finishReason"].as_str().is_some_and(|r| BLOCKED_FINISH.contains(&r)) {
        return Err(Fail::Blocked);
    }
    let text: String = cand
        .pointer("/content/parts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|p| p["thought"] != true)
        .filter_map(|p| p["text"].as_str())
        .collect();
    if text.trim().is_empty() {
        return Err(Fail::Malformed);
    }
    serde_json::from_str(&text).map_err(|_| Fail::Malformed)
}

/// POST `{base}/v1beta/models/{model}:generateContent`. The key goes in
/// `x-goog-api-key` and nowhere else (never the URL).
pub fn call(agent: &ureq::Agent, base: &str, key: &str, model: &str, body: &Value) -> Reply {
    let resp = agent
        .post(&format!("{}/v1beta/models/{model}:generateContent", base.trim_end_matches('/')))
        .set("x-goog-api-key", key)
        .set("content-type", "application/json")
        .send_string(&body.to_string());
    let resp = match resp {
        Ok(r) => r,
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();            return Reply { status: Some(code), usage: Usage::default(), result: Err(Fail::from_status(code, &text)) };
        }
        Err(ureq::Error::Transport(t)) => {            let fail = if timed_out(&t) { Fail::Timeout } else { Fail::Network };
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
    Reply { status: Some(status), usage: Usage::from_response(&v), result: answer_json(&v) }
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
    fn body_carries_system_tail_and_the_schema_as_json_output() {
        let schema = json!({"type": "object"});
        let b = request_body("gemini-3.5-flash-lite", "sys", "usr", &schema);
        assert!(b.get("model").is_none(), "the model is in the URL");
        assert_eq!(b["systemInstruction"], json!({"parts": [{"text": "sys"}]}));
        assert_eq!(b["contents"], json!([{"role": "user", "parts": [{"text": "usr"}]}]));
        let g = &b["generationConfig"];
        assert_eq!(g["temperature"], 0);
        assert_eq!(g["maxOutputTokens"], 300);
        assert_eq!(g["responseMimeType"], "application/json");
        assert_eq!(g["responseJsonSchema"], schema);
        assert_eq!(g["thinkingConfig"], json!({"thinkingLevel": "minimal"}));
    }

    #[test]
    fn thinking_off_for_2_5_minimal_for_3() {
        assert_eq!(thinking_config("gemini-2.5-flash-lite"), json!({"thinkingBudget": 0}));
        assert_eq!(thinking_config("gemini-3.5-flash-lite"), json!({"thinkingLevel": "minimal"}));
        assert_eq!(thinking_config("gemini-3.8-flash"), json!({"thinkingLevel": "minimal"}));
    }

    #[test]
    fn schema_strips_unsupported_keywords_and_types_string_enums() {
        let s = json!({"$schema": "x", "type": "object", "additionalProperties": false, "minProperties": 1,
            "required": ["k", "l"],
            "properties": {
                "k": {"enum": ["a", "b"]},
                "l": {"type": "array", "uniqueItems": true, "items": {"enum": ["x"]}},
                "s": {"type": ["string", "null"], "minLength": 2},
                "n": {"enum": [1, 2]},
            }});
        assert_eq!(
            json_schema(&s),
            json!({"type": "object", "additionalProperties": false, "required": ["k", "l"],
                "properties": {
                    "k": {"type": "string", "enum": ["a", "b"]},
                    "l": {"type": "array", "items": {"type": "string", "enum": ["x"]}},
                    "s": {"type": ["string", "null"]},
                    "n": {"enum": [1, 2]},
                }})
        );
    }

    /// Drops the `"type": "string"` that [json_schema] adds beside an `enum`.
    fn untype_enums(v: &Value) -> Value {
        match v {
            Value::Object(o) => Value::Object(
                o.iter()
                    .filter(|(k, _)| !(k.as_str() == "type" && o.contains_key("enum")))
                    .map(|(k, x)| (k.clone(), untype_enums(x)))
                    .collect(),
            ),
            Value::Array(a) => Value::Array(a.iter().map(untype_enums).collect()),
            other => other.clone(),
        }
    }

    #[test]
    fn every_catalogue_schema_is_sent_whole_with_typed_enums() {
        for t in crate::catalogue::TASKS.iter() {
            let orig = t.schema_value();
            assert_eq!(untype_enums(&json_schema(&orig)), orig, "{}: nothing stripped", t.name);
        }
        let fk = json_schema(&crate::catalogue::find("fail_kind", "fail_kind@1").unwrap().schema_value());
        assert_eq!(fk["properties"]["kind"]["type"], "string");
    }

    #[test]
    fn notes_per_failure() {
        let n = |f: Fail| f.note();
        assert_eq!(n(Fail::from_status(400, r#"{"error":{"details":[{"reason":"API_KEY_INVALID"}]}}"#)), "bad key");
        assert_eq!(n(Fail::from_status(400, r#"{"error":{"status":"INVALID_ARGUMENT"}}"#)), "remote error");
        assert_eq!(n(Fail::Status(401)), "bad key");
        assert_eq!(n(Fail::Status(403)), "bad key");
        assert_eq!(n(Fail::Status(429)), "rate limited");
        assert_eq!(n(Fail::Status(503)), "overloaded");
        assert_eq!(n(Fail::Status(500)), "overloaded");
        assert_eq!(n(Fail::Status(404)), "remote error");
        assert_eq!(n(Fail::Status(504)), "remote error");
        assert_eq!(n(Fail::Network), "remote error");
        assert_eq!(n(Fail::Timeout), "timeout");
        assert_eq!(n(Fail::Blocked), "blocked");
        assert_eq!(n(Fail::Malformed), "malformed");
    }

    fn cand(parts: Value, finish: &str) -> Value {
        json!({"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": finish}]})
    }

    #[test]
    fn answer_joins_text_parts_and_skips_thoughts() {
        let v = cand(json!([{"text": "hmm", "thought": true}, {"text": "{\"a\":"}, {"text": "1}"}]), "STOP");
        assert_eq!(answer_json(&v), Ok(json!({"a": 1})));
        assert_eq!(answer_json(&cand(json!([]), "STOP")), Err(Fail::Malformed));
        assert_eq!(answer_json(&cand(json!([{"text": "not json"}]), "STOP")), Err(Fail::Malformed));
        assert_eq!(answer_json(&cand(json!([{"text": "{\"a\":"}]), "MAX_TOKENS")), Err(Fail::Malformed));
        assert_eq!(answer_json(&json!({})), Err(Fail::Malformed));
    }

    #[test]
    fn safety_stops_and_prompt_blocks_are_blocked() {
        for r in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"] {
            assert_eq!(answer_json(&cand(json!([{"text": "{}"}]), r)), Err(Fail::Blocked), "{r}");
        }
        assert_eq!(answer_json(&json!({"promptFeedback": {"blockReason": "SAFETY"}})), Err(Fail::Blocked));
        assert_eq!(answer_json(&cand(json!([{"text": "{}"}]), "STOP")), Ok(json!({})));
    }

    #[test]
    fn usage_fields_default_to_zero() {
        let u = Usage::from_response(&json!({"usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 3}}));
        assert_eq!(u, Usage { input_tokens: 12, output_tokens: 3, ..Default::default() });
        let u = Usage::from_response(&json!({"usageMetadata": {"thoughtsTokenCount": 7, "cachedContentTokenCount": 5}}));
        assert_eq!(u, Usage { thought_tokens: 7, cached_tokens: 5, ..Default::default() });
    }
}
