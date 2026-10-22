//! The helper-step runner (SPEC 3.6): one op of PowerShell work, run by a
//! fresh PowerShell through src/native-step.ps1, with W in and W out.

use super::Ctx;
use super::spawn::home;
use crate::sys;
use chatq_core::fsx::{read_json, save_text};
use chatq_core::json::to_pretty;
use chatq_core::state::WatchState;
use serde_json::{Map, Value, json};
use std::fs;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

/// How long one wait for a step lasts before the stop file is looked at.
const SLICE: Duration = Duration::from_secs(2);

/// Launch attempts in this chatqd's life, so `<n>` is never reused.
static STEPS: AtomicU32 = AtomicU32::new(0);

/// How a step ended (SPEC 3.6 "Failure").
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// a good `ok:true` answer: the W to take whole, and the op's result
    Ok(Box<WatchState>, Map<String, Value>),
    /// the launch itself failed, with the OS error text
    DidNotStart(String),
    /// a good `ok:false` answer, with its error
    Failed(String),
    /// no good answer, exit code 3: the loader failed
    DidNotLoad,
    /// no good answer, any other exit code
    NoAnswer(i32),
}

impl Outcome {
    /// The `<reason>` of `helper step <reason>`; None for Ok.
    pub fn reason(&self) -> Option<String> {
        match self {
            Outcome::Ok(..) => None,
            Outcome::DidNotStart(_) => Some("did not start".into()),
            Outcome::Failed(e) => Some(format!("failed: {e}")),
            Outcome::DidNotLoad => Some("did not load (exit 3)".into()),
            Outcome::NoAnswer(code) => Some(format!("exited {code} with no answer")),
        }
    }
}

/// The fields each op's `result` must hold (SPEC 3.6 "Ops").
fn result_fields(op: &str) -> &'static [&'static str] {
    match op {
        "pick" => &["gone"],
        "stray" => &["removed"],
        "soon" => &["soonAt"],
        "held" | "alert" => &["sent"],
        "job-write" => &["saved"],
        "reply" => &["acted"],
        _ => &[],
    }
}

/// `In`: `{v, op, watcherPid, startedAt, alertJob, w, args}`.
fn in_json(ctx: &Ctx, op: &str, alert_job: Option<&str>, w: &WatchState, args: Value) -> Value {
    json!({
        "v": 1,
        "op": op,
        "watcherPid": ctx.pid,
        "startedAt": w.started_at,
        "alertJob": alert_job,
        "w": w.to_w(),
        "args": args,
    })
}

/// The command line after `--ps`: [native-step.ps1](src/native-step.ps1)'s.
fn step_args(ctx: &Ctx, n: u32, start: i64, seams: Option<String>) -> Vec<String> {
    let p = &ctx.p;
    let path = |b: std::path::PathBuf| b.to_string_lossy().into_owned();
    let mut a: Vec<String> = [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
    ]
    .map(String::from)
    .into();
    a.push(path(p.native_step()));
    a.extend([
        "-In".into(),
        path(p.step_in(n)),
        "-Out".into(),
        path(p.step_out(n)),
        "-Watcher".into(),
        ctx.pid.to_string(),
        "-WatcherStart".into(),
        start.to_string(),
    ]);
    if let Some(s) = seams {
        a.extend(["-Seams".into(), s]);
    }
    a
}

/// `Out` as read, and the step's exit code, as one outcome: a good answer
/// first, whatever the code, then the code.
fn classify(op: &str, out: Option<&Value>, code: i32) -> Outcome {
    if let Some(m) = out.and_then(Value::as_object)
        && m.get("v").and_then(Value::as_i64) == Some(1)
    {
        match m.get("ok").and_then(Value::as_bool) {
            Some(true) => {
                let w = m.get("w").and_then(WatchState::from_w);
                let result = m
                    .get("result")
                    .and_then(Value::as_object)
                    .filter(|r| result_fields(op).iter().all(|f| r.contains_key(*f)));
                if let (Some(w), Some(r)) = (w, result) {
                    return Outcome::Ok(Box::new(w), r.clone());
                }
            }
            Some(false) => {
                if let Some(e) = m.get("error").and_then(Value::as_str) {
                    return Outcome::Failed(e.into());
                }
            }
            None => {}
        }
    }
    if code == 3 {
        Outcome::DidNotLoad
    } else {
        Outcome::NoAnswer(code)
    }
}

