//! Every OS call chatqd makes, and so every `unsafe` block (SPEC 3.1).

#[cfg(unix)]
#[path = "mac.rs"]
mod os;
#[cfg(windows)]
#[path = "win.rs"]
mod os;

pub use os::{
    Awake, alive, is_chatqd, launch, own_start_ticks, peek_message, spawn_waited, system_proxy,
};

/// The process's own environment, set before any thread exists (SPEC 4.1).
pub fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: called only at start-up, from the main thread, before chatqd
    // starts any thread that could read the environment meanwhile.
    unsafe {
        match value {
            Some(v) => std::env::set_var(name, v),
            None => std::env::remove_var(name),
        }
    }
}

/// The Windows command line of a launch: the exe always quoted, as .NET
/// quotes it, then [ConvertTo-ChatqArgLine](src/queue.ps1)'s line.
pub fn command_line(exe: &str, args: &[String]) -> String {
    format!("\"{exe}\" {}", chatq_core::argline::arg_line(args))
}

/// How a launch starts: chatqd itself, or a PowerShell (console) watcher.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Native,
    Ps,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn root(name: &str) -> PathBuf {
        let r = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/chatqd-sys")
            .join(name);
        let _ = fs::remove_dir_all(&r);
        fs::create_dir_all(&r).unwrap();
        r
    }

    #[cfg(windows)]
    fn shell(script: &str) -> (String, Vec<String>) {
        let cmd = std::env::var("ComSpec").unwrap();
        (cmd, vec!["/c".into(), script.into()])
    }

    #[cfg(unix)]
    fn shell(script: &str) -> (String, Vec<String>) {
        ("/bin/sh".into(), vec!["-c".into(), script.into()])
    }

    fn exit_code(mut child: os::Waited) -> i32 {
        for _ in 0..30 {
            if let Some(code) = child.wait(Duration::from_secs(2)) {
                return code;
            }
        }
        panic!("the step never ended");
    }

    #[test]
    fn a_step_gives_its_exit_code() {
        let r = root("exit");
        let (exe, args) = shell("exit 7");
        let child = spawn_waited(&exe, &args, r.to_str().unwrap()).unwrap();
        assert_eq!(exit_code(child), 7);
    }

    #[test]
    fn a_step_that_cannot_start_is_an_error() {
        let r = root("missing");
        let exe = r.join("no-such.exe");
        assert!(spawn_waited(exe.to_str().unwrap(), &[], r.to_str().unwrap()).is_err());
    }

    #[test]
    fn own_start_ticks_is_now_as_dotnet_reads_it() {
        let since = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let now = 621_355_968_000_000_000 + (since.as_nanos() / 100) as i64;
        let start = own_start_ticks().unwrap();
        // A wrong epoch or a local/UTC mix is off by hours or centuries.
        assert!(start <= now + 10_000_000, "{start} is after {now}");
        assert!(
            now - start < 30 * 10_000_000,
            "{start} is long before {now}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_step_leaves_watcher_out_alone() {
        let r = root("logs");
        let logs = r.join("data/logs");
        fs::create_dir_all(&logs).unwrap();
        for f in ["watcher.out", "watcher.err"] {
            fs::write(logs.join(f), "kept").unwrap();
        }
        let (exe, args) = shell("echo out; echo err >&2");
        let child = spawn_waited(&exe, &args, r.to_str().unwrap()).unwrap();
        assert_eq!(exit_code(child), 0);
        for f in ["watcher.out", "watcher.err"] {
            assert_eq!(fs::read_to_string(logs.join(f)).unwrap(), "kept");
        }
    }
}
