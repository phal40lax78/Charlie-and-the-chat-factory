//! [Poller] against a fake ntfy on loopback (a `TcpListener` thread), with
//! the steps a closure. Nothing here reaches the network, and every case
//! checks that the topic is in no log.

use super::*;
use crate::seams::Seams;
use crate::watch::Args;
use chatq_core::culture::Culture;
use chatq_core::fsx::try_lock;
use chatq_core::paths::Paths;
use chatq_core::time::{Flavour, stamp_utc};
use chatq_core::wire::{Sealed, b64url_encode, hmac_sha256, label_keys};
use chrono::Utc;
use std::cell::RefCell;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const TOPIC: &str = "chatqtest-sekrit-topic";
/// The phone's key D: bytes 0 to 31, in base64url
const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

/// A fake ntfy: every request's head, and `answer`'s bytes back.
struct Fake {
    base: String,
    seen: Arc<Mutex<Vec<String>>>,
}

impl Fake {
    fn start(answer: impl Fn(&str) -> Vec<u8> + Send + 'static) -> Fake {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        thread::spawn(move || {
            for c in l.incoming() {
                let Ok(mut c) = c else { break };
                let mut head = Vec::new();
                let mut b = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") && c.read(&mut b).is_ok_and(|n| n == 1) {
                    head.push(b[0]);
                }
                let head = String::from_utf8_lossy(&head).into_owned();
                log.lock().unwrap().push(head.clone());
                let _ = c.write_all(&answer(&head));
            }
        });
        Fake { base, seen }
    }

    /// Always `body`, 200.
    fn body(body: &[u8]) -> Fake {
        let body = body.to_vec();
        Fake::start(move |_| ok(&body))
    }

    fn seen(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }

    /// The request line of each request.
    fn lines(&self) -> Vec<String> {
        let s = self.seen();
        s.iter()
            .map(|h| h.lines().next().unwrap_or("").to_string())
            .collect()
    }
}

