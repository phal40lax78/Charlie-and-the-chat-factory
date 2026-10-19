//! The built chatqd against throwaway roots under native/target/test-data
//! (never a real data folder, never %TEMP%). Every launch it makes is
//! recorded through the `spawn` seam, so no PowerShell watcher starts. A case
//! with a job runs its helper steps in a real PowerShell, against a stub
//! R/src/native-step.ps1 ([STUB]) that keeps each `In` and `Out`, sends W
//! back as it came and answers as the case's stub.json says.

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
const ID: &str = "20261015-101500-ab12";

/// A stand-in for src/native-step.ps1. `stub.json` maps an op to `{exit,
/// out, result}`: the exit code, `out: false` for no `Out` at all, and the
/// result in place of the op's default. A pick with no entry is a run that
/// ends done.
const STUB: &str = r#"param([string]$In, [string]$Out, [string]$Watcher, [string]$WatcherStart, [string]$Seams)
$root = Split-Path -Parent $PSScriptRoot
$raw = [IO.File]::ReadAllText($In)
# not $in: names are case-blind, and [string]$In would take it as text
$req = $raw | ConvertFrom-Json
$log = Join-Path $root 'stub-steps'
$null = New-Item -ItemType Directory -Force -Path $log
$n = @(Get-ChildItem -LiteralPath $log).Count + 1
[IO.File]::WriteAllText((Join-Path $log "$n.json"), $raw)
$plan = $null
$pf = Join-Path $root 'stub.json'
if (Test-Path -LiteralPath $pf) { $plan = ([IO.File]::ReadAllText($pf) | ConvertFrom-Json).($req.op) }
$result = switch ($req.op) {
    'pick' { @{ gone = $false } }
    'stray' { @{ removed = 0 } }
    'soon' { @{ soonAt = $null } }
    'held' { @{ sent = $true } }
    'alert' { @{ sent = $true } }
    'job-write' { @{ saved = $true } }
    default { @{} }
}
if ($plan -and $null -ne $plan.result) { $result = $plan.result }
if ($req.op -eq 'pick' -and -not $plan) {
    $f = Join-Path (Join-Path (Join-Path $root 'data') 'queue') "$($req.args.jobId).json"
    $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    $j.state = 'done'
    [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 8))
}
if (-not $plan -or $plan.out -ne $false) {
    # the parent check's reading: chatqd's start as .NET has it, in ticks
    # from -WatcherStart, kept in stub-outs as chatqd deletes Out
    $off = [Math]::Abs((Get-Process -Id ([int]$Watcher)).StartTime.ToUniversalTime().Ticks - [long]$WatcherStart)
    $o = @{ v = 1; ok = $true; error = $null; w = $req.w; result = $result; startOff = $off }
    $text = $o | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Out, $text)
    $outs = Join-Path $root 'stub-outs'
    $null = New-Item -ItemType Directory -Force -Path $outs
    [IO.File]::WriteAllText((Join-Path $outs "$n.json"), $text)
}
exit $(if ($plan -and $plan.exit) { [int]$plan.exit } else { 0 })
"#;

