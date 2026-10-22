//! `chatqd watch`: start-up and exit around the loop (SPEC 1.1, 4.1, 4.4).

mod awake;
#[path = "loop.rs"]
mod looping;
mod reply;
mod spawn;
mod step;
mod wait;

use crate::seams::Seams;
use crate::{VERSION, sys};
use awake::KeepAwake;
use chatq_core::culture::Culture;
use chatq_core::fsx::{save_text, try_lock};
use chatq_core::json::to_pretty;
use chatq_core::launch::{ack_pending, record_strike, write_last};
use chatq_core::log::add_log_line;
use chatq_core::paths::Paths;
use chatq_core::state::WatchState;
use chatq_core::time::Flavour;
use chrono::Utc;
use looping::{Exit, Host};
use std::fs::{self, File};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

/// `watch --root R --script S --ps P [--culture C]` (SPEC 4.1).
pub struct Args {
    pub root: String,
    pub script: String,
    pub ps: String,
    pub culture: Option<String>,
}

impl Args {
    pub fn parse(a: &[String]) -> Option<Args> {
        let (mut root, mut script, mut ps, mut culture) = (None, None, None, None);
        let mut it = a.iter();
        while let Some(k) = it.next() {
            let v = it.next()?.clone();
            match k.as_str() {
                "--root" => root = Some(v),
                "--script" => script = Some(v),
                "--ps" => ps = Some(v),
                "--culture" => culture = Some(v),
                _ => return None,
            }
        }
        Some(Args {
            root: root?,
            script: script?,
            ps: ps?,
            culture,
        })
    }
}

/// What every part of the watcher reads and nothing changes.
pub struct Ctx {
    pub args: Args,
    pub p: Paths,
    pub pid: u32,
    /// how the starter's PowerShell reads a zoneless stamp
    pub fl: Flavour,
    pub culture: Culture,
    pub seams: Seams,
}

impl Ctx {
    /// [Write-ChatqWatchLog](src/watcher.ps1): never throws.
    pub fn wlog(&self, text: &str) {
        let _ = add_log_line(&self.p.log_dir(), "watcher.log", text, Utc::now());
    }

    /// chatqd.log: chatqd's own diagnostics, same line format and roll.
    pub fn dlog(&self, text: &str) {
        let _ = add_log_line(&self.p.log_dir(), "chatqd.log", text, Utc::now());
    }
}

/// Lock tries, and the pause between them: a watcher handing over lets go
/// only as it exits, and a prober holds the lock for an instant.
const LOCK_TRIES: u32 = 5;
const LOCK_PAUSE: Duration = Duration::from_millis(200);

fn take_lock(p: &Paths) -> Option<File> {
    for t in 1..=LOCK_TRIES {
        if let Ok(f) = try_lock(&p.lock()) {
            return Some(f);
        }
        if t < LOCK_TRIES {
            sleep(LOCK_PAUSE);
        }
    }
    None
}

/// Step exchanges, the PS cache a step left behind and a handoff no PS
/// watcher took (SPEC 4.5): no step can be running before this chatqd has
/// the lock, and nothing reads them across a chatqd's start.
fn sweep_leftovers(p: &Paths) {
    let _ = fs::remove_file(p.native_file("carry.clixml"));
    let _ = fs::remove_file(p.handoff());
    let Ok(rd) = fs::read_dir(p.native_dir()) else {
        return;
    };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().to_lowercase();
        if n.starts_with("step-") && n.ends_with(".json") {
            let _ = fs::remove_file(e.path());
        }
    }
}