/// Runs `op` with `args` over `w` and waits for it, however long: a `pick`
/// may run for hours. A stop file seen meanwhile is logged once and left for
/// the loop. Both exchange files are gone afterwards, whatever the outcome.
pub fn run(ctx: &Ctx, op: &str, alert_job: Option<&str>, w: &WatchState, args: Value) -> Outcome {
    let p = &ctx.p;
    let n = STEPS.fetch_add(1, Ordering::Relaxed) + 1;
    let (step_in, step_out) = (p.step_in(n), p.step_out(n));
    let seams = std::env::var("CHATQ_NATIVE_SEAMS")
        .ok()
        .filter(|s| !s.is_empty());
    let t0 = Instant::now();
    let launched = save_text(&step_in, &to_pretty(&in_json(ctx, op, alert_job, w, args)))
        .and_then(|()| sys::own_start_ticks())
        .and_then(|start| {
            let args = step_args(ctx, n, start, seams);
            sys::spawn_waited(&ctx.args.ps, &args, &home(ctx))
        });
    let outcome = match launched {
        Err(e) => {
            ctx.dlog(&format!("step {n} {op}: helper step did not start ({e})"));
            Outcome::DidNotStart(e.to_string())
        }
        Ok(mut child) => {
            let mut stop_seen = false;
            let code = loop {
                if let Some(code) = child.wait(SLICE) {
                    break code;
                }
                if !stop_seen && p.stop().exists() {
                    stop_seen = true;
                    ctx.dlog(&format!("stop seen while step {n} ({op}) runs"));
                }
            };
            let ms = t0.elapsed().as_millis();
            ctx.dlog(&format!("step {n} {op} exited {code} after {ms} ms"));
            let o = classify(op, read_json(&step_out, ctx.fl).as_ref(), code);
            if let Some(why) = o.reason() {
                ctx.dlog(&format!("step {n} {op}: helper step {why}"));
            }
            o
        }
    };
    let _ = fs::remove_file(&step_in);
    let _ = fs::remove_file(&step_out);
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seams::Seams;
    use crate::watch::Args;
    use chatq_core::culture::Culture;
    use chatq_core::paths::Paths;
    use chatq_core::time::Flavour;
    use std::path::Path;

    fn ctx(name: &str, ps: &str) -> Ctx {
        let r = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/chatqd-step")
            .join(name);
        let _ = fs::remove_dir_all(&r);
        fs::create_dir_all(&r).unwrap();
        let root = r.to_string_lossy().into_owned();
        Ctx {
            p: Paths::new(&root),
            pid: 4242,
            fl: Flavour::Desktop,
            culture: Culture::invariant(),
            seams: Seams::default(),
            args: Args {
                root,
                script: "x.ps1".into(),
                ps: ps.into(),
                culture: None,
            },
        }
    }

    fn state() -> WatchState {
        WatchState {
            started_at: "2026-10-18T01:02:03.0000000Z".into(),
            current: Some("j1".into()),
            ..Default::default()
        }
    }

    fn answer(ok: bool, result: Value) -> Value {
        json!({"v": 1, "ok": ok, "error": null, "w": state().to_w(), "result": result})
    }

    #[test]
    fn in_names_the_op_the_watcher_and_its_w() {
        let c = ctx("in", "ps.exe");
        let v = in_json(&c, "pick", Some("#7"), &state(), json!({"jobId": "j1"}));
        assert_eq!(v["v"], 1);
        assert_eq!(v["op"], "pick");
        assert_eq!(v["watcherPid"], 4242);
        assert_eq!(v["startedAt"], "2026-10-18T01:02:03.0000000Z");
        assert_eq!(v["alertJob"], "#7");
        assert_eq!(v["w"], state().to_w());
        assert_eq!(v["args"], json!({"jobId": "j1"}));
        let v = in_json(&c, "stray", None, &state(), json!({}));
        assert!(v["alertJob"].is_null());
    }

    #[test]
    fn the_command_line_is_native_steps() {
        let c = ctx("args", "ps.exe");
        let p = &c.p;
        let s = |b: std::path::PathBuf| b.to_string_lossy().into_owned();
        let a = step_args(&c, 5, 638_000_000_000_000_000, None);
        let mut want: Vec<String> = [
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ]
        .map(String::from)
        .into();
        want.extend([
            s(p.native_step()),
            "-In".into(),
            s(p.step_in(5)),
            "-Out".into(),
            s(p.step_out(5)),
            "-Watcher".into(),
            "4242".into(),
            "-WatcherStart".into(),
            "638000000000000000".into(),
        ]);
        assert_eq!(a, want);
        let a = step_args(&c, 5, 1, Some(r"C:\t\seams.json".into()));
        assert_eq!(a[a.len() - 2..], ["-Seams", r"C:\t\seams.json"]);
    }

    /// Out as the step leaves it on disk, read the way [run] reads it.
    fn outcome(c: &Ctx, op: &str, text: Option<&str>, code: i32) -> Outcome {
        let out = c.p.step_out(1);
        if let Some(t) = text {
            fs::create_dir_all(c.p.native_dir()).unwrap();
            fs::write(&out, t).unwrap();
        }
        classify(op, read_json(&out, c.fl).as_ref(), code)
    }

    #[test]
    fn a_good_answer_is_ok_whatever_the_exit_code() {
        let c = ctx("ok", "ps.exe");
        let text = answer(true, json!({"gone": false})).to_string();
        let Outcome::Ok(w, r) = outcome(&c, "pick", Some(&text), 1) else {
            panic!("not ok");
        };
        assert_eq!(*w, WatchState::from_w(&state().to_w()).unwrap());
        assert_eq!(r["gone"], false);
        // PS writes {} for an op with no result fields
        let text = answer(true, json!({})).to_string();
        assert!(matches!(
            outcome(&c, "auto", Some(&text), 0),
            Outcome::Ok(..)
        ));
    }

    #[test]
    fn ok_false_is_failed_with_its_error() {
        let c = ctx("failed", "ps.exe");
        let text = r#"{"v":1,"ok":false,"error":"bad step input","w":null,"result":null}"#;
        let o = outcome(&c, "held", Some(text), 0);
        assert_eq!(o, Outcome::Failed("bad step input".into()));
        assert_eq!(o.reason().unwrap(), "failed: bad step input");
    }

    #[test]
    fn no_good_answer_is_the_exit_code() {
        let c = ctx("bad", "ps.exe");
        let o = outcome(&c, "pick", None, 3);
        assert_eq!(o, Outcome::DidNotLoad);
        assert_eq!(o.reason().unwrap(), "did not load (exit 3)");
        let o = outcome(&c, "pick", None, -1073741510);
        assert_eq!(o.reason().unwrap(), "exited -1073741510 with no answer");
        // each of these is no good answer
        let mut w_bad = answer(true, json!({"gone": true}));
        w_bad["w"]["caches"] = json!({});
        let mut v_bad = answer(true, json!({"gone": true}));
        v_bad["v"] = 2.into();
        for text in [
            "not json".to_string(),
            "[]".into(),
            answer(true, json!({})).to_string(),
            answer(true, json!(null)).to_string(),
            w_bad.to_string(),
            v_bad.to_string(),
            r#"{"v":1,"ok":false,"error":null,"w":null,"result":null}"#.into(),
            r#"{"v":1,"ok":"yes","error":null,"w":null,"result":null}"#.into(),
        ] {
            assert_eq!(
                outcome(&c, "pick", Some(&text), 0),
                Outcome::NoAnswer(0),
                "{text}"
            );
        }
    }

    #[test]
    fn a_step_that_cannot_start_leaves_no_file_and_a_line() {
        let mut c = ctx("no-ps", "");
        let missing = c.p.native_dir().join("no-such-powershell.exe");
        c.args.ps = missing.to_string_lossy().into_owned();
        let o = run(&c, "stray", None, &state(), json!({}));
        assert!(matches!(o, Outcome::DidNotStart(_)), "{o:?}");
        assert_eq!(o.reason().unwrap(), "did not start");
        let left: Vec<_> = fs::read_dir(c.p.native_dir()).unwrap().flatten().collect();
        assert!(left.is_empty(), "{left:?}");
        let log = fs::read_to_string(c.p.log_dir().join("chatqd.log")).unwrap();
        assert!(log.contains(" stray: helper step did not start ("), "{log}");
    }
}