/// The PowerShell a real step runs in: Windows PowerShell, or pwsh where
/// there is none. None where neither is there.
fn real_ps() -> Option<String> {
    if cfg!(windows) {
        let root = std::env::var("SystemRoot").ok()?;
        return Some(format!(
            r"{root}\System32\WindowsPowerShell\v1.0\powershell.exe"
        ));
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join("pwsh"))
        .find(|f| f.is_file())
        .map(|f| f.to_string_lossy().into_owned())
}

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

    fn cmd(&self) -> Command {
        self.cmd_with(&json!({"spawn": true, "capture": self.capture()}))
    }

    fn cmd_with(&self, s: &Value) -> Command {
        self.cmd_ps(s, PS)
    }

    /// A run whose steps go to the stub under a real PowerShell, answering
    /// as `plan` says; None, with a note, where there is no PowerShell.
    fn stepping(&self, plan: Value) -> Option<Command> {
        let Some(ps) = real_ps() else {
            eprintln!("no PowerShell here: the case runs no step and checks nothing");
            return None;
        };
        let src = self.p.native_step();
        fs::create_dir_all(src.parent().unwrap()).unwrap();
        fs::write(&src, STUB).unwrap();
        fs::write(self.dir.join("stub.json"), plan.to_string()).unwrap();
        let s = json!({"spawn": true, "capture": self.capture()});
        Some(self.cmd_ps(&s, &ps))
    }

    fn cmd_ps(&self, s: &Value, ps: &str) -> Command {
        let seams = self.dir.join("seams.json");
        fs::write(&seams, s.to_string()).unwrap();
        let mut c = Command::new(BIN);
        c.args(["watch", "--root", &self.p.root, "--script"])
            .arg(self.p.loader())
            .args(["--ps", ps])
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

    fn job_file(&self) -> PathBuf {
        self.p.queue_dir().join(format!("{ID}.json"))
    }

    /// Job ID, queued, with `more` over its fields.
    fn queue_job(&self, more: Value) {
        let mut job =
            json!({"id": ID, "seq": 1, "title": "fix it", "state": "queued", "history": []});
        for (k, v) in more.as_object().unwrap() {
            job[k] = v.clone();
        }
        fs::create_dir_all(self.p.queue_dir()).unwrap();
        fs::write(self.job_file(), job.to_string()).unwrap();
    }

    /// Each step's `In`, in the order the stub saw them.
    fn steps(&self) -> Vec<Value> {
        (1..)
            .map(|n| self.dir.join("stub-steps").join(format!("{n}.json")))
            .take_while(|f| f.exists())
            .map(|f| self.json(&f))
            .collect()
    }

    fn ops(&self) -> Vec<String> {
        self.steps()
            .iter()
            .map(|s| s["op"].as_str().unwrap().to_string())
            .collect()
    }
}

