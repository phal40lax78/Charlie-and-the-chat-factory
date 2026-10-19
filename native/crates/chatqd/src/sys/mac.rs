//! macOS: caffeinate, nohup, kill(pid, 0), proc_pidinfo. Other Unixes lack
//! the last.
//! Windows can lint it (`cargo clippy --target aarch64-apple-darwin`, with
//! that target added); only the native-macos CI leg builds and runs it.

use super::Kind;
use std::fs::{self, File};
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// .NET ticks at 1970-01-01.
const UNIX_TICKS: i64 = 621_355_968_000_000_000;

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

/// A helper step's process (SPEC 3.6).
pub struct Waited(Child);

/// Starts a helper step: `exe args` in `cwd`, stdio on null. Not [launch],
/// which truncates D/logs/watcher.out and .err for watcher launches only.
pub fn spawn_waited(exe: &str, args: &[String], cwd: &str) -> io::Result<Waited> {
    Command::new(exe)
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(Waited)
}

impl Waited {
    /// Waits up to `timeout` for the step to end: its exit code as .NET's
    /// `ExitCode` reads it (128 + the signal for a killed one), or None
    /// while it still runs.
    pub fn wait(&mut self, timeout: Duration) -> Option<i32> {
        let end = Instant::now() + timeout;
        loop {
            match self.0.try_wait() {
                Ok(Some(s)) => return s.code().or(s.signal().map(|n| 128 + n)),
                Ok(None) if Instant::now() < end => thread::sleep(Duration::from_millis(50)),
                _ => return None,
            }
        }
    }
}

/// chatqd's own start time as .NET UTC ticks: `proc_pidinfo`'s start, the
/// source of .NET's `Process.StartTime` (SPEC 3.6).
pub fn own_start_ticks() -> io::Result<i64> {
    // SAFETY: proc_bsdinfo is plain integers and bytes, so all-zero is valid.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: info is a writable buffer of exactly size bytes.
    let n = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    if n != size {
        return Err(io::Error::last_os_error());
    }
    Ok(UNIX_TICKS + info.pbi_start_tvsec as i64 * 10_000_000 + info.pbi_start_tvusec as i64 * 10)
}
