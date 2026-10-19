//! The built chatqd against throwaway roots under native/target/test-data
//! (never a real data folder, never %TEMP%). Every launch it makes is
//! recorded through the `spawn` seam, so no PowerShell watcher starts.

use chatq_core::fsx::{lock_held, try_lock};
use chatq_core::launch::encode_command;
use chatq_core::paths::Paths;
use chatq_core::time::stamp_utc;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime};

const BIN: &str = env!("CARGO_BIN_EXE_chatqd");
const VER: &str = env!("CARGO_PKG_VERSION");
const PS: &str = r"C:\fake\WindowsPowerShell\v1.0\powershell.exe";
const TARGET: &str = chatq_core::launch::TARGET;

struct Root {
    dir: PathBuf,
    p: Paths,
}

/// Kills a watcher a failed assertion left waiting.
struct Running(Child);

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl Running {
    fn exit_within(&mut self, secs: u64) -> i32 {
        let t0 = Instant::now();
        loop {
            if let Some(s) = self.0.try_wait().unwrap() {
                return s.code().unwrap_or(-1);
            }
            assert!(
                t0.elapsed() < Duration::from_secs(secs),
                "chatqd still running after {secs} s"
            );
            sleep(Duration::from_millis(50));
        }
    }
}

fn root(name: &str) -> Root {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("target")
        .join("test-data")
        .join(format!("chatqd-{name}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("data")).unwrap();
    let r = Root {
        p: Paths::new(dir.to_str().unwrap()),
        dir,
    };
    r.loader(VER);
    r
}

impl Root {
    fn loader(&self, version: &str) {
        let text = format!("# a fake loader\r\n$script:ChatVersion = '{version}'\r\n");
        fs::write(self.p.loader(), text).unwrap();
    }

    fn capture(&self) -> PathBuf {
        self.dir.join("capture")
    }

    fn cmd(&self, hold: Option<f64>) -> Command {
        let mut s = json!({"spawn": true, "capture": self.capture()});
        if let Some(h) = hold {
            s["hold"] = json!(h);
        }
        self.cmd_with(&s)
    }

    fn cmd_with(&self, s: &Value) -> Command {
        let seams = self.dir.join("seams.json");
        fs::write(&seams, s.to_string()).unwrap();
        let mut c = Command::new(BIN);
        c.args(["watch", "--root", &self.p.root, "--script"])
            .arg(self.p.loader())
            .args(["--ps", PS])
            .env("CHATQ_NATIVE_SEAMS", &seams)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        for n in [
            "CHATQ_ENGINE",
            "CHATQ_CHATQD",
            "CHATQ_CLAUDE",
            "CHATQ_CODEX",
        ] {
            c.env_remove(n);
        }
        c
    }

    fn start(&self, c: &mut Command) -> Running {
        Running(c.spawn().unwrap())
    }

    /// One whole run that ends by itself.
    fn run(&self, c: &mut Command) -> i32 {
        self.start(c).exit_within(15)
    }

    fn log(&self, name: &str) -> String {
        fs::read_to_string(self.p.log_dir().join(name)).unwrap_or_default()
    }

    /// The text of each watcher.log line, its stamp dropped.
    fn lines(&self) -> Vec<String> {
        self.log("watcher.log")
            .lines()
            .map(|l| l.split_once("  ").unwrap().1.to_string())
            .collect()
    }

    fn json(&self, path: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn spawns(&self) -> Vec<Value> {
        (1..)
            .map(|n| self.capture().join(format!("spawn-{n}.json")))
            .take_while(|f| f.exists())
            .map(|f| self.json(&f))
            .collect()
    }

    fn until(&self, secs: u64, what: impl Fn() -> bool) {
        let t0 = Instant::now();
        while !what() {
            assert!(
                t0.elapsed() < Duration::from_secs(secs),
                "not within {secs} s"
            );
            sleep(Duration::from_millis(100));
        }
    }

    fn queue_job(&self, state: &str) {
        let q = self.p.queue_dir();
        fs::create_dir_all(&q).unwrap();
        let id = "20261015-101500-ab12";
        fs::write(
            q.join(format!("{id}.json")),
            json!({"id": id, "seq": 1, "state": state}).to_string(),
        )
        .unwrap();
    }
}

#[test]
fn version_matches_mismatches_and_unreadable() {
    let r = root("version");
    let out = Command::new(BIN)
        .args(["version", "--root", &r.p.root])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim_end(),
        format!("chatqd {VER} {TARGET}")
    );
    r.loader("9.9.9");
    let out = Command::new(BIN)
        .args(["version", "--root", &r.p.root])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim_end(),
        format!("chatqd {VER} {TARGET}: the scripts are 9.9.9")
    );
    fs::remove_file(r.p.loader()).unwrap();
    let out = Command::new(BIN)
        .args(["version", "--root", &r.p.root])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    let out = Command::new(BIN)
        .args(["watch", "--root"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(64));
}

#[test]
fn empty_queue_exits_and_lets_go() {
    let r = root("empty");
    // a stale stop is from an earlier watcher, not for this one
    fs::write(r.p.stop(), "").unwrap();
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    let lines = r.lines();
    assert_eq!(lines.len(), 3, "{lines:?}");
    assert!(lines[0].starts_with("watcher ") && lines[0].ends_with(&format!(" started ({VER})")));
    assert_eq!(lines[1], "queue empty");
    assert!(lines[2].ends_with(" stopped"));
    assert!(!r.p.stop().exists());
    assert!(!r.p.pid().exists());
    assert!(!lock_held(&r.p.lock()));
    let last = r.json(&r.p.last());
    assert_eq!(last["state"], "empty");
    assert_eq!(last["engine"], "native");
    assert_eq!(last["version"], VER);
    let st = r.json(&r.p.state());
    assert_eq!(st["handoff"], false);
    assert_eq!(st["version"], VER);
    assert_eq!(st["pid"], last["pid"]);
    let board = fs::read_to_string(r.p.board()).unwrap();
    assert!(board.starts_with(
        "# chatq\r\n\r\nchatq \u{b7} 0 queued \u{b7} watcher running \u{b7} updated "
    ));
    assert!(board.ends_with("\r\n\r\n_nothing queued_\r\n"));
    assert!(r.spawns().is_empty());
    assert!(
        r.log("chatqd.log")
            .contains("seam spawn: launches recorded in")
    );
}

#[test]
fn a_busy_lock_acks_and_leaves_last_alone() {
    let r = root("busy");
    let _held = try_lock(&r.p.lock()).unwrap();
    let last = r#"{"pid":1,"version":"x","engine":"native","state":"holding","at":"y"}"#;
    fs::create_dir_all(r.p.native_dir()).unwrap();
    fs::write(r.p.last(), last).unwrap();
    let mut w = r.start(&mut r.cmd(None));
    // the launcher's pending record, written before the 5 tries are over
    let pending = json!({"pid": w.0.id(), "version": VER, "at": stamp_utc(chrono::Utc::now())});
    fs::write(r.p.pending(), pending.to_string()).unwrap();
    assert_eq!(w.exit_within(10), 0);
    assert!(!r.p.pending().exists(), "the ack");
    assert_eq!(fs::read_to_string(r.p.last()).unwrap(), last);
    assert!(r.log("watcher.log").is_empty());
    assert!(
        r.log("chatqd.log")
            .contains("another watcher holds the lock")
    );
}

#[test]
fn stop_while_holding() {
    let r = root("hold-stop");
    let mut w = r.start(&mut r.cmd(Some(1.0)));
    r.until(10, || {
        r.p.state().exists() && r.json(&r.p.state())["next"].is_string()
    });
    assert!(lock_held(&r.p.lock()));
    assert!(r.p.pid().exists());
    assert_eq!(r.json(&r.p.last())["state"], "holding");
    // a launcher that wrote its pending record after the first ack
    let pending = json!({"pid": w.0.id(), "version": VER, "at": stamp_utc(chrono::Utc::now())});
    fs::write(r.p.pending(), pending.to_string()).unwrap();
    fs::write(r.p.stop(), "").unwrap();
    assert_eq!(w.exit_within(6), 0);
    assert!(!r.p.pending().exists(), "acked again at exit");
    let lines = r.lines();
    assert_eq!(lines[1], "stop requested", "{lines:?}");
    assert!(!r.p.stop().exists());
    assert_eq!(r.json(&r.p.last())["state"], "stopped");
    assert!(r.json(&r.p.state())["next"].is_null());
    assert!(r.spawns().is_empty());
    assert!(r.log("chatqd.log").contains("seam hold: 1 min"));
}

#[test]
fn wake_now_fresh_and_stale() {
    let r = root("hold-wake");
    let mut w = r.start(&mut r.cmd(Some(1.0)));
    r.until(10, || {
        r.p.state().exists() && r.json(&r.p.state())["next"].is_string()
    });
    fs::write(r.p.wake(), "NOW\r\n").unwrap();
    r.until(6, || r.lines().iter().any(|l| l == "woken: -Now"));
    r.until(2, || fs::read_to_string(r.p.wake()).unwrap() == "seen\r\n");
    // a -Now left lying around: the mtime changes, the word is ignored
    fs::write(r.p.wake(), "now\r\n").unwrap();
    let f = fs::File::options().write(true).open(r.p.wake()).unwrap();
    f.set_modified(SystemTime::now() - Duration::from_secs(600))
        .unwrap();
    drop(f);
    sleep(Duration::from_secs(5));
    assert_eq!(r.lines().iter().filter(|l| *l == "woken: -Now").count(), 1);
    assert_eq!(fs::read_to_string(r.p.wake()).unwrap(), "now\r\n");
    fs::write(r.p.stop(), "").unwrap();
    assert_eq!(w.exit_within(6), 0);
}

#[test]
fn a_queued_job_hands_over_and_leaves_the_now() {
    let r = root("handoff");
    r.queue_job("queued");
    fs::write(r.p.wake(), "now\r\n").unwrap();
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    let lines = r.lines();
    assert_eq!(lines.len(), 2, "started and stopped only: {lines:?}");
    assert_eq!(
        fs::read_to_string(r.p.wake()).unwrap(),
        "now\r\n",
        "left for the PS watcher"
    );
    assert_eq!(r.json(&r.p.state())["handoff"], true);
    assert_eq!(r.json(&r.p.last())["state"], "handed-over");
    assert!(
        r.log("chatqd.log")
            .contains("handing over to the PowerShell watcher: a job is queued")
    );
    let s = r.spawns();
    assert_eq!(s.len(), 1);
    assert_eq!(s[0]["engine"], "ps");
    assert_eq!(s[0]["exe"], PS);
    let cmd = s[0]["command"].as_str().unwrap();
    let script = r.p.loader().to_string_lossy().into_owned();
    assert!(
        cmd.starts_with(&format!("$env:CHATQ_WATCHER='1'; try {{ . '{script}' }}")),
        "{cmd}"
    );
    assert!(cmd.ends_with("; Invoke-ChatqWatchLoop"));
    let line = format!(
        "\"{PS}\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {}",
        encode_command(cmd)
    );
    assert_eq!(s[0]["cmdline"], line);
    assert_eq!(
        s[0]["cwd"],
        std::env::var("USERPROFILE").unwrap_or_default()
    );
}

#[test]
fn other_first_pass_duties_hand_over() {
    let r = root("handoff-more");
    let soon = stamp_utc(chrono::Utc::now() + chrono::Duration::minutes(30));
    let cfg = json!({"reply": {"on": true, "topic": "t", "key": "k"}});
    fs::write(r.p.config(), cfg.to_string()).unwrap();
    fs::write(r.p.replies(), json!({"openUntil": soon}).to_string()).unwrap();
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    assert!(
        r.log("chatqd.log")
            .contains(": the phone reply window is open")
    );

    // handed-over state with a lane limited until later: carried, and the
    // board would name the lane
    let r = root("handoff-carry");
    let st = json!({"handoff": true, "blocked": {"claude": {"until": soon, "type": "session", "source": "probe"}}});
    fs::write(r.p.state(), st.to_string()).unwrap();
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    assert_eq!(r.lines()[1], "carrying on from the watcher before it");
    assert!(
        r.log("chatqd.log")
            .contains(": the board shows more than an empty queue")
    );
    assert_eq!(r.json(&r.p.state())["blocked"]["claude"]["until"], soon);

    let r = root("handoff-repair");
    r.queue_job("running");
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    assert!(
        r.log("chatqd.log")
            .contains(": the watcher before it left something to repair")
    );
}

#[test]
fn a_panic_strikes_runs_the_finally_and_hands_over() {
    let r = root("panic");
    let s = json!({"spawn": true, "capture": r.capture(), "panic": true});
    assert_eq!(r.run(&mut r.cmd_with(&s)), 0);
    let d = r.log("chatqd.log");
    assert!(d.contains("chatqd panicked: the panic seam"), "{d}");
    assert!(d.contains("handing over to the PowerShell watcher: chatqd panicked"));
    let last = r.json(&r.p.last());
    assert_eq!(last["state"], "handed-over");
    let fuse = r.json(&r.p.fuse());
    assert_eq!(fuse["version"], VER);
    assert_eq!(fuse["strikes"][0]["why"], "panic");
    assert_eq!(fuse["strikes"][0]["pid"], last["pid"]);
    assert!(!lock_held(&r.p.lock()));
    assert!(!r.p.pid().exists());
    assert_eq!(r.json(&r.p.state())["handoff"], true);
    assert!(r.lines().last().unwrap().ends_with(" stopped"));
    let s = r.spawns();
    assert_eq!(s.len(), 1, "{s:?}");
    assert_eq!(s[0]["engine"], "ps");
}

#[test]
fn restart_respawns_native_after_preflight() {
    let r = root("restart-native");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(r.run(r.cmd(None).env("CHATQ_CHATQD", BIN)), 0);
    assert!(
        r.lines()
            .iter()
            .any(|l| l == "a newer copy was installed - handing over")
    );
    assert!(!r.p.restart().exists());
    assert_eq!(r.json(&r.p.last())["state"], "handed-over");
    assert_eq!(r.json(&r.p.state())["handoff"], true);
    let s = r.spawns();
    assert_eq!(s.len(), 1, "{s:?}");
    assert_eq!(s[0]["engine"], "native");
    // chatqd names the binary as Identity::of resolves it, whatever separators
    // a --target-dir gave CARGO_BIN_EXE
    let bin = std::path::absolute(BIN)
        .unwrap()
        .to_string_lossy()
        .into_owned();
    assert_eq!(s[0]["exe"], bin);
    let script = r.p.loader().to_string_lossy().into_owned();
    assert_eq!(
        s[0]["args"],
        json!(["watch", "--root", r.p.root, "--script", script, "--ps", PS])
    );
    assert!(s[0]["command"].is_null());
    let v = r.json(&r.p.verified());
    assert_eq!(v["passed"][0]["path"], bin);
}

#[test]
fn respawn_goes_to_ps_when_native_may_not_run() {
    // no binary at R/bin/<version>/<target>/
    let r = root("restart-nobin");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(r.run(&mut r.cmd(None)), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert!(r.log("chatqd.log").contains("no runnable chatqd at"));

    let r = root("restart-engine");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(
        r.run(
            r.cmd(None)
                .env("CHATQ_CHATQD", BIN)
                .env("CHATQ_ENGINE", "ps")
        ),
        0
    );
    assert_eq!(r.spawns()[0]["engine"], "ps");

    // a launch before this one that was never acked: a strike, so PS
    let r = root("restart-noack");
    fs::write(r.p.restart(), "").unwrap();
    fs::create_dir_all(r.p.native_dir()).unwrap();
    let old = stamp_utc(chrono::Utc::now() - chrono::Duration::minutes(1));
    fs::write(
        r.p.pending(),
        json!({"pid": 4_000_000_000u32, "version": VER, "at": old}).to_string(),
    )
    .unwrap();
    assert_eq!(r.run(r.cmd(None).env("CHATQ_CHATQD", BIN)), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert_eq!(r.json(&r.p.fuse())["strikes"][0]["why"], "no ack");
    assert!(!r.p.pending().exists());

    // a blown fuse
    let r = root("restart-fuse");
    fs::write(r.p.restart(), "").unwrap();
    fs::create_dir_all(r.p.native_dir()).unwrap();
    let now = stamp_utc(chrono::Utc::now());
    let strike = json!({"at": now, "why": "crash", "pid": 1});
    let fuse = json!({"version": VER, "strikes": [strike, strike, strike], "alerted": false});
    fs::write(r.p.fuse(), fuse.to_string()).unwrap();
    assert_eq!(r.run(r.cmd(None).env("CHATQ_CHATQD", BIN)), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert!(r.log("chatqd.log").contains("failed 3 times"));

    // the scripts were updated to a version this binary is not
    let r = root("restart-newver");
    fs::write(r.p.restart(), "").unwrap();
    r.loader("99.0.0");
    assert_eq!(r.run(r.cmd(None).env("CHATQ_CHATQD", BIN)), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert!(r.log("chatqd.log").contains("preflight failed"));
    assert_eq!(r.json(&r.p.fuse())["version"], "99.0.0");
}

#[test]
fn restart_starts_a_real_native_successor() {
    // no spawn seam: the successor is this same binary, in this same
    // throwaway root, and it leaves at once on the empty queue
    let r = root("restart-live");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(r.run(r.cmd_with(&json!({})).env("CHATQ_CHATQD", BIN)), 0);
    r.until(15, || {
        r.lines().iter().filter(|l| l.ends_with(" stopped")).count() == 2
    });
    let lines = r.lines();
    assert_eq!(
        lines.iter().filter(|l| l.contains(" started (")).count(),
        2,
        "{lines:?}"
    );
    assert_eq!(
        lines
            .last()
            .map(String::as_str)
            .map(|l| l.ends_with(" stopped")),
        Some(true)
    );
    assert!(
        lines
            .iter()
            .any(|l| l == "carrying on from the watcher before it")
    );
    assert!(lines.iter().any(|l| l == "queue empty"));
    assert_eq!(r.json(&r.p.last())["state"], "empty");
    assert!(!r.p.pending().exists(), "the successor acked");
    assert!(!r.p.fuse().exists(), "no strike");
    assert!(r.log("chatqd.log").contains("starting chatqd "));
}