pub fn run(args: Args) -> ExitCode {
    // first, so everything this process starts inherits it (SPEC 2.5)
    sys::set_env("CHATQ_WATCHER", Some("1"));
    sys::set_env("PSExecutionPolicyPreference", None);
    sys::peek_message();
    let ctx = Ctx {
        p: Paths::new(&args.root),
        pid: std::process::id(),
        fl: Flavour::from_exe(&args.ps),
        culture: args
            .culture
            .as_deref()
            .and_then(Culture::from_arg)
            .unwrap_or_else(Culture::invariant),
        seams: Seams::load(),
        args,
    };
    let p = &ctx.p;
    let _ = fs::create_dir_all(&p.data);
    for line in ctx.seams.honoured() {
        ctx.dlog(&line);
    }
    let logs = p.log_dir();
    std::panic::set_hook(Box::new(move |info| {
        let msg = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_default();
        let at = info
            .location()
            .map(|l| format!(" @ {}:{}", l.file(), l.line()))
            .unwrap_or_default();
        let _ = add_log_line(
            &logs,
            "chatqd.log",
            &format!("chatqd panicked: {msg}{at}"),
            Utc::now(),
        );
    }));

    let Some(lock) = take_lock(p) else {
        // another watcher has it: ack this launch, and leave last.json to
        // the one holding the lock (SPEC 4.2)
        ack_pending(p, ctx.pid);
        ctx.dlog("another watcher holds the lock - leaving");
        return ExitCode::SUCCESS;
    };
    sweep_leftovers(p);
    let _ = write_last(p, ctx.pid, VERSION, "holding", Utc::now());
    ack_pending(p, ctx.pid);

    let mut w = WatchState {
        started_at: chatq_core::time::stamp_utc(Utc::now()),
        ..Default::default()
    };
    let mut host = looping::Live::new(&ctx);
    let exit = match catch_unwind(AssertUnwindSafe(|| {
        looping::start(&ctx, &mut w);
        looping::run(&mut host, &mut w)
    })) {
        Ok(e) => e,
        Err(_) => {
            // the hook has logged it; a panic is a strike, and the PS
            // watcher carries on from the state saved below (SPEC 4.4)
            let _ = record_strike(p, VERSION, "panic", Some(ctx.pid), Utc::now());
            w.handoff = true;
            Exit::Handoff("chatqd panicked".into())
        }
    };

    // the PS loop's finally
    host.awake(false);
    let _ = fs::remove_file(p.pid());
    w.current = None;
    w.next = None;
    w.listening = false;
    if matches!(exit, Exit::Handoff(_)) {
        write_handoff(&ctx, &w);
    }
    save_state(&ctx, &w);
    let state = match exit {
        Exit::Empty => "empty",
        Exit::Stopped => "stopped",
        Exit::Restart | Exit::Handoff(_) => "handed-over",
    };
    let _ = write_last(p, ctx.pid, VERSION, state, Utc::now());
    // Once more: a launcher that learns the pid only after the start (PS
    // Start-Process, macOS) can write pending.json after the first ack.
    ack_pending(p, ctx.pid);
    drop(lock);
    ctx.wlog(&format!("watcher {} stopped", ctx.pid));

    // Last of all, once the lock, the pid file and the state are settled:
    // a successor started sooner would find this one still holding the lock.
    match exit {
        Exit::Handoff(why) => {
            spawn::launch_ps(&ctx);
            ctx.dlog(&format!("handing over to the PowerShell watcher: {why}"));
        }
        Exit::Restart => spawn::respawn(&ctx),
        Exit::Empty => {
            if looping::listen_after_empty(&mut host) {
                spawn::respawn(&ctx);
            }
        }
        Exit::Stopped => {}
    }
    ExitCode::SUCCESS
}

/// [Save-ChatqWatchState](src/watcher.ps1): never throws.
pub fn save_state(ctx: &Ctx, w: &WatchState) {
    // the text native/vectors/state.json pins
    let _ = save_text(&ctx.p.state(), &w.to_text(ctx.pid, VERSION, Utc::now()));
}

/// D/native/handoff.json (SPEC 4.4): W and its caches, for the PS watcher a
/// handoff starts to carry on with. carry.clixml stays beside it. Written
/// before the state save, so a state.json saying `handoff` finds it there.
fn write_handoff(ctx: &Ctx, w: &WatchState) {
    let _ = save_text(&ctx.p.handoff(), &to_pretty(&w.to_handoff(ctx.pid)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn a_handoff_leaves_w_for_the_ps_watcher() {
        let r = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/chatqd-handoff");
        let _ = fs::remove_dir_all(&r);
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
        let mut w = WatchState {
            started_at: "2026-10-18T01:02:03.0000000Z".into(),
            ..Default::default()
        };
        w.add_usage_sent("claude|session|x");
        fs::create_dir_all(ctx.p.native_dir()).unwrap();
        fs::write(ctx.p.native_file("carry.clixml"), "<Objs/>").unwrap();
        write_handoff(&ctx, &w);
        let v: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(ctx.p.handoff()).unwrap()).unwrap();
        assert_eq!(v["v"], 1);
        assert_eq!(v["watcherPid"], 4242);
        assert_eq!(v["w"]["handoff"], true);
        let back = WatchState::from_w(&v["w"]).unwrap();
        assert_eq!(back.usage_sent(), ["claude|session|x"]);
        assert!(
            ctx.p.native_file("carry.clixml").exists(),
            "the carry stays"
        );
        // and the next chatqd's start takes both away
        sweep_leftovers(&ctx.p);
        assert!(!ctx.p.handoff().exists());
        assert!(!ctx.p.native_file("carry.clixml").exists());
    }
}
