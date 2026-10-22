//! The localhost HTTP face (SPEC.md section 2): `GET /health`, `POST /classify`,
//! `GET /usage`, and on the local backend `POST /install` and `POST /unload`;
//! Bearer token on every request. std threads over tiny_http.

use crate::api::{ClassifyReq, InstallReq, CONTRACT};
use crate::engine::{ClassifyErr, Engine};
use crate::supervisor::{Install, InstallErr};
use serde_json::{json, Value};
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

const MAX_BODY: u64 = 64 * 1024;
const WORKERS: usize = 4;

fn token_ok(given: &str, want: &str) -> bool {
    // Compare every byte regardless of where they differ.
    given.len() == want.len() && given.bytes().zip(want.bytes()).fold(0u8, |a, (x, y)| a | (x ^ y)) == 0
}

/// One request, no sockets: `(status, body)`. `None` body = empty body.
pub fn route(engine: &Engine, token: &str, method: &str, path: &str, auth: Option<&str>, body: &[u8]) -> (u16, Option<Value>) {
    let given = auth.and_then(|a| a.strip_prefix("Bearer ")).unwrap_or("");
    if !token_ok(given, token) {
        return (401, None);
    }
    match (method, path) {
        ("GET", "/health") => (200, Some(engine.health())),
        ("GET", "/usage") => (200, Some(engine.usage())),
        ("POST", "/classify") => match serde_json::from_slice::<ClassifyReq>(body) {
            Err(e) => (400, Some(json!({"error": e.to_string()}))),
            Ok(req) => match engine.classify(&req) {
                Ok(a) => (200, Some(serde_json::to_value(a).expect("answer serializes"))),
                Err(ClassifyErr::Unknown(known)) => (409, Some(json!({"known": known}))),
                Err(ClassifyErr::Unavailable(u)) => (503, Some(u.to_json())),
            },
        },
        ("POST", "/unload") if engine.local_backend().is_some() => {
            let state = engine.local_backend().expect("local").unload();
            (200, Some(json!({"contract": CONTRACT, "state": state})))
        }
        ("POST", "/install") if engine.local_backend().is_some() => match serde_json::from_slice::<InstallReq>(body) {
            Err(e) => (400, Some(json!({"error": e.to_string()}))),
            Ok(req) => match engine.local_backend().expect("local").install(&req.model) {
                Ok(Install::Started(id) | Install::Joined(id)) => {
                    (202, Some(json!({"contract": CONTRACT, "state": "downloading", "model": id})))
                }
                Ok(Install::Present { model, state }) => (200, Some(json!({"contract": CONTRACT, "state": state, "model": model}))),
                Err(InstallErr::Unknown(known)) => (400, Some(json!({"error": "unknown model", "known": known}))),
                Err(InstallErr::Refused(u)) => (503, Some(u.to_json())),
            },
        },
        (_, "/install" | "/unload") if engine.local_backend().is_some() => (405, Some(json!({"error": "method not allowed"}))),
        (_, "/health" | "/classify" | "/usage") => (405, Some(json!({"error": "method not allowed"}))),
        _ => (404, Some(json!({"error": "not found"}))),
    }
}

pub struct Handle {
    pub port: u16,
    pub token: String,
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
}

impl Handle {
    pub fn shutdown(self) {
        self.stop.store(true, Ordering::SeqCst);
        for t in self.threads {
            let _ = t.join();
        }
    }
}

/// Bind `127.0.0.1:port` (0 = any) and serve until `shutdown`.
pub fn start(engine: Engine, token: String, port: u16) -> Result<Handle, String> {
    let server = tiny_http::Server::http(("127.0.0.1", port)).map_err(|e| e.to_string())?;
    let bound = server.server_addr().to_ip().ok_or("no ip address")?.port();
    let server = Arc::new(server);
    let stop = Arc::new(AtomicBool::new(false));
    let mut threads = Vec::new();
    for _ in 0..WORKERS {
        let (server, stop, engine, token) = (server.clone(), stop.clone(), engine.clone(), token.clone());
        threads.push(std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                match server.recv_timeout(Duration::from_millis(200)) {
                    Ok(Some(req)) => serve_one(&engine, &token, req),
                    Ok(None) => {}
                    Err(_) => break,
                }
            }
        }));
    }
    Ok(Handle { port: bound, token, stop, threads })
}

fn serve_one(engine: &Engine, token: &str, mut req: tiny_http::Request) {
    let auth = req
        .headers()
        .iter()
        .find(|h| h.field.equiv("Authorization"))
        .map(|h| h.value.as_str().to_string());
    let mut body = Vec::new();
    let _ = req.as_reader().take(MAX_BODY + 1).read_to_end(&mut body);
    let (status, out) = if body.len() as u64 > MAX_BODY {
        (413, Some(json!({"error": "body too large"})))
    } else {
        route(engine, token, req.method().as_str(), req.url(), auth.as_deref(), &body)
    };
    let _ = match out {
        None => req.respond(tiny_http::Response::empty(status)),
        Some(v) => {
            let ct = tiny_http::Header::from_bytes("Content-Type", "application/json").expect("static header");
            req.respond(tiny_http::Response::from_string(v.to_string()).with_status_code(status).with_header(ct))
        }
    };
}
