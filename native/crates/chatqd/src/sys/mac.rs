//! macOS (and any Unix chatqd is built on): caffeinate, nohup, kill(pid, 0).
//! Windows can lint it (`cargo clippy --target aarch64-apple-darwin`, with
//! that target added); only the native-macos CI leg builds and runs it.

use super::Kind;
use std::fs::{self, File};
use std::io;
use std::process::{Child, Command, Stdio};

/// No message queue on Unix.
pub fn peek_message() {}

/// `caffeinate -i -w <pid>`, which ends by itself however chatqd dies.
#[derive(Default)]
pub struct Awake(Option<Child>);

impl Awake {
    pub fn set(&mut self, on: bool) {
        if on {
            let pid = std::process::id().to_string();
            self.0 = Command::new("caffeinate")
                .args(["-i", "-w", &pid])
                .spawn()
                .ok();
        } else if let Some(mut c) = self.0.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Is there a live process at `pid`? One we may not signal is there.
pub fn alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    // SAFETY: signal 0 checks for the process and delivers nothing.
    let r = unsafe { libc::kill(pid, 0) };
    r == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Is the live process at `pid` a chatqd? By `ps`'s command name.
pub fn is_chatqd(pid: u32) -> bool {
    Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .stderr(Stdio::null())
        .output()
        .is_ok_and(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .ends_with("chatqd")
        })
}

/// `nohup <exe> <args…> > D/logs/watcher.out 2> D/logs/watcher.err`, as
/// [Start-ChatqWatcherProcess](src/watcher.ps1) starts one. Unlike Windows,
/// the child is already running when its pid is known, so a fast ack can
/// come before pending.json does.
pub fn launch(
    _kind: Kind,
    exe: &str,
    args: &[String],
    cwd: &str,
    log_dir: &str,
    before_run: &mut dyn FnMut(u32),
) -> io::Result<u32> {
    fs::create_dir_all(log_dir)?;
    let out = File::create(format!("{log_dir}/watcher.out"))?;
    let err = File::create(format!("{log_dir}/watcher.err"))?;
    let child = Command::new("nohup")
        .arg(exe)
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .spawn()?;
    before_run(child.id());
    Ok(child.id())
}
