//! The `local` backend's model call (SPEC.md section 2): llama-server's
//! OpenAI-compatible `/v1/chat/completions`, JSON-schema constrained,
//! temperature 0.

use crate::api::Tail;
use serde_json::{json, Value};
use std::io;
use std::time::Duration;

/// Room for a label object (about 60 tokens) with margin.
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

/// The prompt cache is off on the server (`--cache-ram 0`); `cache_prompt`
/// false keeps the request from asking for it either.
pub fn request_body(system: &str, user: &str, schema: &Value) -> Value {
    json!({
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0,
        "max_tokens": MAX_TOKENS,
        "cache_prompt": false,
        "response_format": {"type": "json_schema", "json_schema": {"schema": schema}},
    })
}

/// Why a call gave no labels.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fail {
    /// No answer within the timeout. The server may still be working: not a crash.
    Timeout,
    /// A 200 whose first choice is not JSON.
    Malformed,
    /// Refused connection, an error status, a cut body. The engine asks the
    /// process whether it is alive before it calls this a crash.
    Other(String),
}

/// One call's outcome. `status` is `Some` when a response arrived (that call
/// gets a usage line).
#[derive(Debug)]
pub struct Reply {
    pub status: Option<u16>,
    /// `usage.prompt_tokens`, `usage.completion_tokens`.
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub result: Result<Value, Fail>,
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

fn reply(status: Option<u16>, result: Result<Value, Fail>) -> Reply {
    Reply { status, input_tokens: 0, output_tokens: 0, result }
}

/// The labels from a 200 body: `choices[0].message.content` parsed as JSON.
pub fn answer_json(v: &Value) -> Result<Value, Fail> {
    let content = v.pointer("/choices/0/message/content").and_then(Value::as_str).ok_or(Fail::Malformed)?;
    serde_json::from_str(content.trim()).map_err(|_| Fail::Malformed)
}

/// POST `{base}/v1/chat/completions` with a whole-request `timeout`.
pub fn ask(base: &str, system: &str, user: &str, schema: &Value, timeout: Duration) -> Reply {
    let agent = ureq::AgentBuilder::new().timeout(timeout).build();
    let resp = agent.post(&format!("{base}/v1/chat/completions")).send_json(request_body(system, user, schema));
    let resp = match resp {
        Ok(r) => r,
        Err(ureq::Error::Status(code, _)) => return reply(Some(code), Err(Fail::Other(format!("status {code}")))),
        Err(ureq::Error::Transport(t)) => {
            let fail = if timed_out(&t) { Fail::Timeout } else { Fail::Other(t.to_string()) };
            return reply(None, Err(fail));
        }
    };
    let status = resp.status();
    let text = match resp.into_string() {
        Ok(s) => s,
        Err(e) => {
            let fail = if timed_out(&e) { Fail::Timeout } else { Fail::Other(e.to_string()) };
            return reply(None, Err(fail));
        }
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return reply(Some(status), Err(Fail::Malformed)) };
    let n = |k: &str| v.pointer(&format!("/usage/{k}")).and_then(Value::as_u64).unwrap_or(0);
    Reply { status: Some(status), input_tokens: n("prompt_tokens"), output_tokens: n("completion_tokens"), result: answer_json(&v) }
}

/// `GET {base}/health` is 200.
pub fn health(base: &str, timeout: Duration) -> bool {
    let agent = ureq::AgentBuilder::new().timeout(timeout).build();
    agent.get(&format!("{base}/health")).call().is_ok_and(|r| r.status() == 200)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Turn;

    /// One-shot fake llama-server: serves `n` requests, returns the bodies it saw.
    fn fake(n: usize, reply: String) -> (String, std::thread::JoinHandle<Vec<String>>) {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr().to_ip().unwrap());
        let h = std::thread::spawn(move || {
            let mut seen = Vec::new();
            for _ in 0..n {
                let mut req = server.recv().unwrap();
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                seen.push(format!("{} {} {}", req.method(), req.url(), body));
                let _ = req.respond(tiny_http::Response::from_string(reply.clone()));
            }
            seen
        });
        (base, h)
    }

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
    fn ask_sends_the_contracted_body_and_parses_content_and_usage() {
        let reply = json!({"choices":[{"message":{"content":"{\"contradicts\":true,\"earlier\":null,\"later\":null}"}}],
                           "usage": {"prompt_tokens": 210, "completion_tokens": 17}});
        let (base, h) = fake(1, reply.to_string());
        let schema = json!({"type":"object"});
        let r = ask(&base, "sys", "usr", &schema, Duration::from_secs(5));
        assert_eq!(r.result.unwrap()["contradicts"], true);
        assert_eq!((r.status, r.input_tokens, r.output_tokens), (Some(200), 210, 17));
        let seen = h.join().unwrap();
        assert!(seen[0].starts_with("POST /v1/chat/completions "));
        let body: Value = serde_json::from_str(seen[0].splitn(3, ' ').nth(2).unwrap()).unwrap();
        assert_eq!(body["temperature"], 0);
        assert_eq!(body["max_tokens"], MAX_TOKENS);
        assert_eq!(body["cache_prompt"], false);
        assert_eq!(body["response_format"]["type"], "json_schema");
        assert_eq!(body["response_format"]["json_schema"]["schema"], schema);
        assert_eq!(body["messages"][0]["content"], "sys");
        assert_eq!(body["messages"][1]["content"], "usr");
    }

    #[test]
    fn ask_calls_non_json_content_malformed() {
        let reply = json!({"choices":[{"message":{"content":"sure thing"}}]});
        let (base, h) = fake(1, reply.to_string());
        let r = ask(&base, "s", "u", &json!({}), Duration::from_secs(5));
        assert_eq!((r.status, r.result), (Some(200), Err(Fail::Malformed)));
        h.join().unwrap();
    }

    #[test]
    fn a_closed_port_is_other_not_timeout() {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let r = ask(&format!("http://127.0.0.1:{port}"), "s", "u", &json!({}), Duration::from_secs(10));
        assert!(matches!(r.result, Err(Fail::Other(_))), "{:?}", r.result);
        assert_eq!(r.status, None);
    }

    #[test]
    fn health_true_on_200_false_when_down() {
        let (base, h) = fake(1, "{}".into());
        assert!(health(&base, Duration::from_secs(2)));
        h.join().unwrap();
        assert!(!health(&base, Duration::from_millis(300)), "server gone");
    }
}
