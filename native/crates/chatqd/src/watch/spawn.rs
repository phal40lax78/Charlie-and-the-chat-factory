//! The watcher chatqd starts after it lets go (SPEC 4.2, 4.4): the PS
//! watcher on a handoff, and on a respawn whichever the decision picks from
//! the scripts now on disk, never chatqd's own compiled version.

use super::Ctx;
use crate::sys::{self, Kind};
use chatq_core::config::read_config;
use chatq_core::launch::{
    self, Ask, Probes, TARGET, ack_pending, binary_path, native_args, ps_watcher_args,
    ps_watcher_command, read_loader_version, record_strike, write_pending,
};
use chrono::Utc;
use serde_json::json;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

/// How long preflight's `chatqd version` may take.
const PREFLIGHT: Duration = Duration::from_secs(5);

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

/// `$HOME`, never the caller's folder: Windows will not delete or rename a
/// folder a long-lived process is in.
fn home(ctx: &Ctx) -> String {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    env(var).unwrap_or_else(|| ctx.p.root.clone())
}

/// Starts one launch, or records it when the `spawn` seam is on (SPEC 6.5).
/// A failure is logged to chatqd.log and its message returned.
fn start(
    ctx: &Ctx,
    kind: Kind,
    exe: &str,
    args: &[String],
    command: Option<&str>,
    before_run: &mut dyn FnMut(u32),
) -> Result<(), String> {
    let cwd = home(ctx);
    let record = json!({
        "engine": if kind == Kind::Native { "native" } else { "ps" },
        "exe": exe,
        "args": args,
        "cmdline": sys::command_line(exe, args),
        "command": command,
        "cwd": cwd,
    });
    if ctx.seams.capture(&record) {
        return Ok(());
    }
    sys::launch(kind, exe, args, &cwd, &ctx.p.logs, before_run)
        .map(|_| ())
        .map_err(|e| {
            ctx.dlog(&format!("cannot start the watcher {exe}: {e}"));
            e.to_string()
        })
}

/// [Get-ChatqWatcherLaunch](src/watcher.ps1)'s command, started with the
/// starter's PowerShell. chatqd has already let go by now, so a failure here
/// leaves no watcher: it goes to watcher.log too, where the user looks,
/// in [Start-ChatqWatcherProcess](src/watcher.ps1)'s words.
pub fn launch_ps(ctx: &Ctx) {
    let cmd = ps_watcher_command(
        &ctx.args.script,
        &ctx.p.logs,
        env("CHATQ_CLAUDE").as_deref(),
        env("CHATQ_CODEX").as_deref(),
    );
    let started = start(
        ctx,
        Kind::Ps,
        &ctx.args.ps,
        &ps_watcher_args(&cmd),
        Some(&cmd),
        &mut |_| {},
    );
    if let Err(e) = started {
        ctx.wlog(&format!("cannot start the watcher: {e}"));
    }
}

/// `chatqd version --root R`, at most 5 s, must exit 0 printing exactly
/// `chatqd <version> <target>`.
fn preflight(bin: &Path, root: &str, version: &str) -> Result<(), String> {
    let mut child = Command::new(bin)
        .args(["version", "--root", root])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("did not start: {e}"))?;
    let t0 = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if t0.elapsed() < PREFLIGHT => sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("no answer within 5 s".into());
            }
        }
    };
    let mut out = String::new();
    if let Some(mut s) = child.stdout.take() {
        let _ = s.read_to_string(&mut out);
    }
    let out = out.trim_end_matches(['\r', '\n']);
    let want = format!("chatqd {version} {TARGET}");
    if status.success() && out == want {
        Ok(())
    } else {
        Err(format!("exit {:?}, said '{out}'", status.code()))
    }
}

/// Is the binary there to run? On Unix, the owner exec bit too.
fn runnable(bin: &Path) -> bool {
    let Ok(m) = std::fs::metadata(bin) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        m.is_file() && m.permissions().mode() & 0o100 != 0
    }
    #[cfg(not(unix))]
    m.is_file()
}

/// The decision (SPEC 4.2), [launch::decide] with this system's answers.
/// Every strike found there, and every refusal, makes this launch the PS
/// watcher's.
fn decide(ctx: &Ctx, version: &str) -> Result<String, String> {
    let p = &ctx.p;
    let probes = Probes {
        live_chatqd: &sys::is_chatqd,
        alive: &sys::alive,
    };
    let engine = env("CHATQ_ENGINE");
    let cfg = read_config(&p.config(), ctx.fl);
    let bin = binary_path(p, version, env("CHATQ_CHATQD").as_deref());
    let mut pre = |b: &Path| preflight(b, &p.root, version);
    let ask = Ask {
        engine_env: engine.as_deref(),
        cfg: &cfg,
        native_os: cfg!(any(windows, target_os = "macos")),
        bin: &bin,
        runnable: &runnable,
        preflight: &mut pre,
    };
    let d = launch::decide(p, version, Utc::now(), &probes, ask);
    for s in &d.strikes {
        ctx.dlog(&format!("fuse strike: {s}"));
    }
    d.native
}

/// A restart, or an empty exit with a reply window open: the decision on
/// the loader's version now, not chatqd's.
pub fn respawn(ctx: &Ctx) {
    let Some(version) = read_loader_version(Path::new(&ctx.args.script)) else {
        ctx.dlog("the scripts' version cannot be read - starting the PowerShell watcher");
        launch_ps(ctx);
        return;
    };
    match decide(ctx, &version) {
        Err(why) => {
            ctx.dlog(&format!("starting the PowerShell watcher: {why}"));
            launch_ps(ctx);
        }
        Ok(bin) => {
            let a = &ctx.args;
            let args = native_args(&a.root, &a.script, &a.ps, a.culture.as_deref());
            let p = &ctx.p;
            let mut wrote = None;
            let mut pending = |pid: u32| {
                wrote = Some(pid);
                let _ = write_pending(p, pid, &version, Utc::now());
            };
            if start(ctx, Kind::Native, &bin, &args, None, &mut pending).is_ok() {
                ctx.dlog(&format!("starting chatqd {version}"));
            } else {
                // a child ended before it ran never acks: its pending record
                // goes, or this one failure would be a second strike later
                if let Some(pid) = wrote {
                    ack_pending(p, pid);
                }
                let _ = record_strike(p, &version, "start failed", None, Utc::now());
                ctx.dlog("starting the PowerShell watcher: chatqd did not start");
                launch_ps(ctx);
            }
        }
    }
}