fn answer(status: &str, more: &str, body: &[u8]) -> Vec<u8> {
    let mut r = format!(
        "HTTP/1.1 {status}\r\n{more}Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    r.extend_from_slice(body);
    r
}

fn ok(body: &[u8]) -> Vec<u8> {
    answer("200 OK", "Content-Type: application/x-ndjson\r\n", body)
}

/// One ntfy line.
fn msg(id: &str, message: &str) -> String {
    serde_json::to_string(
        &json!({"id": id, "event": "message", "topic": TOPIC, "message": message}),
    )
    .unwrap()
}

/// A reply sealed under [KEY] with a MAC that checks out: a candidate,
/// whatever it decrypts to.
fn sealed(id: &str) -> String {
    let master: Vec<u8> = (0u8..32).collect();
    let keys = label_keys(&master, Sealed::Reply.label(), id);
    let head = format!(
        "{}.{id}.{}.{}",
        Sealed::Reply.prefix(),
        b64url_encode(&[7u8; 16]),
        b64url_encode(&[9u8; 32])
    );
    let mac = b64url_encode(&hmac_sha256(&keys.mac, head.as_bytes()));
    format!("{head}.{mac}")
}

fn ctx(name: &str, server: Option<&str>) -> Ctx {
    let r = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/test-data/chatqd-reply")
        .join(name);
    let _ = fs::remove_dir_all(&r);
    fs::create_dir_all(r.join("data")).unwrap();
    let root = r.to_string_lossy().into_owned();
    let ctx = Ctx {
        p: Paths::new(&root),
        pid: 4242,
        fl: Flavour::Desktop,
        culture: Culture::invariant(),
        seams: Seams::default(),
        args: Args {
            root,
            script: "x.ps1".into(),
            ps: "ps.exe".into(),
            culture: None,
        },
    };
    let mut reply = json!({
        "on": true,
        "topic": {"value": TOPIC, "protected": false},
        "key": {"value": KEY, "protected": false},
    });
    if let Some(s) = server {
        reply["server"] = json!(s);
    }
    fs::write(ctx.p.config(), json!({"reply": reply}).to_string()).unwrap();
    ctx
}

fn log(ctx: &Ctx, name: &str) -> Vec<String> {
    fs::read_to_string(ctx.p.log_dir().join(name))
        .unwrap_or_default()
        .lines()
        .map(|l| l.split_once("  ").unwrap().1.to_string())
        .collect()
}

/// The topic in no log, whatever happened.
fn no_topic(ctx: &Ctx) {
    for e in fs::read_dir(ctx.p.log_dir())
        .into_iter()
        .flatten()
        .flatten()
    {
        let text = fs::read_to_string(e.path()).unwrap();
        assert!(!text.contains(TOPIC), "{:?}: {text}", e.file_name());
    }
}

fn replies(ctx: &Ctx) -> Value {
    serde_json::from_str(&fs::read_to_string(ctx.p.replies()).unwrap()).unwrap()
}

/// A good answer: `w` as it came, `result`.
fn good(w: &WatchState, result: Value) -> Outcome {
    let Value::Object(m) = result else {
        unreachable!()
    };
    Outcome::Ok(Box::new(w.clone()), m)
}

/// A poll whose steps are refused: a batch with no candidate makes none.
fn no_step(op: &str, _: &WatchState, _: Value) -> Outcome {
    panic!("a {op} step for a batch with no candidate");
}

#[test]
fn escaping_is_escape_data_string() {
    assert_eq!(escape_data("AZaz09-._~"), "AZaz09-._~");
    assert_eq!(escape_data("a b/c+é?&="), "a%20b%2Fc%2B%C3%A9%3F%26%3D");
}

#[test]
fn junk_is_logged_and_saved_with_no_step() {
    let body = [
        r#"{"id":"o1","event":"open"}"#.to_string(),
        msg("aaa1", "hello"),
        msg("aaa2", "hello again"),
        msg("bad-id!", "x"),
        String::new(),
    ]
    .join("\n");
    let fake = Fake::body(body.as_bytes());
    let ctx = ctx("junk", Some(&fake.base));
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let now = Utc::now();
    assert_eq!(p.poll(&ctx, &mut w, 15, now, &mut no_step), 0);
    let lines = log(&ctx, "replies.log");
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(
        lines[0].starts_with("reply aaa1 refused - format: "),
        "{lines:?}"
    );
    assert_eq!(lines[1], "a message whose id is not ntfy's shape - skipped");
    let phone: Vec<String> = lines.iter().map(|l| format!("phone: {l}")).collect();
    assert_eq!(log(&ctx, "watcher.log"), phone);
    assert_eq!(replies(&ctx)["lastId"], "aaa2");
    let c = w.poll_caches();
    assert!(
        c.handled.contains(&format!("{TOPIC}|aaa1"))
            && c.handled.contains(&format!("{TOPIC}|AAA2"))
    );
    assert_eq!(c.junk_log["format"].count, 1, "the second only counted");
    assert_eq!(c.polled_at.map(stamp_utc), Some(stamp_utc(now)));
    assert_eq!(c.saved_at.map(stamp_utc), Some(stamp_utc(now)));
    // the URL: the topic as it is, a minute back, and no Authorization
    let since = now.timestamp() - 60;
    assert_eq!(
        fake.lines(),
        [format!("GET /{TOPIC}/json?poll=1&since={since} HTTP/1.1")]
    );
    assert!(
        !fake.seen()[0]
            .to_ascii_lowercase()
            .contains("authorization")
    );
    // MinSeconds: too soon, nothing fetched
    let soon = now + TimeDelta::seconds(5);
    assert_eq!(p.poll(&ctx, &mut w, 15, soon, &mut no_step), 0);
    assert_eq!(fake.lines().len(), 1);
    // then from lastId, the handled ids passed over: a save, no line
    let later = now + TimeDelta::seconds(16);
    assert_eq!(p.poll(&ctx, &mut w, 15, later, &mut no_step), 0);
    assert_eq!(
        fake.lines()[1],
        format!("GET /{TOPIC}/json?poll=1&since=aaa2 HTTP/1.1")
    );
    assert_eq!(log(&ctx, "replies.log").len(), 2);
    assert_eq!(replies(&ctx)["lastId"], "aaa2");
    no_topic(&ctx);
}

#[test]
fn since_comes_from_the_state() {
    let fake = Fake::body(b"");
    let ctx = ctx("since", Some(&fake.base));
    let mut w = WatchState::default();
    let now = Utc::now();
    fs::write(ctx.p.replies(), r#"{"since": 1700000000}"#).unwrap();
    Poller::default().poll(&ctx, &mut w, 0, now, &mut no_step);
    // an empty batch writes lastPolledAt alone, once in 5 minutes
    let st = replies(&ctx);
    assert!(
        st["lastPolledAt"].is_string() && st["lastId"].is_null(),
        "{st}"
    );
    fs::write(ctx.p.replies(), r#"{"since": 0}"#).unwrap();
    Poller::default().poll(&ctx, &mut w, 0, now, &mut no_step);
    let at = now.timestamp() - 60;
    let want = [
        format!("GET /{TOPIC}/json?poll=1&since=1700000000 HTTP/1.1"),
        format!("GET /{TOPIC}/json?poll=1&since={at} HTTP/1.1"),
    ];
    assert_eq!(fake.lines(), want);
    assert_eq!(
        replies(&ctx),
        json!({"since": 0}),
        "not again within 5 minutes"
    );
    no_topic(&ctx);
}

#[test]
fn a_candidate_goes_whole_to_one_reply_step() {
    let body = [
        msg("aaa1", "hello"),
        msg("bbb1", &sealed("abcdefghij")),
        msg("ccc1", "junk"),
    ]
    .join("\n");
    let fake = Fake::body(body.as_bytes());
    let ctx = ctx("candidate", Some(&fake.base));
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let now = Utc::now();
    let calls = RefCell::new(Vec::new());
    let mut step = |op: &str, w: &WatchState, args: Value| {
        calls.borrow_mut().push((op.to_string(), args));
        // the step's own, later PolledAt
        let mut back = w.clone();
        let mut c = back.poll_caches();
        c.polled_at = Some(now + TimeDelta::seconds(3));
        c.handled.add("from|the-step");
        back.set_poll_caches(&c);
        good(&back, json!({"acted": 2}))
    };
    assert_eq!(p.poll(&ctx, &mut w, 15, now, &mut step), 2);
    let calls = calls.into_inner();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "reply");
    assert_eq!(
        calls[0].1,
        json!({"text": body, "maxMessages": 10, "quick": false, "timeoutSec": 8})
    );
    let c = w.poll_caches();
    assert_eq!(
        c.polled_at.map(stamp_utc),
        Some(stamp_utc(now)),
        "chatqd's wins"
    );
    assert!(c.handled.contains("from|the-step"), "the step's W taken");
    // chatqd wrote nothing of its own: the step logs and saves
    assert!(log(&ctx, "replies.log").is_empty());
    assert!(!ctx.p.replies().exists(), "lastId never moved by chatqd");
    no_topic(&ctx);
}

#[test]
fn a_failed_step_keeps_the_batch_and_backs_off() {
    let fake = Fake::body(msg("bbb1", &sealed("abcdefghij")).as_bytes());
    let ctx = ctx("step-fails", Some(&fake.base));
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let t0 = Utc::now();
    let mut answer: Box<dyn Fn(&WatchState) -> Outcome> = Box::new(|_| Outcome::NoAnswer(5));
    let tries = RefCell::new(0);
    let at =
        |p: &mut Poller, w: &mut WatchState, secs: i64, answer: &dyn Fn(&WatchState) -> Outcome| {
            let mut step = |_: &str, w: &WatchState, _: Value| {
                *tries.borrow_mut() += 1;
                answer(w)
            };
            p.poll(&ctx, w, 0, t0 + TimeDelta::seconds(secs), &mut step)
        };
    assert_eq!(at(&mut p, &mut w, 0, &*answer), 0);
    assert_eq!(at(&mut p, &mut w, 30, &*answer), 0, "held a minute");
    assert_eq!(*tries.borrow(), 1);
    assert_eq!(
        fake.lines().len(),
        2,
        "fetched each pass, as PowerShell polls"
    );
    at(&mut p, &mut w, 61, &*answer);
    assert_eq!(*tries.borrow(), 2);
    at(&mut p, &mut w, 61 + 119, &*answer);
    assert_eq!(*tries.borrow(), 2, "then two minutes");
    answer = Box::new(|w| good(w, json!({"acted": 1})));
    assert_eq!(at(&mut p, &mut w, 61 + 121, &*answer), 1);
    assert_eq!(
        at(&mut p, &mut w, 61 + 122, &*answer),
        1,
        "reset by a good answer"
    );
    let said = "phone replies wait: a reply step failed - tried again in a minute or more";
    assert_eq!(log(&ctx, "watcher.log"), [said], "once in 10 minutes");
    assert!(
        !ctx.p.replies().exists(),
        "the batch kept: lastId never moved"
    );
    no_topic(&ctx);
}

/// A fake whose `n`th answer (from 0) is `bodies[n]`, the last one after.
fn fake_of(bodies: Vec<String>) -> Fake {
    let n = Arc::new(Mutex::new(0usize));
    Fake::start(move |_| {
        let mut i = n.lock().unwrap();
        let b = &bodies[(*i).min(bodies.len() - 1)];
        *i += 1;
        ok(b.as_bytes())
    })
}

#[test]
fn junk_is_still_saved_while_a_failed_step_holds() {
    let fake = fake_of(vec![
        msg("bbb1", &sealed("abcdefghij")),
        msg("aaa1", "hello"),
    ]);
    let ctx = ctx("held-junk", Some(&fake.base));
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let t0 = Utc::now();
    let mut fails = |_: &str, _: &WatchState, _: Value| Outcome::NoAnswer(5);
    p.poll(&ctx, &mut w, 0, t0, &mut fails);
    // held for a minute: the next batch, junk only, is triaged natively
    let t1 = t0 + TimeDelta::seconds(20);
    assert_eq!(p.poll(&ctx, &mut w, 0, t1, &mut no_step), 0);
    assert_eq!(fake.lines().len(), 2);
    assert_eq!(replies(&ctx)["lastId"], "aaa1");
    let lines = log(&ctx, "replies.log");
    assert!(
        lines.len() == 1 && lines[0].starts_with("reply aaa1 refused - format: "),
        "{lines:?}"
    );
    no_topic(&ctx);
}

#[test]
fn a_save_only_powershell_makes_goes_to_a_text_step() {
    // reply.hours as text 5.1 and 7 read as numbers their own ways: the
    // since read is native, either save is PowerShell's
    let fake = fake_of(vec![String::new(), msg("aaa1", "hello")]);
    let ctx = ctx("ps-only-save", Some(&fake.base));
    let mut cfg: Value =
        serde_json::from_str(&fs::read_to_string(ctx.p.config()).unwrap()).unwrap();
    cfg["reply"]["hours"] = json!("0x10");
    fs::write(ctx.p.config(), cfg.to_string()).unwrap();
    let calls = RefCell::new(Vec::new());
    let mut step = |op: &str, w: &WatchState, args: Value| {
        calls.borrow_mut().push((
            op.to_string(),
            args["text"].clone(),
            w.poll_caches().saved_at,
        ));
        good(w, json!({"acted": 0}))
    };
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let t0 = Utc::now();
    // an empty batch: the lastPolledAt save, ChatqReplySavedAt as it was
    p.poll(&ctx, &mut w, 0, t0, &mut step);
    // a junk batch: the lastId save
    p.poll(&ctx, &mut w, 0, t0 + TimeDelta::seconds(20), &mut step);
    let calls = calls.into_inner();
    assert_eq!(fake.lines().len(), 2, "{:?}", fake.seen());
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        calls.iter().all(|c| c.0 == "reply" && c.2.is_none()),
        "{calls:?}"
    );
    assert_eq!(calls[0].1, "");
    assert_eq!(calls[1].1, msg("aaa1", "hello"));
    assert!(!ctx.p.replies().exists(), "chatqd wrote nothing");
    assert!(
        log(&ctx, "replies.log").is_empty(),
        "the step logs the junk"
    );
    let said = log(&ctx, "watcher.log");
    assert_eq!(said.len(), 1, "said once: {said:?}");
    assert!(said[0].ends_with(" - PowerShell steps read the phone's replies"));
    no_topic(&ctx);
}

#[test]
fn a_failed_fetch_is_logged_once_in_ten_minutes() {
    for (status, why) in [
        ("500 Internal Server Error", "the server answered 500"),
        ("429 Too Many Requests", "the server answered 429"),
    ] {
        let fake = Fake::start(move |_| answer(status, "", b"{\"error\":\"x\"}"));
        let ctx = ctx("fetch-fails", Some(&fake.base));
        let mut p = Poller::default();
        let mut w = WatchState::default();
        let t0 = Utc::now();
        for s in [0, 60, 601] {
            p.poll(&ctx, &mut w, 0, t0 + TimeDelta::seconds(s), &mut no_step);
        }
        let line = format!("poll failed: {why}");
        assert_eq!(log(&ctx, "replies.log"), [line.clone(), line]);
        assert_eq!(fake.lines().len(), 3);
        assert!(!ctx.p.replies().exists(), "nothing saved");
        no_topic(&ctx);
    }
}

#[test]
fn a_slow_server_times_out_at_8_s() {
    let fake = Fake::start(|_| {
        thread::sleep(Duration::from_secs(10));
        ok(b"")
    });
    let ctx = ctx("slow", Some(&fake.base));
    let t = std::time::Instant::now();
    Poller::default().poll(
        &ctx,
        &mut WatchState::default(),
        0,
        Utc::now(),
        &mut no_step,
    );
    let s = t.elapsed().as_secs_f64();
    assert!((7.5..9.5).contains(&s), "{s} s");
    assert_eq!(
        log(&ctx, "replies.log"),
        ["poll failed: the request timed out"]
    );
    no_topic(&ctx);
}

#[test]
fn redirects_are_followed_five_times() {
    // every answer sends the poll on, the topic in the Location
    let fake = Fake::start(|head| {
        let n: u32 = head
            .split_once("hop=")
            .and_then(|(_, r)| r.split(' ').next()?.parse().ok())
            .unwrap_or(0);
        if n == 3 {
            return ok(msg("aaa1", "x").as_bytes());
        }
        let to = format!("Location: /{TOPIC}/json?hop={}\r\n", n + 1);
        answer("302 Found", &to, b"")
    });
    let ctx = ctx("redirects", Some(&fake.base));
    Poller::default().poll(
        &ctx,
        &mut WatchState::default(),
        0,
        Utc::now(),
        &mut no_step,
    );
    assert_eq!(fake.lines().len(), 4);
    assert_eq!(log(&ctx, "replies.log").len(), 1, "followed to the answer");
    no_topic(&ctx);
    let fake = Fake::start(|_| answer("302 Found", &format!("Location: /{TOPIC}/json\r\n"), b""));
    let ctx = self::ctx("redirects-loop", Some(&fake.base));
    Poller::default().poll(
        &ctx,
        &mut WatchState::default(),
        0,
        Utc::now(),
        &mut no_step,
    );
    assert_eq!(
        log(&ctx, "replies.log"),
        ["poll failed: too many redirects"]
    );
    assert_eq!(fake.lines().len(), 6, "the first and 5 more");
    no_topic(&ctx);
}

#[test]
fn five_hundred_junk_lines_make_one_line_and_one_save() {
    let body: Vec<String> = (0..500).map(|n| msg(&format!("j{n}"), "flood")).collect();
    let fake = Fake::body(body.join("\n").as_bytes());
    let ctx = ctx("flood", Some(&fake.base));
    let mut w = WatchState::default();
    Poller::default().poll(&ctx, &mut w, 0, Utc::now(), &mut no_step);
    assert_eq!(log(&ctx, "replies.log").len(), 1);
    assert_eq!(w.poll_caches().junk_log["format"].count, 499);
    assert_eq!(replies(&ctx)["lastId"], "j499");
    assert_eq!(w.poll_caches().handled.tags().len(), 500);
    no_topic(&ctx);
}

#[test]
fn bad_utf8_is_read_with_replacements() {
    let mut body = msg("aaa1", "MARK").into_bytes();
    let at = body.windows(4).position(|x| x == b"MARK").unwrap();
    body.splice(at..at + 4, [0xff, 0xfe, b'x']);
    let fake = Fake::body(&body);
    let ctx = ctx("utf8", Some(&fake.base));
    Poller::default().poll(
        &ctx,
        &mut WatchState::default(),
        0,
        Utc::now(),
        &mut no_step,
    );
    let lines = log(&ctx, "replies.log");
    assert_eq!(lines.len(), 1);
    assert!(
        lines[0].starts_with("reply aaa1 refused - format: "),
        "{lines:?}"
    );
    no_topic(&ctx);
}

#[test]
fn a_failed_save_is_logged_and_marks_nothing() {
    let fake = Fake::body(msg("aaa1", "hello").as_bytes());
    let ctx = ctx("save-fails", Some(&fake.base));
    let _held = try_lock(&ctx.p.replies_lock()).unwrap();
    let mut w = WatchState::default();
    Poller::default().poll(&ctx, &mut w, 0, Utc::now(), &mut no_step);
    let lines = log(&ctx, "replies.log");
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(lines[0].starts_with("reply aaa1 refused - "));
    assert_eq!(
        lines[1],
        "could not save where polling got to: data/replies.lock is held by another process"
    );
    let c = w.poll_caches();
    assert!(c.handled.tags().is_empty() && c.saved_at.is_none());
    no_topic(&ctx);
}

#[test]
fn a_state_only_powershell_reads_goes_to_a_fetch_step() {
    let fake = Fake::body(b"");
    let ctx = ctx("ps-only", Some(&fake.base));
    fs::write(ctx.p.replies(), r#"[{"lastId": "x"}, {"lastId": "y"}]"#).unwrap();
    let calls = RefCell::new(Vec::new());
    let mut step = |op: &str, w: &WatchState, args: Value| {
        calls.borrow_mut().push((op.to_string(), args));
        good(w, json!({"acted": 0}))
    };
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let t0 = Utc::now();
    p.poll(&ctx, &mut w, 0, t0, &mut step);
    p.poll(&ctx, &mut w, 0, t0 + TimeDelta::seconds(20), &mut step);
    let want = json!({"fetch": true, "maxMessages": 10, "quick": false, "timeoutSec": 8});
    assert_eq!(
        calls.into_inner(),
        [
            ("reply".to_string(), want.clone()),
            ("reply".to_string(), want)
        ]
    );
    assert!(fake.lines().is_empty(), "the step fetches");
    let said = log(&ctx, "watcher.log");
    assert_eq!(said.len(), 1, "said once: {said:?}");
    assert!(said[0].ends_with(" - PowerShell steps read the phone's replies"));
    no_topic(&ctx);
}

#[test]
fn a_state_that_does_not_read_is_a_poll_error() {
    let fake = Fake::body(b"");
    let ctx = ctx("unreadable", Some(&fake.base));
    fs::write(ctx.p.replies(), "{").unwrap();
    let mut w = WatchState::default();
    Poller::default().poll(&ctx, &mut w, 0, Utc::now(), &mut no_step);
    let lines = log(&ctx, "replies.log");
    assert_eq!(lines.len(), 1);
    assert!(
        lines[0].starts_with("poll error: data/replies.json could not be read: "),
        "{lines:?}"
    );
    assert!(fake.lines().is_empty());
    assert!(
        w.poll_caches().polled_at.is_some(),
        "after PolledAt, as PowerShell's catch"
    );
    no_topic(&ctx);
}

#[test]
fn replies_off_or_a_key_that_will_not_open_polls_nothing() {
    let fake = Fake::body(b"");
    for (name, cfg) in [
        (
            "off",
            json!({"reply": {"on": false, "topic": {"value": TOPIC, "protected": false}}}),
        ),
        (
            "no-key",
            json!({"reply": {"on": true, "topic": {"value": TOPIC, "protected": false},
                                    "key": {"value": "AQID", "protected": true}}}),
        ),
    ] {
        let ctx = ctx(name, Some(&fake.base));
        fs::write(ctx.p.config(), cfg.to_string()).unwrap();
        let mut w = WatchState::default();
        Poller::default().poll(&ctx, &mut w, 0, Utc::now(), &mut no_step);
        assert!(w.poll_caches().polled_at.is_none(), "{name}");
    }
    assert!(fake.lines().is_empty());
}

#[test]
fn the_ntfy_base_seam_stands_in_for_the_default_server_only() {
    let seam = Fake::body(b"");
    let named = Fake::body(b"");
    let mut ctx = ctx("seam", None);
    ctx.seams.ntfy_base = Some(seam.base.clone());
    let t0 = Utc::now();
    Poller::default().poll(&ctx, &mut WatchState::default(), 0, t0, &mut no_step);
    assert_eq!(seam.lines().len(), 1, "no server named: the seam's");
    let cfg = json!({"reply": {"on": true, "server": format!("{}/", named.base),
        "topic": {"value": TOPIC, "protected": false}, "key": {"value": KEY, "protected": false}}});
    fs::write(ctx.p.config(), cfg.to_string()).unwrap();
    Poller::default().poll(&ctx, &mut WatchState::default(), 0, t0, &mut no_step);
    assert_eq!(seam.lines().len(), 1);
    assert_eq!(named.lines().len(), 1, "config's server, its / trimmed");
    assert!(named.lines()[0].starts_with(&format!("GET /{TOPIC}/json?")));
    no_topic(&ctx);
}

#[test]
fn a_proxy_asking_for_credentials_is_said_once() {
    let ctx = ctx("proxy-auth", None);
    let mut p = Poller::with_fetch(|_| Err(Fail::ProxyAuth));
    let mut w = WatchState::default();
    let t0 = Utc::now();
    for s in [0, 20, 700] {
        p.poll(&ctx, &mut w, 0, t0 + TimeDelta::seconds(s), &mut no_step);
    }
    let d = fs::read_to_string(ctx.p.log_dir().join("chatqd.log")).unwrap();
    assert_eq!(d.matches("proxy needs authentication").count(), 1, "{d}");
    let line = "poll failed: proxy needs authentication";
    assert_eq!(log(&ctx, "replies.log"), [line, line]);
    no_topic(&ctx);
}

#[test]
fn a_connect_the_system_refuses_is_left_to_the_ps_watcher() {
    let ctx = ctx("forbidden", None);
    let mut seams = Seams::default();
    seams.connect_forbidden = true;
    let mut p = Poller::new(&seams);
    let mut w = WatchState::default();
    let before = Utc::now() - TimeDelta::seconds(30);
    let mut c = w.poll_caches();
    c.polled_at = Some(before);
    w.set_poll_caches(&c);
    assert!(!p.forbidden());
    assert_eq!(p.poll(&ctx, &mut w, 15, Utc::now(), &mut no_step), 0);
    assert!(p.forbidden());
    assert_eq!(log(&ctx, "watcher.log"), [FORBIDDEN_LINE]);
    assert!(log(&ctx, "replies.log").is_empty(), "no poll failed: line");
    // the PS watcher's first poll is not held back by this one
    let c = w.poll_caches();
    assert_eq!(c.polled_at.map(stamp_utc), Some(stamp_utc(before)));
    assert!(!ctx.p.replies().exists(), "nothing saved");
    no_topic(&ctx);
}

#[test]
fn a_failed_board_step_is_held_back() {
    let ctx = ctx("board", None);
    let mut p = Poller::default();
    let mut w = WatchState::default();
    let t0 = Utc::now();
    let n = RefCell::new(0);
    let mut fails = |_: &str, _: &WatchState, _: Value| {
        *n.borrow_mut() += 1;
        Outcome::DidNotStart("no".into())
    };
    p.board(&ctx, &mut w, t0, &mut fails);
    p.board(&ctx, &mut w, t0 + TimeDelta::seconds(30), &mut fails);
    p.board(&ctx, &mut w, t0 + TimeDelta::seconds(61), &mut fails);
    assert_eq!(*n.borrow(), 2);
    let said = "the board waits: a board step failed - tried again in a minute or more";
    assert_eq!(log(&ctx, "watcher.log"), [said]);
}