/// A wait for real: a job queued not before an hour from now.
fn waiting(name: &str) -> Option<(Root, Command)> {
    let r = root(name);
    let c = r.stepping(json!({}))?;
    let later = stamp_utc(chrono::Utc::now() + chrono::Duration::hours(1));
    r.queue_job(json!({"notBefore": later}));
    Some((r, c))
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
    assert_eq!(r.run(&mut r.cmd()), 0);
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
    let mut w = r.start(&mut r.cmd());
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
fn stop_while_waiting() {
    let Some((r, mut c)) = waiting("wait-stop") else {
        return;
    };
    let mut w = r.start(&mut c);
    r.until(60, || {
        r.p.state().exists() && r.json(&r.p.state())["next"].is_string()
    });
    assert!(lock_held(&r.p.lock()));
    assert!(r.p.pid().exists());
    assert_eq!(r.json(&r.p.last())["state"], "holding");
    // a launcher that wrote its pending record after the first ack
    let pending = json!({"pid": w.0.id(), "version": VER, "at": stamp_utc(chrono::Utc::now())});
    fs::write(r.p.pending(), pending.to_string()).unwrap();
    fs::write(r.p.stop(), "").unwrap();
    assert_eq!(w.exit_within(10), 0);
    assert!(!r.p.pending().exists(), "acked again at exit");
    let lines = r.lines();
    assert_eq!(lines[1], "stop requested", "{lines:?}");
    assert!(!r.p.stop().exists());
    assert_eq!(r.json(&r.p.last())["state"], "stopped");
    assert!(r.json(&r.p.state())["next"].is_null());
    assert!(r.spawns().is_empty());
    // the lane was never scanned: one block step, and then the wait
    assert_eq!(r.ops(), ["block"]);
    assert_eq!(r.steps()[0]["args"], json!({"jobIds": [ID]}));
    let d = r.log("chatqd.log");
    assert!(d.contains("step 1 block exited 0 after "), "{d}");
    assert!(!d.contains("helper step"), "a good answer: {d}");
}

#[test]
fn wake_now_fresh_and_stale() {
    let Some((r, mut c)) = waiting("wait-wake") else {
        return;
    };
    let mut w = r.start(&mut c);
    r.until(60, || {
        r.p.state().exists() && r.json(&r.p.state())["next"].is_string()
    });
    fs::write(r.p.wake(), "NOW\r\n").unwrap();
    // state.json is saved just before the wait reads wake's mtime, so a
    // write in between is seen only by the next pass, a wait (30 s) later
    r.until(35, || r.lines().iter().any(|l| l == "woken: -Now"));
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
    assert_eq!(w.exit_within(10), 0);
    // the -Now stamped the lane as scanned, so no scan came after it
    assert_eq!(r.ops(), ["block"]);
}

#[test]
fn a_queued_job_is_picked_through_a_step_the_now_taken() {
    let r = root("pick");
    let Some(mut c) = r.stepping(json!({})) else {
        return;
    };
    let later = stamp_utc(chrono::Utc::now() + chrono::Duration::hours(1));
    r.queue_job(json!({"deferUntil": later}));
    fs::write(r.p.wake(), "now\r\n").unwrap();
    assert_eq!(r.start(&mut c).exit_within(60), 0);
    let lines = r.lines();
    assert_eq!(lines.len(), 4, "{lines:?}");
    assert_eq!(lines[1..3], ["woken: -Now", "queue empty"]);
    assert_eq!(fs::read_to_string(r.p.wake()).unwrap(), "seen\r\n");
    let job = r.json(&r.job_file());
    assert!(job["deferUntil"].is_null(), "the -Now's write");
    assert_eq!(job["state"], "done", "the stub's run");
    // the -Now stamped the job's lane, so no scan came before the pick
    assert_eq!(r.ops(), ["pick"]);
    let st = r.json(&r.p.state());
    let pick = &r.steps()[0];
    assert_eq!(pick["alertJob"], "#1");
    assert_eq!(pick["args"], json!({"jobId": ID}));
    assert_eq!(pick["watcherPid"], st["pid"]);
    assert_eq!(pick["w"]["scannedAt"][0]["k"], "");
    assert!(pick["w"]["scannedAt"][0]["v"].is_string());
    assert_eq!(st["handoff"], false);
    assert_eq!(r.json(&r.p.last())["state"], "empty");
    assert!(r.spawns().is_empty(), "no handoff");
    let d = r.log("chatqd.log");
    assert!(d.contains("step 1 pick exited 0 after "), "{d}");
    assert!(!d.contains("helper step"), "a good answer: {d}");
    assert!(!r.p.step_in(1).exists() && !r.p.step_out(1).exists());
    // -WatcherStart against (Get-Process -Id <chatqd>).StartTime, as the
    // step's parent check reads them: within its 1 s
    let out = r.json(&r.dir.join("stub-outs").join("1.json"));
    let off = out["startOff"].as_i64().unwrap();
    assert!(off <= 10_000_000, "{off} ticks apart");
}

#[test]
fn a_pick_that_does_not_answer_fails_its_job() {
    let r = root("pick-fails");
    let Some(mut c) = r.stepping(json!({"pick": {"out": false, "exit": 5}})) else {
        return;
    };
    r.queue_job(json!({"seq": 3}));
    assert_eq!(r.start(&mut c).exit_within(60), 0);
    let why = "helper step exited 5 with no answer";
    let lines = r.lines();
    assert_eq!(lines[1], format!("#3 error: {why}"), "{lines:?}");
    assert_eq!(lines[2], "queue empty");
    let job = r.json(&r.job_file());
    assert_eq!(job["state"], "failed");
    assert_eq!(
        job["result"],
        json!({"kind": "failed", "reason": format!("chatq error: {why}")})
    );
    assert_eq!(job["history"][0]["state"], "failed");
    assert_eq!(job["history"][0]["why"], "chatq error");
    assert!(job["runnerPid"].is_null() && job["endedAt"].is_string());
    assert!(
        r.log("jobs.log")
            .contains("  #3 failed - chatq error \u{b7} fix it")
    );
    assert_eq!(r.ops(), ["block", "pick", "alert"]);
    let alert = &r.steps()[2];
    assert_eq!(alert["alertJob"], "#3");
    let text = format!("fix it \u{b7} chatq error: {why}");
    assert_eq!(
        alert["args"],
        json!({"event": "failed", "text": text, "priority": 2, "jobId": ID,
            "loud": false, "quick": false, "noReply": false, "usageKind": null})
    );
    let d = r.log("chatqd.log");
    assert!(d.contains("step 2 pick exited 5 after "), "{d}");
    assert!(d.contains(&format!("step 2 pick: {why}")), "{d}");
    assert!(
        !d.contains("step 3 alert: helper step"),
        "the alert went: {d}"
    );
    assert!(r.spawns().is_empty());
}

#[test]
fn an_open_reply_window_hands_over_with_w() {
    let r = root("handoff");
    let soon = stamp_utc(chrono::Utc::now() + chrono::Duration::minutes(30));
    let cfg = json!({"reply": {"on": true, "topic": "t", "key": "k"}});
    fs::write(r.p.config(), cfg.to_string()).unwrap();
    fs::write(r.p.replies(), json!({"openUntil": soon}).to_string()).unwrap();
    fs::write(r.p.wake(), "now\r\n").unwrap();
    assert_eq!(r.run(&mut r.cmd()), 0);
    let lines = r.lines();
    assert_eq!(lines.len(), 2, "started and stopped only: {lines:?}");
    assert_eq!(
        fs::read_to_string(r.p.wake()).unwrap(),
        "now\r\n",
        "left for the PS watcher"
    );
    let st = r.json(&r.p.state());
    assert_eq!(st["handoff"], true);
    assert_eq!(r.json(&r.p.last())["state"], "handed-over");
    assert!(
        r.log("chatqd.log")
            .contains("handing over to the PowerShell watcher: the phone reply window is open")
    );
    let h = r.json(&r.p.handoff());
    assert_eq!(h["v"], 1);
    assert_eq!(h["watcherPid"], st["pid"]);
    assert_eq!(h["w"]["handoff"], true);
    assert!(h["w"]["caches"]["ChatqAskSent"].is_array());
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
    assert!(
        r.p.handoff().exists(),
        "a panic hands W over too (SPEC 4.4)"
    );
    assert!(r.lines().last().unwrap().ends_with(" stopped"));
    let s = r.spawns();
    assert_eq!(s.len(), 1, "{s:?}");
    assert_eq!(s[0]["engine"], "ps");
}

#[test]
fn restart_respawns_native_after_preflight() {
    let r = root("restart-native");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(r.run(r.cmd().env("CHATQ_CHATQD", BIN)), 0);
    assert!(
        r.lines()
            .iter()
            .any(|l| l == "a newer copy was installed - handing over")
    );
    assert!(!r.p.restart().exists());
    assert_eq!(r.json(&r.p.last())["state"], "handed-over");
    assert_eq!(r.json(&r.p.state())["handoff"], true);
    assert!(
        !r.p.handoff().exists(),
        "a restart carries state.json alone (SPEC 4.4)"
    );
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
    assert_eq!(r.run(&mut r.cmd()), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert!(r.log("chatqd.log").contains("no runnable chatqd at"));

    let r = root("restart-engine");
    fs::write(r.p.restart(), "").unwrap();
    assert_eq!(
        r.run(r.cmd().env("CHATQ_CHATQD", BIN).env("CHATQ_ENGINE", "ps")),
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
    assert_eq!(r.run(r.cmd().env("CHATQ_CHATQD", BIN)), 0);
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
    assert_eq!(r.run(r.cmd().env("CHATQ_CHATQD", BIN)), 0);
    assert_eq!(r.spawns()[0]["engine"], "ps");
    assert!(r.log("chatqd.log").contains("failed 3 times"));

    // the scripts were updated to a version this binary is not
    let r = root("restart-newver");
    fs::write(r.p.restart(), "").unwrap();
    r.loader("99.0.0");
    assert_eq!(r.run(r.cmd().env("CHATQ_CHATQD", BIN)), 0);
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
